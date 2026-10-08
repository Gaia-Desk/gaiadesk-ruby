# frozen_string_literal: true

require "json"
require_relative "http_server"
require_relative "mock_desk"
require_relative "e2e_desk"

# A mock of GaiaDesk's /v1 API for the tests, served by TestHTTPServer: every route of
# the contract (desks, reach, wake, audit, webhooks, support sessions, and the desk
# operations relayed to MockDesk), the error envelope with request ids, SSE streams
# written in pieces with keep-alive comments, held waits, and end-to-end encrypted
# desk operations opened and answered with the desk's secret (DeskSeal).
#
# Modes: :api (the hosted API), :local (the desk's own API: one desk, the local admin
# token, no fleet routes), :lan (agent tokens only).
#
# Desks: DESK (plain, no key), E2E_DESK (publishes the vectors' key), REQUIRED_DESK
# (key + e2e_required), NOKEY_REQUIRED_DESK (e2e_required, no key until woken), and
# special ones: LIMITED (429 then fine), HTML (no envelope), OFFLINE (409 silent),
# FLAKY (502 on its first GET).
class MockApi
  DESK = "123456789"
  E2E_DESK = "481902774"
  REQUIRED_DESK = "222333444"
  NOKEY_REQUIRED_DESK = "222333555"
  LIMITED = "999999991"
  HTML = "999999990"
  OFFLINE = "999999992"
  FLAKY = "999999993"
  ADMIN_TOKEN = "gdlocal_test_admin"
  VECTORS = JSON.parse(File.read(File.expand_path("../fixtures/e2e_vectors.json", __dir__)))

  OPS = {
    %w[POST exec] => "exec", %w[POST jobs] => "job_start", %w[GET jobs] => "job_list", %w[DELETE job] => "job_kill",
    %w[GET logs] => "job_logs", %w[GET wait] => "job_wait", %w[GET stats] => "stats", %w[PUT files] => "file_put",
    %w[GET files] => "file_get", %w[POST tokens] => "token_mint", %w[GET tokens] => "token_list", %w[DELETE token] => "token_revoke"
  }.freeze

  attr_reader :desks, :server, :webhooks, :sessions, :hits, :seen_nonces
  attr_accessor :mode, :woken, :rotated

  def initialize(mode = :api, server_kind: :tcp, **server_opts)
    @mode = mode
    @desks = [DESK, E2E_DESK, REQUIRED_DESK, NOKEY_REQUIRED_DESK].to_h { |d| [d, MockDesk.new(d)] }
    @secret = [VECTORS["desk_secret_hex"]].pack("H*")
    @new_secret = ("\x42" * 32).b
    @rotated = false
    @woken = false
    @webhooks = []
    @sessions = []
    @hits = Hash.new(0)
    @seen_nonces = {}
    @rid = 0
    @lock = Mutex.new
    @server = TestHTTPServer.new(server_kind, **server_opts) { |req, res| handle(req, res) }
  end

  def url
    @server.url
  end

  def close
    @server.close
  end

  def log
    @server.log
  end

  def request_id
    @lock.synchronize { @rid += 1 }
    format("req_%024x", @rid)
  end

  # The key a desk opens with now.
  def secret_for(desk)
    desk == E2E_DESK && @rotated ? @new_secret : @secret
  end

  def published_key(desk)
    return nil if desk == DESK || [LIMITED, HTML, OFFLINE, FLAKY].include?(desk)
    return nil if desk == NOKEY_REQUIRED_DESK && !@woken

    GaiaDesk::E2E.b64encode(GaiaDesk::E2E.public_key(secret_for(desk)))
  end

  # ───────────────────────────── replies ─────────────────────────────

  def status_for(kind, reason)
    case kind
    when "usage" then 400
    when "refused" then { "unauthenticated" => 401, "rate_limited" => 429, "desk_busy" => 429 }.fetch(reason, reason == "e2e_required" ? 409 : 403)
    when "unreachable" then if %w[unknown_desk no_such_route].include?(reason)
                              404
                            else
                              (reason == "timeout" ? 504 : 409)
                            end
    when "failed" then 422
    when "protocol" then %w[desk_too_old e2e_unsupported].include?(reason) ? 409 : 502
    else 502
    end
  end

  def json(res, status, value, headers = {})
    res.send(status, JSON.generate(value), { "Content-Type" => "application/json", "X-Request-Id" => request_id }.merge(headers))
  end

  def error(res, kind, message, reason = nil, desk: nil, headers: {}, extra: {})
    e = { "kind" => kind, "message" => message }
    e["reason"] = reason if reason
    e["desk"] = desk if desk
    e["request_id"] = request_id
    json(res, status_for(kind, reason), { "error" => e }.merge(extra), headers)
  end

  # ───────────────────────────── routing ─────────────────────────────

  def handle(req, res)
    @lock.synchronize { @hits["#{req.method} #{req.path}"] += 1 }
    path = req.path.sub(%r{\A/v1}, "")
    return unless authenticated?(req, res)

    case path
    when "/desks" then list_desks(req, res)
    when "/audit" then fleet(req, res) { audit(req, res) }
    when "/webhooks" then fleet(req, res) { webhooks_route(req, res) }
    when %r{\A/webhooks/(wh_[0-9a-f]{16})\z} then fleet(req, res) { delete_webhook(res, Regexp.last_match(1)) }
    when "/support/sessions" then fleet(req, res) { support(req, res) }
    when %r{\A/support/sessions/([^/]+)\z} then fleet(req, res) { support_one(res, Regexp.last_match(1)) }
    when %r{\A/desks/([^/]+)(/.*)?\z} then desk_route(req, res, Regexp.last_match(1), Regexp.last_match(2).to_s)
    else error(res, "unreachable", "no such route", "no_such_route")
    end
  end

  def authenticated?(req, res)
    auth = req.header("authorization").to_s
    tok = req.header("x-gaiadesk-desk-token")
    case @mode
    when :api
      return true if auth.start_with?("Bearer ") && auth.size > 7

      error(res, "refused", "Sign in, or send an API key as `Authorization: Bearer ak_…`.", "unauthenticated")
    when :local
      return true if tok || auth == "Bearer #{ADMIN_TOKEN}"

      error(res, "refused", "a local admin token or an agent token is required", "unauthenticated")
    else
      if auth.include?("gdlocal_")
        return error(res, "refused", "the local admin token works on this machine only", "admin_token_local_only") && false
      end
      return true if tok

      error(res, "refused", "the LAN gateway takes agent tokens only", "unauthenticated")
    end
    false
  end

  def fleet(_req, res)
    return error(res, "unreachable", "served by the hosted API only", "no_such_route") unless @mode == :api

    yield
  end

  def desk_info(id)
    online = id != OFFLINE
    d = { "desk_id" => id, "name" => "desk #{id}", "online" => online, "os" => "macos", "app_version" => "0.10.330",
          "owner" => "you", "sources" => ["account"], "last_seen" => 1_791_300_000,
          "features" => published_key(id) ? %w[desk_op desk_op_e2e] : %w[desk_op], "e2e_pub" => published_key(id),
          "e2e_required" => [REQUIRED_DESK, NOKEY_REQUIRED_DESK].include?(id) }
    d.merge!("offline_since" => 1_791_290_000, "offline_reason" => "silent", "offline_reason_text" => "nothing heard") unless online
    d
  end

  def list_desks(_req, res)
    ids = @mode == :api ? @desks.keys + [OFFLINE] : [DESK]
    json(res, 200, { "devices" => ids.map { |i| desk_info(i) }, "sources" => ["server"], "notes" => [],
                     "identity" => { "account" => "you@example.com", "source" => "api_key" } })
  end

  def desk_route(req, res, id, rest)
    return error(res, "usage", "not a desk id", "bad_desk_id") unless id.match?(/\A\d{9}\z/)
    return error(res, "unreachable", "served by the hosted API only", "no_such_route") if @mode != :api && %w[/reach /wake].include?(rest)
    return error(res, "unreachable", "No desk with this id on this machine.", "unknown_desk", desk: id) if @mode != :api && id != DESK
    return special(req, res, id, rest) if [LIMITED, HTML, OFFLINE, FLAKY].include?(id)

    desk = @desks[id] or return error(res, "unreachable", "No desk with this id on your account or team.", "unknown_desk", desk: id)
    case rest
    when "" then json(res, 200, desk_info(id).merge("wake" => { "doorbell_sockets" => 1, "lan_wake" => true }))
    when "/reach" then reach(req, res, id)
    when "/wake" then wake(req, res, id)
    else desk_op(req, res, desk, rest)
    end
  end

  def special(req, res, id, rest)
    return json(res, 200, desk_info(id)) if rest.empty? && id != HTML

    case id
    when LIMITED
      n = @lock.synchronize { @hits["limited"] += 1 }
      return error(res, "refused", "Over this key's rate limit.", "rate_limited", headers: { "Retry-After" => "0" }) if n == 1

      json(res, 200, { "jobs" => [] })
    when HTML then res.send(502, "<html>bad gateway</html>", "Content-Type" => "text/html", "X-Request-Id" => "req_html")
    when OFFLINE then error(res, "unreachable", "The desk is offline: nothing heard from it.", "silent", desk: id)
    when FLAKY
      n = @lock.synchronize { @hits["flaky #{req.method}"] += 1 }
      return error(res, "connection_lost", "the desk went away", desk: id) if n == 1

      rest == "/stats" ? json(res, 200, { "desk" => id, "cpus" => 4 }) : json(res, 200, { "jobs" => [] })
    end
  end

  # ───────────────────────────── fleet routes ─────────────────────────────

  def reach(req, res, id)
    events = [{ "at" => 1_791_290_000, "online" => false, "reason" => "silent", "reason_text" => "nothing heard" },
              { "at" => 1_791_200_000, "online" => true, "reason" => "registered", "reason_text" => "connected", "version" => "0.10.325" }]
    events = events.first(req.query["limit"].to_i) if req.query["limit"]
    json(res, 200, { "desk_id" => id, "since" => (req.query["since"] || 1_790_700_000).to_i, "events" => events })
  end

  def wake(req, res, id)
    body = req.body.empty? ? {} : JSON.parse(req.body)
    @woken = true
    json(res, 200, { "desk_id" => id, "online" => true, "woke" => true, "already_online" => false,
                     "rang" => { "doorbell" => 1, "lan_helpers" => 1 }, "waited_ms" => body["wait_s"].to_i * 10 },
         req.header("idempotency-key") ? { "Idempotent-Replayed" => "true" } : {})
  end

  AUDIT = (1..12).map do |i|
    { "id" => "ev_#{i}", "action" => i.even? ? "api.execOnDesk" : "desk.session.start", "stream" => "api",
      "occurred_at_ms" => 1_791_000_000_000 - ((i / 2) * 1000), "actor" => { "type" => "user", "id" => "you" }, "metadata" => {} }
  end.freeze

  def audit(req, res)
    q = req.query
    list = AUDIT.select do |e|
      (q["action"].nil? || (q["action"].end_with?(".*") ? e["action"].start_with?(q["action"][0..-2]) : e["action"] == q["action"])) &&
        (q["until_ms"].nil? || e["occurred_at_ms"] <= q["until_ms"].to_i) &&
        (q["since_ms"].nil? || e["occurred_at_ms"] >= q["since_ms"].to_i)
    end
    json(res, 200, { "events" => list.first((q["limit"] || 100).to_i) })
  end

  def webhooks_route(req, res)
    return json(res, 200, { "webhooks" => @webhooks }) if req.method == "GET"

    body = JSON.parse(req.body)
    return error(res, "usage", "url must be https", "bad_url") unless body["url"].to_s.start_with?("https://")

    hook = { "id" => format("wh_%016x", @webhooks.size + 1), "url" => body["url"], "events" => body["events"],
             "description" => body["description"].to_s, "created_at" => 1_791_300_000 }
    @webhooks << hook
    json(res, 201, hook.merge("secret" => "whsec_#{'ab' * 32}"))
  end

  def delete_webhook(res, id)
    hook = @webhooks.find { |h| h["id"] == id } or return error(res, "unreachable", "no such webhook", "unknown_webhook")
    @webhooks.delete(hook)
    json(res, 200, { "deleted" => id })
  end

  def support(req, res)
    if req.method == "GET"
      list = req.query["state"] == "all" ? @sessions : @sessions.reject { |s| %w[ended expired].include?(s["state"]) }
      return json(res, 200, { "sessions" => list.first((req.query["limit"] || 50).to_i) })
    end

    body = JSON.parse(req.body)
    s = { "id" => format("ss_%016x", @sessions.size + 1), "state" => "waiting", "mode" => body["mode"] || "view",
          "customer" => body["customer"] || {}, "customer_present" => false, "customer_verified" => true, "join_code" => "123456789",
          "join_url" => "https://gaiadesk.net/app/support.html#session=x", "desk_id" => nil, "origin" => body["origin"],
          "owner" => "you@example.com", "created_at" => 1_791_300_000, "expires_at" => 1_791_300_000 + (body["expires_in"] || 3600) }
    @sessions << s
    json(res, 201, s.merge("embed_token" => "gdemb_#{'cd' * 32}"))
  end

  def support_one(res, id)
    s = @sessions.find { |x| x["id"] == id } or return error(res, "unreachable", "no such support session", "unknown_support_session")
    json(res, 200, s)
  end
end

require_relative "mock_api_ops"
