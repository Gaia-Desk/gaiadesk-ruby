# frozen_string_literal: true

require "test_helper"

# Every desk operation over the hosted API, in the clear (a desk that publishes no key),
# against the mock API.
class DeskOpsTest < Minitest::Test
  D = MockApi::DESK

  def setup
    @api = MockApi.new
    @warnings = []
    @gd = client(@api, desk_token: "gdagt_basic", warnings: @warnings)
  end

  def teardown
    @api.close
  end

  def last(method = nil)
    @api.log.reverse.find { |r| method.nil? || r.method == method }
  end

  # ───────────────────────────── devices ─────────────────────────────

  def test_devices
    r = @gd.devices

    assert_includes r["devices"].map { |d| d["desk_id"] }, D
    assert_equal ["server"], r["sources"]
    assert_equal([D], @gd.devices(desk_id: D)["devices"].map { |d| d["desk_id"] })
    req = last

    assert_equal "Bearer sess_person", req.header("authorization")
    assert_equal "gdagt_basic", req.header("x-gaiadesk-desk-token")
    assert_match %r{\Agaiadesk-ruby/}, req.header("user-agent")
  end

  # ───────────────────────────── exec ─────────────────────────────

  def test_exec
    r = @gd.exec(D, "echo hi")

    assert_equal 0, r["exit"]
    assert_equal "hi\n", r["stdout"]
    req = last("POST")

    assert_equal "/v1/desks/#{D}/exec", req.path
    assert_equal({ "command" => "echo hi" }, JSON.parse(req.body))
    assert_equal "application/json", req.header("content-type")
    assert_equal 1, @warnings.size, "one plaintext warning per desk"
    @gd.exec(D, "echo again")

    assert_equal 1, @warnings.size
  end

  def test_exec_argv_and_options
    r = @gd.exec(D, %w[spec x], stdin: "in", shell: :powershell, env: { "A" => "1" }, cwd: "src", timeout: "2m")

    assert_equal({ "argv" => %w[spec x], "shell" => "pwsh", "env" => { "A" => "1" }, "cwd" => "src", "timeout_secs" => 120, "stdin" => "in" },
                 JSON.parse(r["stdout"]))
    assert_equal "piped\n", @gd.exec(D, "cat", stdin: StringIO.new("piped\n"))["stdout"]
    assert_equal "1\n", @gd.exec(D, "printenv X", env: { "X" => "1" })["stdout"]
  end

  def test_a_non_zero_exit_is_a_result
    assert_equal 7, @gd.exec(D, "exit 7")["exit"]
    e = assert_raises(GaiaDesk::CommandError) { @gd.exec(D, "exit 7", check: true) }
    assert_equal 7, e.result["exit"]
  end

  def test_a_timed_out_command
    r = @gd.exec(D, "timeout")

    assert_equal 124, r["exit"]
    assert r["timed_out"]
    assert_raises(GaiaDesk::CommandError) { @gd.exec(D, "timeout", check: true) }
  end

  def test_a_refused_command_raises
    e = assert_raises(GaiaDesk::RefusedError) { @gd.exec(D, "refuse") }
    assert_equal "desk_opted_out", e.reason
    assert_equal 254, e.exit_code
  end

  def test_admin
    e = assert_raises(GaiaDesk::RefusedError) { @gd.exec(D, "whoami", admin: true) }
    assert_equal "admin_scope_missing", e.reason
    assert_predicate e, :admin_refusal?
    assert_equal true, JSON.parse(last("POST").body)["admin"]

    e = assert_raises(GaiaDesk::RefusedError) { @gd.exec(D, "whoami", admin: true, desk_token: "gdagt_admin") }
    assert_equal "admin_not_enabled", e.reason
    @api.desks[D].admin_enabled = true
    @api.desks[D].admin_mode = :deny
    e = assert_raises(GaiaDesk::RefusedError) { @gd.exec(D, "whoami", admin: true, desk_token: "gdagt_admin") }
    assert_equal "admin_denied", e.reason
    @api.desks[D].admin_mode = :allow

    assert_equal "root\n", @gd.exec(D, "whoami", admin: true, desk_token: "gdagt_admin")["stdout"]
    assert_equal "gdagt_admin", last("POST").header("x-gaiadesk-desk-token")
    assert_equal "user\n", @gd.exec(D, "whoami")["stdout"]
  end

  def test_per_call_wake_and_client_wake
    @gd.exec(D, "echo x", wake: 15)

    assert_equal({ "wake_s" => "15" }, last("POST").query)
    gd = client(@api, desk_token: "gdagt_basic", wake: 40)
    gd.stats(D)

    assert_equal "40", last.query["wake_s"]
    gd.stats(D, wake: 0)

    assert_equal "0", last.query["wake_s"]
  end

  def test_idempotency_key_is_sent_on_posts
    @gd.exec(D, "echo x", idempotency_key: "run-42")

    assert_equal "run-42", last("POST").header("idempotency-key")
  end

  def test_an_api_key_without_a_desk_token_is_refused
    gd = client(@api, api_key: "ak_live", desk_token: nil)
    e = assert_raises(GaiaDesk::RefusedError) { gd.exec(D, "echo x") }
    assert_equal "agent_token_required", e.reason
    assert_equal 403, e.status
    assert_match(/\Areq_[0-9a-f]{24}\z/, e.request_id)
    assert_equal "refused", e.json["error"]["kind"]
  end

  # ───────────────────────────── exec_stream ─────────────────────────────

  def test_exec_stream
    s = @gd.exec_stream(D, "echo streamed")

    assert_equal [%W[stdout streamed\n]], s.text.to_a
    assert_equal 0, s.wait.exit_code
    assert_equal "exit", s.result["event"]
    refute s.result.key?("stdout")
    req = last("POST")

    assert_equal({ "stream" => "1" }, req.query)
    assert_equal "text/event-stream", req.header("accept")
  end

  def test_exec_stream_with_a_block
    seen = []
    s = @gd.exec_stream(D, "err oops") { |c| seen << [c.stream, c.data] }

    assert_equal [["stderr", "oops\n".b]], seen
    assert_equal 3, s.exit_code
    assert_equal 3, s.result["exit"]
  end

  def test_exec_stream_utf8_split_across_events
    s = @gd.exec_stream(D, "utf8")

    assert_equal "h\u00e9llo w\u00f6rld \u2713\n", s.read_all["stdout"]
  end

  def test_a_desk_lost_mid_stream
    s = @gd.exec_stream(D, "lost")

    assert_equal "partial\n", s.read_all["stdout"]
    assert_equal 255, s.wait.exit_code
    assert_equal "connection_lost", s.result["error"]["kind"]
  end

  def test_a_stream_cut_before_its_end
    s = @gd.exec_stream(D, "cut")
    s.read_all

    assert_equal 255, s.wait.exit_code
    assert_equal "connection_lost", s.result["error"]["kind"]
    assert_match(/ended before the command did/, s.result["error"]["message"])
  end

  def test_a_refusal_before_the_stream
    s = @gd.exec_stream(D, "refuse-early")

    assert_empty s.to_a
    assert_equal 254, s.wait.exit_code
    assert_equal "refused", s.result["error"]["kind"]
    assert_equal "desk_opted_out", s.result["error"]["reason"]
  end

  def test_kill_a_stream
    s = @gd.exec_stream(D, "slow")
    first = s.next_chunk

    assert_equal "tick\n", first.text
    s.kill

    assert_equal 130, s.wait(5).exit_code
    assert_nil s.result
  end

  def test_a_stream_takes_no_stdin_writes
    s = @gd.exec_stream(D, "echo x", stdin: "given up front")
    assert_raises(GaiaDesk::UsageError) { s.write("more") }
    s.wait

    assert_equal "given up front", JSON.parse(last("POST").body)["stdin"]
  end

  # ───────────────────────────── jobs ─────────────────────────────

  def test_jobs_lifecycle
    job = @gd.run_job(D, "nightly", "./build.sh --release", shell: "bash", env: { "CI" => "1" }, cpu: 50, mem: "1G", keep_awake: true,
                                                            priority: "low", cwd: "repo")

    assert_equal "running", job["state"]
    body = JSON.parse(last("POST").body)

    assert_equal ["./build.sh --release"], body["command"]
    assert_equal({ "priority" => "low", "cpu_percent" => 50, "mem_mb" => 1024, "keep_awake" => true }, body["limits"])
    assert_equal(["nightly"], @gd.jobs(D).map { |j| j["name"] })
    assert_equal "line one\nline two\n", @gd.job_logs(D, "nightly")
    assert_equal "two\n", @gd.job_logs(D, "nightly", tail: 4)
    assert_equal({ "tail" => "4" }, last.query)
    assert_equal "nightly", @gd.job_log_result(D, "nightly")["job"]["name"]
    killed = @gd.kill_job(D, "nightly")

    assert_equal "killed", killed["state"]
    assert_equal "DELETE", last.method
    e = assert_raises(GaiaDesk::OperationFailedError) { @gd.kill_job(D, "nope") }
    assert_equal 422, e.status
    assert_equal 1, e.exit_code
  end

  def test_follow_job_logs
    @gd.run_job(D, "build", "quick thing")
    chunks = []
    s = @gd.follow_job_logs(D, "build") { |c| chunks << c.text }

    assert_equal "line one\nline two\n", chunks.join
    assert_equal "end", s.result["event"]
    assert_equal 0, s.exit_code
    assert_equal({ "follow" => "1" }, last.query)
  end

  def test_follow_job_logs_interrupted_and_missing
    @gd.run_job(D, "svc", "forever serve")
    s = @gd.follow_job_logs(D, "svc", tail: 9)
    s.read_all

    assert_equal "interrupted", s.result["event"]
    assert_equal({ "follow" => "1", "tail" => "9" }, last.query)
    s = @gd.follow_job_logs(D, "nope")
    s.read_all

    assert_equal "error", s.result["event"]
    assert_equal 1, s.wait.exit_code
  end

  def test_wait_job
    @gd.run_job(D, "fast", "finishes soon")
    r = @gd.wait_job(D, "fast", timeout: 30)

    refute r["timed_out"]
    assert_equal({ "timeout" => "30" }, last.query)
  end

  def test_wait_job_times_out
    @gd.run_job(D, "slowjob", "./forever")
    r = @gd.wait_job(D, "slowjob", timeout: 0)

    assert r["timed_out"]
    assert_equal [0], @api.waits
  end

  def test_wait_job_without_timeout_asks_at_most_870
    @gd.run_job(D, "fast", "finishes soon")
    @gd.wait_job(D, "fast")

    assert_equal [870], @api.waits
  end

  def test_held_wait
    @gd.run_job(D, "held1", "./x")
    r = @gd.wait_job(D, "held1", timeout: 60)

    assert_equal "exited", r["job"]["state"]
    refute r["timed_out"]
  end

  def test_held_wait_failure_is_its_error
    @gd.run_job(D, "heldfail", "./x")
    e = assert_raises(GaiaDesk::ConnectionLostError) { @gd.wait_job(D, "heldfail", timeout: 60) }
    assert_equal 502, e.status
    assert_match(/went away/, e.message)
  end

  def test_wait_for_a_missing_job
    assert_raises(GaiaDesk::OperationFailedError) { @gd.wait_job(D, "ghost", timeout: 1) }
  end

  def test_stats
    r = @gd.stats(D)

    assert_equal 8, r["cpus"]
  end

  # ───────────────────────────── files ─────────────────────────────

  def test_upload_bytes_and_download_bytes
    r = @gd.upload_bytes("payload \x00\xff".b, D, "/tmp/p.bin")

    assert_equal 10, r["bytes"]
    req = last("PUT")

    assert_equal({ "path" => "/tmp/p.bin" }, req.query)
    assert_equal "application/octet-stream", req.header("content-type")
    assert_equal "payload \x00\xff".b, @gd.download_bytes(D, "/tmp/p.bin")
  end

  def test_upload_a_file_keeps_its_name_for_a_folder_target
    Dir.mktmpdir do |dir|
      path = File.join(dir, "report.csv")
      File.binwrite(path, "a,b\n1,2\n")
      r = @gd.upload(path, D, "/srv/")

      assert_equal "/srv/report.csv", r["destination"]
      assert_equal "a,b\n1,2\n", @api.desks[D].files["/srv/report.csv"]
      assert_raises(GaiaDesk::UsageError) { @gd.upload(dir, D, "/srv/") }
      e = assert_raises(GaiaDesk::Error) { @gd.upload(File.join(dir, "missing"), D, "/srv/") }
      assert_equal "local", e.kind
    end
  end

  def test_upload_an_io
    io = StringIO.new("from an io")
    @gd.upload(io, D, "/tmp/io.txt")

    assert_equal "from an io", @api.desks[D].files["/tmp/io.txt"]
    reader, writer = IO.pipe
    writer.write("piped")
    writer.close
    assert_raises(GaiaDesk::UsageError) { @gd.upload(reader, D, "/tmp/pipe.txt") }
    @gd.upload(reader, D, "/tmp/pipe.txt", size: 5)

    assert_equal "piped", @api.desks[D].files["/tmp/pipe.txt"]
  end

  def test_upload_that_failed
    e = assert_raises(GaiaDesk::OperationFailedError) { @gd.upload_bytes("x", D, "/readonly/x") }
    assert_equal 1, e.json["failed"].size
  end

  def test_upload_too_large_never_sends
    big = Struct.new(:size) { def read(*) = nil }.new(GaiaDesk::Transport::API_FILE_LIMIT + 1)
    @api.server.clear_log
    assert_raises(GaiaDesk::UsageError) { @gd.upload(big, D, "/tmp/big") }
    assert_empty @api.log
  end

  def test_download_to_a_path_a_folder_and_an_io
    Dir.mktmpdir do |dir|
      r = @gd.download(D, "/tmp/hello.txt", File.join(dir, "h.txt"))

      assert_equal "hello from the desk\n", File.read(File.join(dir, "h.txt"))
      assert_equal 20, r["bytes"]
      assert_equal "download", r["direction"]
      r = @gd.download(D, "/tmp/hello.txt", dir)

      assert_equal File.join(dir, "hello.txt"), r["destination"]
      assert_path_exists File.join(dir, "hello.txt")
    end
    io = StringIO.new
    @gd.download(D, "/tmp/hello.txt", io)

    assert_equal "hello from the desk\n", io.string
    assert_equal ["hello from the desk\n".b], @gd.download_stream(D, "/tmp/hello.txt").to_a
  end

  def test_download_errors
    e = assert_raises(GaiaDesk::UsageError) { @gd.download_bytes(D, "/tmp") }
    assert_equal "is_folder", e.reason
    assert_raises(GaiaDesk::OperationFailedError) { @gd.download_bytes(D, "/nope") }
    e = assert_raises(GaiaDesk::UnreachableError) { @gd.download_bytes(D, "/tmp/cut") }
    assert_equal "network", e.kind
  end

  # ───────────────────────────── tokens ─────────────────────────────

  def test_tokens
    gd = client(@api) # a person's session, no desk token
    r = gd.create_token(D, name: "ci", scopes: %w[exec admin], expires: "1d")
    t = r["tokens"].first

    assert_match(/\Agdagt_/, t["secret"])
    assert_equal({ "name" => "ci", "expires_secs" => 86_400, "scopes" => %w[exec admin] }, JSON.parse(last("POST").body))
    assert_includes gd.list_tokens(D).map { |x| x["id"] }, t["id"]
    assert_equal({ "revoked" => t["id"], "stopped_sessions" => 1 }, gd.revoke_token(D, t["id"]))
    assert_raises(GaiaDesk::OperationFailedError) { gd.revoke_token(D, "tok_gone") }
  end

  def test_token_administration_is_the_owners
    e = assert_raises(GaiaDesk::RefusedError) { @gd.list_tokens(D) }
    assert_equal "agent_cannot_admin", e.reason
  end

  def test_minting_on_several_desks_keeps_what_was_minted
    gd = client(@api)
    r = gd.create_token([D, MockApi::E2E_DESK], name: "both")

    assert_equal([D, MockApi::E2E_DESK], r["tokens"].map { |t| t["desk"] })
    e = assert_raises(GaiaDesk::UnreachableError) { gd.create_token([D, "111111111"], name: "half") }
    assert_equal "unknown_desk", e.kind
    assert_equal 1, e.json["tokens"].size
  end

  def test_token_ids_are_escaped
    gd = client(@api)
    gd.revoke_token(D, "ci") # by name

    assert_equal "/v1/desks/#{D}/tokens/ci", last.path
    assert_raises(GaiaDesk::OperationFailedError) { gd.revoke_token(D, "a b/c") }
    assert_equal "/v1/desks/#{D}/tokens/a%20b%2Fc", last.path
  end
end
