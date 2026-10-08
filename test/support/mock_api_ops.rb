# frozen_string_literal: true

# MockApi's desk operations: credentials, sealed or plaintext requests, and every
# outcome rendered in the clear or sealed, as JSON, SSE, a file, or a held answer.
class MockApi
  attr_reader :waits

  def route_of(method, rest)
    case rest
    when "/exec" then [OPS[[method, "exec"]], nil]
    when "/jobs" then [OPS[[method, "jobs"]], nil]
    when %r{\A/jobs/([^/]+)\z} then [OPS[[method, "job"]], Regexp.last_match(1)]
    when %r{\A/jobs/([^/]+)/logs\z} then [OPS[[method, "logs"]], Regexp.last_match(1)]
    when %r{\A/jobs/([^/]+)/wait\z} then [OPS[[method, "wait"]], Regexp.last_match(1)]
    when "/stats" then [OPS[[method, "stats"]], nil]
    when "/files" then [OPS[[method, "files"]], nil]
    when "/tokens" then [OPS[[method, "tokens"]], nil]
    when %r{\A/tokens/([^/]+)\z} then [OPS[[method, "token"]], URI.decode_www_form_component(Regexp.last_match(1))]
    else [nil, nil]
    end
  end

  def scopes_of(_token)
    %w[exec jobs cp]
  end

  def desk_op(req, res, desk, rest)
    op, arg = route_of(req.method, rest)
    return error(res, "unreachable", "no such route", "no_such_route") if op.nil?

    token = req.header("x-gaiadesk-desk-token")
    key = req.header("authorization").to_s.start_with?("Bearer ak_")
    if key && token.nil? && @mode == :api
      return error(res, "refused", "an API key needs an agent token (X-GaiaDesk-Desk-Token) for desk operations", "agent_token_required")
    end
    if op.start_with?("token_") && token
      return error(res, "refused", "token administration is the desk owner's", "agent_cannot_admin", desk: desk.id)
    end
    return error(res, "refused", "this token was revoked", "token_revoked", desk: desk.id) if token == "gdagt_revoked"

    sealed = sealed_request(req, res, desk, op)
    return if sealed == :answered

    if sealed.nil? && [REQUIRED_DESK, NOKEY_REQUIRED_DESK].include?(desk.id)
      return error(res, "refused", "this desk requires end-to-end encryption for API commands", "e2e_required", desk: desk.id)
    end

    params = sealed ? sealed.request : plain_params(req, op)
    outcome = run_op(desk, op, arg, params, scopes_of(token), token ? "agent" : "owner", req, sealed)
    render(res, desk, outcome, sealed)
  end

  # The opened DeskSeal, nil for a plaintext request, or :answered when it was refused.
  def sealed_request(req, res, desk, op)
    envelope = if req.method == "POST" && req.body.start_with?('{"e2e"')
                 JSON.parse(req.body)["e2e"]
               elsif req.header("gaiadesk-e2e")
                 JSON.parse(GaiaDesk::E2E.b64decode(req.header("gaiadesk-e2e")))
               end
    return nil if envelope.nil?

    if published_key(desk.id).nil? && desk.id != NOKEY_REQUIRED_DESK
      error(res, "protocol", "this desk cannot open end-to-end encrypted operations", "e2e_unsupported", desk: desk.id)
      return :answered
    end
    nonce = envelope["nonce"]
    if @lock.synchronize { @seen_nonces[nonce].tap { @seen_nonces[nonce] = true } }
      error(res, "refused", "this sealed request was opened before", "e2e_replayed", desk: desk.id)
      return :answered
    end
    begin
      ds = DeskSeal.open(secret_for(desk.id), desk.id, op, envelope)
    rescue GaiaDesk::E2E::OpenError, ArgumentError, JSON::ParserError
      error(res, "refused", "the desk could not open the sealed request", "e2e_decrypt_failed", desk: desk.id)
      return :answered
    end
    if ds.request["op"] != op
      error(res, "refused", "the sealed request is another operation", "e2e_op_mismatch", desk: desk.id)
      return :answered
    end
    ds
  end

  def plain_params(req, op)
    case op
    when "exec", "job_start", "token_mint"
      spec = JSON.parse(req.body)
      { "spec" => spec, "stream" => req.query["stream"] == "1" }
    when "job_logs" then { "tail" => req.query["tail"]&.to_i, "follow" => req.query["follow"] == "1" }
    when "job_wait" then { "timeout_ms" => req.query["timeout"]&.to_i&.*(1000) }
    when "file_put" then { "path" => req.query["path"], "body" => req.body }
    when "file_get" then { "path" => req.query["path"] }
    else {}
    end
  end

  def run_op(desk, op, arg, params, scopes, by, req, sealed)
    case op
    when "exec" then desk.exec(params["spec"], scopes, params["stream"] == true)
    when "job_start" then desk.job_start(params["spec"], by)
    when "job_list" then desk.job_list
    when "job_kill" then desk.job_kill(arg)
    when "job_logs" then desk.job_logs(arg, params["tail"], params["follow"] == true)
    when "job_wait"
      t = params["timeout_ms"] && (params["timeout_ms"] / 1000)
      (@waits ||= []) << t
      desk.job_wait(arg, t)
    when "stats" then desk.stats
    when "file_put" then desk.file_put(params["path"], sealed ? open_upload(sealed, req) : params["body"])
    when "file_get" then desk.file_get(params["path"])
    when "token_mint" then desk.token_mint(params["spec"])
    when "token_list" then desk.token_list
    when "token_revoke" then desk.token_revoke(arg)
    end
  end

  def open_upload(sealed, req)
    raise "a sealed upload must be ndjson" unless req.header("content-type") == "application/x-ndjson"

    out = +"".b
    last = false
    req.body.each_line do |line|
      next if line.strip.empty?
      raise "input after the last frame" if last

      last, data = sealed.open_input(JSON.parse(line))
      out << data
    end
    raise "the upload had no last frame" unless last

    out
  end

  # ───────────────────────────── rendering ─────────────────────────────

  def render(res, desk, outcome, sealed)
    case outcome
    when MockDesk::Json then render_json(res, outcome, sealed)
    when MockDesk::Fail then render_fail(res, desk, outcome.error, sealed)
    when MockDesk::Events then render_events(res, outcome, sealed)
    when MockDesk::FileOut then render_file(res, desk, outcome, sealed)
    when MockDesk::Held then render_held(res, desk, outcome, sealed)
    end
  end

  def sealed_answer(sealed, value)
    events = []
    if value.is_a?(Hash) && value["stdout"].is_a?(String) && !value["stdout"].empty?
      events << sealed.seal_event({ "event" => "stdout", "data" => [value["stdout"]].pack("m0") })
    end
    events << sealed.seal_event({ "event" => "exit", "result" => value })
    { "e2e" => { "v" => 1, "events" => events } }
  end

  def sealed_error(sealed, err, status = nil)
    e = { "kind" => err["kind"], "message" => "(sealed: open the last event)", "request_id" => request_id }
    e["reason"] = err["reason"] if err["reason"]
    e["status"] = status if status
    { "error" => e, "e2e" => { "v" => 1, "events" => [sealed.seal_event({ "event" => "error" }.merge(err))] } }
  end

  def render_json(res, outcome, sealed)
    json(res, outcome.status, sealed ? sealed_answer(sealed, outcome.value) : outcome.value)
  end

  def render_fail(res, desk, err, sealed)
    return error(res, err["kind"], err["message"], err["reason"], desk: desk.id) unless sealed

    json(res, status_for(err["kind"], err["reason"]), sealed_error(sealed, err))
  end

  def sse(res, name, data)
    text = ": keep-alive\r\nevent: #{name}\r\ndata: #{JSON.generate(data)}\r\n\r\n".b
    cuts = [3, text.bytesize / 2, text.bytesize - 1, text.bytesize]
    at = 0
    cuts.each do |c|
      res.write(text.byteslice(at, c - at))
      at = c
      sleep 0.002
    end
  end

  def render_events(res, outcome, sealed)
    res.start(200, "Content-Type" => "text/event-stream", "X-Request-Id" => request_id)
    carry = { "stdout" => GaiaDesk::E2E::Utf8Carry.new, "stderr" => GaiaDesk::E2E::Utf8Carry.new }
    outcome.list.each do |ev|
      case ev[0]
      when :sleep then sleep ev[1]
      when :cut then return res.reset
      when :lost then sse(res, "error", { "event" => "error", "exit" => 255, "error" => ev[1] })
      when :forever
        loop do
          send_event(res, outcome.kind, [:stdout, ev[1]], sealed, carry)
          sleep 0.02
        end
      else send_event(res, outcome.kind, ev, sealed, carry)
      end
    end
  end

  def send_event(res, kind, ev, sealed, carry)
    if sealed
      desk_event = case ev[0]
                   when :stdout, :output then { "event" => "stdout", "data" => [ev[1]].pack("m0") }
                   when :stderr then { "event" => "stderr", "data" => [ev[1]].pack("m0") }
                   when :exit then { "event" => "exit", "result" => ev[1] }
                   when :end then { "event" => "exit", "result" => { "job" => ev[1] } }
                   when :interrupted then { "event" => "exit", "result" => { "interrupted" => true } }
                   when :error then { "event" => "error" }.merge(ev[1])
                   end
      return sse(res, "sealed", { "event" => "sealed" }.merge(sealed.seal_event(desk_event)))
    end

    case ev[0]
    when :stdout, :stderr, :output
      stream = ev[0] == :stderr ? "stderr" : "stdout"
      text = carry[stream].decode(ev[1])
      sse(res, ev[0].to_s, { "data" => text }) unless text.empty? # the event name only: the SDK adds it
    when :exit then sse(res, "exit", ev[1].except("stdout", "stderr", "truncated").merge("event" => "exit"))
    when :end then sse(res, "end", { "event" => "end", "job" => ev[1] })
    when :interrupted then sse(res, "interrupted", { "event" => "interrupted" })
    when :error
      sse(res, "error", if kind == "exec"
                          { "event" => "error", "exit" => ev[1]["kind"] == "refused" ? 254 : 255, "error" => ev[1] }
                        else
                          { "event" => "error", "error" => ev[1] }
                        end)
    end
  end

  def render_file(res, desk, outcome, sealed)
    bytes = outcome.bytes
    unless sealed
      if outcome.cut
        res.start(200, "Content-Type" => "application/octet-stream", "Content-Length" => (bytes.bytesize + 100).to_s)
        res.write(bytes)
        return res.reset
      end
      return res.send(200, bytes, "Content-Type" => "application/octet-stream", "X-Request-Id" => request_id)
    end

    res.start(200, "Content-Type" => "application/x-ndjson", "X-Request-Id" => request_id)
    bytes.bytes.each_slice(bytes.bytesize > 1000 ? 16_384 : 7).map { |s| s.pack("C*") }.each do |piece|
      res.write("#{JSON.generate(sealed.seal_event({ 'event' => 'stdout', 'data' => [piece].pack('m0') }))}\n")
    end
    return res.reset if outcome.cut

    result = desk.copy_result("download", "", bytes.bytesize)
    line = JSON.generate(sealed.seal_event({ "event" => "exit", "result" => result }))
    res.write(line[0, 10])
    sleep 0.002
    res.write("#{line[10..]}\n")
  end

  def render_held(res, desk, outcome, sealed)
    res.start(200, "Content-Type" => "application/json", "GaiaDesk-Held" => "1", "X-Request-Id" => request_id)
    3.times do
      res.write(" ")
      sleep outcome.delay / 3
    end
    inner = outcome.outcome
    body = if inner.is_a?(MockDesk::Json)
             sealed ? sealed_answer(sealed, inner.value) : inner.value
           else
             st = status_for(inner.error["kind"], inner.error["reason"])
             if sealed
               sealed_error(sealed, inner.error, st)
             else
               { "error" => inner.error.merge("desk" => desk.id, "status" => st, "request_id" => request_id) }
             end
           end
    res.write(JSON.generate(body))
  end
end
