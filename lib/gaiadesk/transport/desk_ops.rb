# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "uri"

module GaiaDesk
  # The desk operations, the same on every HTTP transport (+api+, +local+, +lan+):
  # each a request whose answer is the CLI's own JSON. Mixed into {Transport};
  # documented on {Client}.
  module DeskOps
    # <tt>GET /desks</tt>: <tt>{"devices", "sources", "notes", "identity"}</tt> (filtered to +desk_id+).
    def devices(desk_id: nil, call: {})
      r = json_call("GET", "/desks", call: call)
      unless r.is_a?(Hash) && r["devices"].is_a?(Array)
        raise ProtocolError.new("the GaiaDesk API listed no devices", kind: "protocol", argv: ["GET /desks"], json: r)
      end
      return r if desk_id.nil?

      d = Args.check_desk(desk_id)
      r.merge("devices" => r["devices"].select { |x| x.is_a?(Hash) && x["desk_id"] == d })
    end

    # <tt>POST /desks/{id}/exec</tt>: the ExecResult (a command that never ran is its typed error).
    def exec(desk_id, command, check: false, call: {}, **shape)
      path = "#{desk_path(desk_id)}/exec"
      spec = Args.exec_spec(command, **shape)
      r = desk_call(E2E::DeskOp.new(Args.check_desk(desk_id), "exec", { "spec" => spec }, "POST", path, json: spec, call: call))
      unless r.is_a?(Hash) && r["exit"].is_a?(Integer)
        raise ProtocolError.new("the GaiaDesk API answered exec without a result", kind: "protocol", argv: ["POST #{path}"], json: r)
      end

      Errors.exec_outcome(r, check, "POST #{path}")
    end

    # <tt>POST /desks/{id}/exec?stream=1</tt>: the ExecEvents as a {Stream}.
    def exec_stream(desk_id, command, call: {}, **shape)
      path = "#{desk_path(desk_id)}/exec"
      spec = Args.exec_spec(command, **shape)
      op = E2E::DeskOp.new(Args.check_desk(desk_id), "exec", { "spec" => spec, "stream" => true }, "POST", path,
                           json: spec, query: { "stream" => 1 }, sealed_query: { "stream" => 1 }, accept: "text/event-stream",
                           call: call)
      stream_of(op, "exec")
    end

    # <tt>POST /desks/{id}/jobs</tt> with a JobSpec: the Job.
    def run_job(desk_id, name, command, call: {}, **limits)
      spec = Args.job_spec(name, command, **limits)
      desk_call(E2E::DeskOp.new(Args.check_desk(desk_id), "job_start", { "spec" => spec }, "POST", "#{desk_path(desk_id)}/jobs",
                                json: spec, call: call))
    end

    # <tt>GET /desks/{id}/jobs/{name}/wait</tt>: <tt>{"job", "timed_out"}</tt> once the job is no
    # longer running. One request holds at most {Transport::API_WAIT_MAX} seconds, so a
    # longer (or no) +timeout+ asks again until the job ends or the time is up. A held
    # answer (<tt>GaiaDesk-Held: 1</tt>) is the result or the error envelope: the envelope
    # is raised as its typed error, whatever the 200.
    def wait_job(desk_id, name, timeout: nil, call: {})
      path = "#{job_path(desk_id, name)}/wait"
      total = timeout.nil? ? nil : Args.seconds(timeout, "timeout")
      started = E2E.now
      loop do
        left = total.nil? ? Transport::API_WAIT_MAX : [0.0, total - (E2E.now - started)].max
        t = [Transport::API_WAIT_MAX, left.ceil].min
        r = desk_call(E2E::DeskOp.new(Args.check_desk(desk_id), "job_wait", { "name" => name, "timeout_ms" => t * 1000 }, "GET",
                                      path, query: { "timeout" => t }, call: call))
        held_failure(r, path)
        over = !total.nil? && E2E.now - started >= total
        return r if !r["timed_out"] || over || total&.zero?
      end
    end

    # <tt>GET /desks/{id}/jobs</tt>: the jobs.
    def jobs(desk_id, call: {})
      list_of(desk_call(E2E::DeskOp.new(Args.check_desk(desk_id), "job_list", {}, "GET", "#{desk_path(desk_id)}/jobs", call: call)),
              "jobs", "GET /desks/#{desk_id}/jobs")
    end

    # <tt>DELETE /desks/{id}/jobs/{name}</tt>: the Job, stopped.
    def kill_job(desk_id, name, call: {})
      desk_call(E2E::DeskOp.new(Args.check_desk(desk_id), "job_kill", { "name" => name }, "DELETE", job_path(desk_id, name),
                                call: call))
    end

    # <tt>GET /desks/{id}/jobs/{name}/logs</tt>: the JobLogs (+job+ and +output+).
    def job_logs(desk_id, name, tail: nil, call: {})
      req = logs_request(name, tail, false)
      desk_call(E2E::DeskOp.new(Args.check_desk(desk_id), "job_logs", req, "GET", "#{job_path(desk_id, name)}/logs",
                                query: { "tail" => tail }, call: call))
    end

    # <tt>GET …/logs?follow=1</tt>: the JobLogEvents as a {Stream}.
    def follow_job_logs(desk_id, name, tail: nil, call: {})
      op = E2E::DeskOp.new(Args.check_desk(desk_id), "job_logs", logs_request(name, tail, true), "GET", "#{job_path(desk_id, name)}/logs",
                           query: { "follow" => 1, "tail" => tail }, sealed_query: { "follow" => 1 }, accept: "text/event-stream",
                           call: call)
      stream_of(op, "logs", name)
    end

    # <tt>GET /desks/{id}/stats</tt>: the StatsReport.
    def stats(desk_id, call: {})
      desk_call(E2E::DeskOp.new(Args.check_desk(desk_id), "stats", {}, "GET", "#{desk_path(desk_id)}/stats", call: call))
    end

    # <tt>PUT /desks/{id}/files?path=</tt>: one local file (a path or an IO; at most 256 MB).
    # A +remote+ ending in +/+ keeps the file's name.
    def upload(local, desk_id, remote, size: nil, call: {})
      return upload_io(local, desk_id, remote, size, call) if local.respond_to?(:read)

      path = local.to_s
      if File.directory?(path)
        raise UsageError.new("#{path} is a folder; the HTTP API copies single files", kind: "usage", argv: ["upload"])
      end

      target = remote.to_s.empty? || remote.to_s.end_with?("/", "\\") ? remote.to_s + basename(path) : remote.to_s
      begin
        File.open(path, "rb") { |file| upload_io(file, desk_id, target, file.size, call) }
      rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => e
        raise Error.new("cannot read #{path}: #{e.message}", kind: "local", argv: ["upload"])
      end
    end

    # <tt>PUT /desks/{id}/files?path=</tt> with bytes in memory.
    def upload_bytes(data, desk_id, remote, call: {})
      b = data.to_s.b
      check_size(b.bytesize)
      put_file(desk_id, remote, E2E::Upload.new(b, b.bytesize), call)
    end

    # <tt>GET /desks/{id}/files?path=</tt>: the file's bytes (a binary String).
    def download_bytes(desk_id, remote, call: {})
      buf = +"".b
      download_stream(desk_id, remote, call: call) { |b| buf << b }
      buf
    end

    # <tt>GET /desks/{id}/files?path=</tt> into +local+: a path (a folder, or a path ending in a
    # separator, keeps the remote name) or an IO. The CopyResult.
    def download(desk_id, remote, local, call: {})
      started = E2E.now
      if local.respond_to?(:write)
        n = 0
        sealed = download_stream(desk_id, remote, call: call) do |b|
          local.write(b)
          n += b.bytesize
        end
        return copy_result(desk_id, local.respond_to?(:path) ? local.path.to_s : "", n, started, sealed)
      end
      dest = if local.to_s.end_with?("/",
                                     File::SEPARATOR) || File.directory?(local.to_s)
               File.join(local.to_s, basename(remote))
             else
               local.to_s
             end
      # Into a file beside it, renamed over it once whole: a download that fails leaves no
      # partial file (and an earlier file at +dest+ as it was).
      part = File.join(File.dirname(dest), ".#{File.basename(dest)}.#{SecureRandom.hex(6)}.part")
      begin
        r = File.open(part, "wb") { |f| download(desk_id, remote, f, call: call) }
        File.rename(part, dest)
        r.merge("destination" => dest)
      rescue SystemCallError => e
        raise Error.new("cannot write #{dest}: #{e.message}", kind: "local", argv: ["download"])
      ensure
        FileUtils.rm_f(part)
      end
    end

    # <tt>GET /desks/{id}/files?path=</tt>, the bytes to the block as they arrive. Returns the
    # desk's CopyResult when the download was sealed (it carries one), else +nil+.
    def download_stream(desk_id, remote, call: {}, &block)
      raise UsageError.new("a remote path is required", kind: "usage") if remote.to_s.empty?

      op = E2E::DeskOp.new(Args.check_desk(desk_id), "file_get", { "path" => remote.to_s }, "GET", "#{desk_path(desk_id)}/files",
                           query: { "path" => remote.to_s }, accept: Transport::OCTET_TYPE, call: call)
      desk_send(op) do |res, seal|
        if seal
          E2E.read_sealed_file(res, seal, "GET files", &block)
        else
          res.read_body { |b| yield b.b unless b.empty? } # Ruby 3.1's Net::HTTP yields an empty first piece
          nil
        end
      end
    end

    # <tt>POST /desks/{id}/tokens</tt> with a MintSpec, once per desk: one MintResult with every
    # desk's token. If a later desk fails, the error's +json+ carries the tokens already minted
    # (their secrets are shown once).
    def create_token(desks, call: {}, **spec)
      mint = Args.mint_spec(**spec)
      tokens = []
      Array(desks).each do |d|
        begin
          r = desk_call(E2E::DeskOp.new(Args.check_desk(d), "token_mint", { "spec" => mint }, "POST", "#{desk_path(d)}/tokens",
                                        json: mint, call: call))
        rescue Error => e
          e.json = (e.json.is_a?(Hash) ? e.json : {}).merge("tokens" => tokens) unless tokens.empty?
          raise
        end
        unless r.is_a?(Hash) && r["tokens"].is_a?(Array)
          raise ProtocolError.new("the GaiaDesk API minted no tokens", kind: "protocol", argv: ["token_mint"], json: r)
        end

        tokens.concat(r["tokens"])
      end
      { "tokens" => tokens }
    end

    # <tt>GET /desks/{id}/tokens</tt>: the tokens (never their secrets).
    def list_tokens(desk_id, call: {})
      list_of(desk_call(E2E::DeskOp.new(Args.check_desk(desk_id), "token_list", {}, "GET", "#{desk_path(desk_id)}/tokens", call: call)),
              "tokens", "GET /desks/#{desk_id}/tokens")
    end

    # <tt>DELETE /desks/{id}/tokens/{token_id}</tt>: <tt>{"revoked", "stopped_sessions"}</tt>.
    def revoke_token(desk_id, token_id, call: {})
      raise UsageError.new("revoke_token needs the token's id or name", kind: "usage") if token_id.to_s.strip.empty?

      path = "#{desk_path(desk_id)}/tokens/#{URI.encode_www_form_component(token_id.to_s).gsub('+', '%20')}"
      desk_call(E2E::DeskOp.new(Args.check_desk(desk_id), "token_revoke", { "token" => token_id.to_s }, "DELETE", path, call: call))
    end

    private

    def stream_of(op, kind, job = "")
      Stream.new(op.label, kind, job) do |on_response|
        desk_send(op) { |res, seal| on_response.call(res, seal && E2E::EventMapper.new(seal, kind, op.desk)) }
      end
    end

    def job_path(desk_id, name)
      "#{desk_path(desk_id)}/jobs/#{URI.encode_www_form_component(Args.check_job_name(name))}"
    end

    def logs_request(name, tail, follow)
      r = { "name" => name }
      r["tail"] = Integer(tail) unless tail.nil?
      r["follow"] = true if follow
      r
    end

    def held_failure(result, path)
      env = Errors.envelope(result)
      if env
        raise Errors.for_kind(env.kind, env.message.empty? ? "the wait failed" : env.message, env.reason,
                              exit_code: Errors.exit_for(env.kind), argv: ["GET #{path}"], json: result, desk: env.desk,
                              status: result["error"]["status"].is_a?(Integer) ? result["error"]["status"] : nil,
                              request_id: result["error"]["request_id"])
      end
      return if result.is_a?(Hash) && result["job"].is_a?(Hash) && [true, false].include?(result["timed_out"])

      raise ProtocolError.new("the GaiaDesk API answered a wait without a job", kind: "protocol", argv: ["GET #{path}"], json: result)
    end

    def list_of(result, key, op)
      return result[key] if result.is_a?(Hash) && result[key].is_a?(Array)

      raise ProtocolError.new("the GaiaDesk API answered #{op} without {#{key.inspect}: [...]}", kind: "protocol", argv: [op], json: result)
    end

    def basename(path)
      path.to_s.split(%r{[\\/]+}).reject(&:empty?).last.to_s
    end

    def check_size(size)
      return if size <= Transport::API_FILE_LIMIT

      raise UsageError.new("the file is #{size} bytes; the HTTP API takes files up to 256 MB (copy larger ones with gaiadesk-cli)",
                           kind: "usage", argv: ["upload"])
    end

    def upload_io(io, desk_id, remote, size, call)
      raise UsageError.new("a remote path is required", kind: "usage") if remote.to_s.empty?

      size ||= io_size(io)
      check_size(size)
      put_file(desk_id, remote.to_s, E2E::Upload.new(io, size), call)
    end

    def io_size(io)
      return io.size if io.respond_to?(:size) && io.size
      return io.stat.size - io.pos if io.respond_to?(:stat) && io.stat.file?

      raise UsageError.new("upload: give size: for an IO whose size cannot be known", kind: "usage")
    end

    def put_file(desk_id, remote, upload, call)
      path = "#{desk_path(desk_id)}/files"
      r = desk_call(E2E::DeskOp.new(Args.check_desk(desk_id), "file_put", { "path" => remote, "size" => upload.size }, "PUT", path,
                                    query: { "path" => remote }, upload: upload, call: call))
      failed = r.is_a?(Hash) ? r["failed"] : nil
      if failed.is_a?(Array) && !failed.empty?
        raise OperationFailedError.new("#{failed.size} file(s) failed to copy", kind: "failed", exit_code: 1, argv: ["PUT #{path}"],
                                                                                json: r, desk: Args.check_desk(desk_id))
      end
      r
    end

    def copy_result(desk_id, destination, bytes, started, sealed)
      return sealed.merge("destination" => destination) if sealed.is_a?(Hash) && !destination.empty?
      return sealed if sealed.is_a?(Hash)

      { "direction" => "download", "desk" => Args.check_desk(desk_id), "destination" => destination, "files" => 1, "dirs" => 0,
        "bytes" => bytes, "resumed_bytes" => 0, "failed" => [], "seconds" => (E2E.now - started).round(3) }
    end
  end
end
