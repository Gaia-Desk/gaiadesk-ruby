# frozen_string_literal: true

# What a desk does with each operation, for the mock API: in-memory jobs, files and
# tokens, and a handful of commands with known behaviour. Each operation returns an
# outcome the mock renders in the clear or sealed:
#
# * Json(status, value): the JSON answer
# * Fail(error): the desk's error ({kind, message, reason?})
# * Events(kind, list): a stream of desk events ([:stdout, bytes], [:stderr, bytes],
#   [:exit, result], [:error, err], [:output, bytes], [:end, job], [:interrupted],
#   [:sleep, secs], [:forever, bytes] (repeat until the client goes), [:cut], [:lost, err])
# * FileOut(bytes, cut): a download
# * Held(delay, outcome): a wait answered after the 200 went out
class MockDesk
  Json = Struct.new(:status, :value)
  Fail = Struct.new(:error)
  Events = Struct.new(:kind, :list)
  FileOut = Struct.new(:bytes, :cut)
  Held = Struct.new(:delay, :outcome)

  attr_reader :id, :jobs, :files, :tokens

  def initialize(id)
    @id = id
    @jobs = {}
    @files = { "/tmp/hello.txt" => "hello from the desk\n".b }
    @folders = ["/tmp"]
    @tokens = [{ "id" => "tok_existing", "name" => "ci", "scopes" => %w[exec cp jobs], "expires_at" => 1_900_000_000 }]
    @seq = 0
  end

  def fail(kind, message, reason = nil)
    e = { "kind" => kind, "message" => message }
    e["reason"] = reason if reason
    Fail.new(e)
  end

  # ───────────────────────────── exec ─────────────────────────────

  def base_result(exit_code, out, err, error: nil, remote_code: exit_code, timed_out: false)
    { "desk" => @id, "exit" => exit_code, "remote_code" => remote_code, "stdout" => out.dup.force_encoding("UTF-8"),
      "stderr" => err.dup.force_encoding("UTF-8"), "timed_out" => timed_out, "truncated" => false, "error" => error,
      "duration_ms" => 3, "mode" => "pipes", "route" => "api" }
  end

  def refusal(reason, message)
    base_result(254, "", "", error: { "kind" => "refused", "message" => message, "reason" => reason, "desk" => @id }, remote_code: nil)
  end

  # The command's events and its result. Administrator work is refused, as the API does;
  # "adminwork" stands in for a request that asked for it.
  def run(spec, _scopes)
    if spec["admin"] || spec["command"] == "adminwork"
      return [[], refusal("admin_not_via_api", "administrator work is not available through the API")]
    end

    line = spec["command"] || Array(spec["argv"]).join(" ")
    word, rest = line.split(" ", 2)
    env = spec["env"] || {}
    case word
    when "echo" then ok_out("#{rest}\n")
    when "err" then [[[:stderr, "#{rest}\n".b]], base_result(3, "", "#{rest}\n")]
    when "exit" then [[], base_result(rest.to_i, "", "")]
    when "cat" then ok_out(spec["stdin"].to_s)
    when "printenv" then ok_out("#{env[rest]}\n")
    when "pwd" then ok_out("#{spec['cwd'] || '/home/user'}\n")
    when "whoami" then ok_out("user\n")
    when "shell" then ok_out("#{spec['shell'] || 'default'}\n")
    when "spec" then ok_out(JSON.generate(spec))
    when "utf8" then utf8
    when "refuse" then [[], refusal("desk_opted_out", "this desk does not take commands from the GaiaDesk API")]
    when "timeout"
      [[[:stdout, "started\n".b]], base_result(124, "started\n", "", remote_code: nil, timed_out: true,
                                                                     error: { "kind" => "failed", "message" => "timed out", "reason" => "timeout" })]
    when "big" then ok_out("#{'x' * 70_000}\n")
    else [[[:stderr, "#{word}: command not found\n".b]], base_result(127, "", "#{word}: command not found\n")]
    end
  end

  def ok_out(text)
    [[[:stdout, text.b]], base_result(0, text, "")]
  end

  def utf8
    text = "h\u00e9llo w\u00f6rld \u2713\n".b
    # split inside the multi-byte characters
    [[[:stdout, text.byteslice(0, 2)], [:stdout, text.byteslice(2, 8)], [:stdout, text.byteslice(10, text.bytesize - 10)]],
     base_result(0, text, "")]
  end

  def exec(spec, scopes, stream)
    line = spec["command"] || Array(spec["argv"]).join(" ")
    if stream && line == "lost"
      return Events.new("exec", [[:stdout, "partial\n".b], [:lost, { "kind" => "connection_lost", "message" => "the desk went away" }]])
    end
    return Events.new("exec", [[:stdout, "partial\n".b], [:cut]]) if stream && line == "cut"
    return Events.new("exec", [[:forever, "tick\n".b]]) if stream && line == "slow"
    return fail("refused", "the desk refused the command", "desk_opted_out") if stream && line == "refuse-early"

    events, result = run(spec, scopes)
    return Json.new(200, result) unless stream
    return Events.new("exec", [[:exit, result]]) if result["exit"] == 254 && result["remote_code"].nil?

    Events.new("exec", events + [[:exit, result]])
  end

  # ───────────────────────────── jobs ─────────────────────────────

  def job_start(spec, by)
    name = spec["name"]
    return fail("failed", "a job named #{name} is running") if @jobs[name] && @jobs[name]["state"] == "running"

    line = Array(spec["command"]).join(" ")
    done = line.start_with?("quick")
    @jobs[name] = { "name" => name, "command" => line, "state" => done ? "exited" : "running", "exit_code" => done ? 0 : nil,
                    "started_at_ms" => 1_791_000_000_000, "ended_at_ms" => done ? 1_791_000_001_000 : nil, "by" => by,
                    "limits" => spec["limits"], "cwd" => spec["cwd"], "shell" => spec["shell"], "env_names" => (spec["env"] || {}).keys,
                    "log" => "line one\nline two\n" }
    Json.new(201, public_job(@jobs[name]))
  end

  def public_job(job)
    job.except("log")
  end

  def job_list
    Json.new(200, { "jobs" => @jobs.values.map { |j| public_job(j) } })
  end

  def job(name)
    @jobs[name]
  end

  def job_kill(name)
    j = @jobs[name] or return fail("failed", "no job named #{name}")
    j["state"] = "killed"
    j["exit_code"] = -15
    Json.new(200, public_job(j))
  end

  def job_logs(name, tail, follow)
    j = @jobs[name] or return (follow ? Events.new("logs", [[:error, { "kind" => "failed", "message" => "no job named #{name}" }]]) : fail("failed", "no job named #{name}"))
    log = j["log"]
    log = log.byteslice([log.bytesize - tail.to_i, 0].max, tail.to_i) if tail
    return Json.new(200, { "job" => public_job(j), "output" => log }) unless follow

    return Events.new("logs", [[:output, log.b], [:interrupted]]) if j["command"].start_with?("forever")

    j["state"] = "exited"
    j["exit_code"] = 0
    Events.new("logs", [[:output, log.byteslice(0, 5).b], [:output, log.byteslice(5, log.bytesize - 5).b], [:end, public_job(j)]])
  end

  # A wait for +timeout+ seconds. "held*" jobs answer after the 200 went out; "heldfail"
  # fails then; a running job times out.
  def job_wait(name, timeout)
    j = @jobs[name] or return fail("failed", "no job named #{name}")
    return Held.new(0.05, fail("connection_lost", "the desk went away during the wait")) if name.start_with?("heldfail")

    if name.start_with?("held")
      j["state"] = "exited"
      j["exit_code"] = 0
      return Held.new(0.05, Json.new(200, { "job" => public_job(j), "timed_out" => false }))
    end
    if j["state"] == "running" && !j["command"].start_with?("finishes")
      return Json.new(200, { "job" => public_job(j), "timed_out" => true, "asked_timeout" => timeout })
    end

    j["state"] = "exited"
    j["exit_code"] ||= 0
    Json.new(200, { "job" => public_job(j), "timed_out" => false })
  end

  def stats
    Json.new(200, { "desk" => @id, "hostname" => "studio", "cpus" => 8, "cpu_percent" => 12.5, "mem_total_mb" => 16_384,
                    "mem_free_mb" => 8000, "disks" => [], "jobs_running" => @jobs.values.count { |j| j["state"] == "running" },
                    "load" => [0.5, 0.4, 0.3] })
  end

  # ───────────────────────────── files ─────────────────────────────

  def copy_result(direction, destination, bytes, failed = [])
    { "direction" => direction, "desk" => @id, "destination" => destination, "files" => failed.empty? ? 1 : 0, "dirs" => 0,
      "bytes" => bytes, "resumed_bytes" => 0, "failed" => failed, "seconds" => 0.01 }
  end

  def file_put(path, bytes)
    return Json.new(200, copy_result("upload", path, 0, [{ "path" => path, "error" => "permission denied" }])) if path.include?("readonly")

    path = "#{path}/upload.bin" if @folders.include?(path)
    @files[path] = bytes.b
    Json.new(200, copy_result("upload", path, bytes.bytesize))
  end

  def file_get(path)
    return fail("usage", "#{path} is a folder", "is_folder") if @folders.include?(path)
    return FileOut.new("only the first part".b, true) if path == "/tmp/cut"

    b = @files[path] or return fail("failed", "no such file: #{path}")
    FileOut.new(b, false)
  end

  # ───────────────────────────── tokens ─────────────────────────────

  def token_mint(spec)
    if Array(spec["scopes"]).include?("admin")
      return fail("refused", "the admin scope cannot be minted through the API", "admin_not_via_api")
    end

    @seq += 1
    t = { "desk" => @id, "id" => "tok_#{@seq}", "name" => spec["name"], "scopes" => spec["scopes"],
          "expires_at" => 1_791_000_000 + spec["expires_secs"].to_i, "cwd" => spec["cwd"], "low_priv" => spec["low_priv"] || false }
    @tokens << t.except("desk")
    Json.new(201, { "tokens" => [t.merge("secret" => "gdagt_secret_#{@seq}")] })
  end

  def token_list
    Json.new(200, { "tokens" => @tokens })
  end

  def token_revoke(id)
    t = @tokens.find { |x| x["id"] == id || x["name"] == id } or return fail("failed", "no token #{id} on this desk")
    @tokens.delete(t)
    Json.new(200, { "revoked" => t["id"], "stopped_sessions" => 1 })
  end
end
