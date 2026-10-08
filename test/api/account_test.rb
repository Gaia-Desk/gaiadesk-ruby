# frozen_string_literal: true

require "test_helper"

# The hosted API's own routes: one desk, reach, wake, audit (with paging), webhooks,
# support sessions; and the error envelope, retries and timeouts on every route.
class AccountTest < Minitest::Test
  D = MockApi::DESK

  def setup
    @api = MockApi.new
    @gd = client(@api)
  end

  def teardown
    @api.close
  end

  def last
    @api.log.last
  end

  def test_desk
    d = @gd.desk(MockApi::E2E_DESK)

    assert_equal TestHelpers::VECTORS["desk_pub"], d["e2e_pub"]
    assert_includes d["features"], "desk_op_e2e"
    assert_equal({ "doorbell_sockets" => 1, "lan_wake" => true }, d["wake"])
    assert_empty last.query, "no wake_s on a fleet route"
  end

  def test_reach
    r = @gd.reach(D, since: Time.at(1_790_000_000), limit: 1)

    assert_equal 1, r["events"].size
    assert_equal({ "since" => "1790000000", "limit" => "1" }, last.query)
    assert_raises(GaiaDesk::UsageError) { @gd.reach(D, limit: "ten") }
  end

  def test_wake
    r = @gd.wake(D, wait: 30, idempotency_key: "wake-1")

    assert r["woke"]
    assert_equal 300, r["waited_ms"]
    assert_equal({ "wait_s" => 30 }, JSON.parse(last.body))
    assert_equal "wake-1", last.header("idempotency-key")
    @gd.wake(D)

    assert_equal({}, JSON.parse(last.body))
    assert_raises(GaiaDesk::UsageError) { @gd.wake(D, wait: 91) }
  end

  def test_audit
    events = @gd.audit(action: "api.*", limit: 2, desk: D, since_ms: Time.at(1_700_000_000), until_ms: 1_800_000_000_000)

    assert_equal 2, events.size
    assert(events.all? { |e| e["action"] == "api.execOnDesk" })
    assert_equal({ "desk" => D, "action" => "api.*", "since_ms" => "1700000000000", "until_ms" => "1800000000000", "limit" => "2" },
                 last.query)
  end

  def test_each_audit_event_pages_through_everything_once
    seen = @gd.each_audit_event(page_size: 3).to_a

    assert_equal MockApi::AUDIT.map { |e| e["id"] }.sort, seen.map { |e| e["id"] }.sort
    assert_equal seen.size, seen.map { |e| e["id"] }.uniq.size
    assert_operator @api.log.size, :>, 3
    lazy = @gd.each_audit_event(page_size: 5)

    assert_equal 2, lazy.first(2).size
    n = 0
    @gd.each_audit_event(action: "api.*", page_size: 2) { n += 1 }

    assert_equal 6, n
  end

  def test_webhooks
    created = @gd.create_webhook(url: "https://example.com/hook", events: %w[desk.online job.finished], description: "ops")

    assert_match(/\Awhsec_/, created["secret"])
    assert_equal([created["id"]], @gd.webhooks.map { |h| h["id"] })
    refute @gd.webhooks.first.key?("secret")
    assert_equal({ "deleted" => created["id"] }, @gd.delete_webhook(created["id"]))
    assert_empty @gd.webhooks
    assert_raises(GaiaDesk::UsageError) { @gd.create_webhook(url: "https://x", events: ["desk.exploded"]) }
    assert_raises(GaiaDesk::UsageError) { @gd.create_webhook(url: "https://x", events: []) }
    assert_raises(GaiaDesk::UsageError) { @gd.delete_webhook("hook") }
    e = assert_raises(GaiaDesk::UsageError) { @gd.create_webhook(url: "http://x", events: ["desk.online"]) }
    assert_equal "bad_url", e.reason
    assert_equal 400, e.status
  end

  def test_support_sessions
    s = @gd.create_support_session(mode: :cobrowse, customer: { name: "Ada", plan: "pro" }, expires_in: "30m",
                                   origin: "https://app.example.com", idempotency_key: "s-1")

    assert_match(/\Agdemb_/, s["embed_token"])
    assert_equal({ "mode" => "cobrowse", "customer" => { "name" => "Ada", "plan" => "pro" }, "expires_in" => 1800,
                   "origin" => "https://app.example.com" }, JSON.parse(last.body))
    assert_equal([s["id"]], @gd.support_sessions.map { |x| x["id"] })
    assert_equal([s["id"]], @gd.support_sessions(state: :all, limit: 5).map { |x| x["id"] })
    assert_equal({ "state" => "all", "limit" => "5" }, last.query)
    assert_equal "waiting", @gd.support_session(s["id"])["state"]
    e = assert_raises(GaiaDesk::UnreachableError) { @gd.support_session("ss_00000000000000ff") }
    assert_equal "unknown_support_session", e.reason
    assert_raises(GaiaDesk::UsageError) { @gd.support_session("nope") }
    assert_raises(GaiaDesk::UsageError) { @gd.create_support_session(mode: :drive) }
    assert_raises(GaiaDesk::UsageError) { @gd.support_sessions(state: :closed) }
  end

  # ───────────────────────────── errors and retries ─────────────────────────────

  def test_unknown_desk
    e = assert_raises(GaiaDesk::UnreachableError) { @gd.stats("111111111") }
    assert_equal "unknown_desk", e.kind
    assert_equal "111111111", e.desk
    assert_equal 404, e.status
    assert_equal 255, e.exit_code
    assert_equal ["GET /desks/111111111/stats"], e.argv
  end

  def test_offline_desk
    e = assert_raises(GaiaDesk::UnreachableError) { @gd.jobs(MockApi::OFFLINE) }
    assert_equal "silent", e.reason
    assert_equal 409, e.status
  end

  def test_an_answer_without_an_envelope
    e = assert_raises(GaiaDesk::ProtocolError) { @gd.jobs(MockApi::HTML) }
    assert_equal 502, e.status
    assert_equal "req_html", e.request_id
  end

  def test_unauthenticated
    gd = GaiaDesk::Client.new(api_key: "x", base_url: @api.url)
    gd.transport.instance_variable_set(:@key, "")
    e = assert_raises(GaiaDesk::RefusedError) { gd.devices }
    assert_equal "unauthenticated", e.reason
    assert_equal 401, e.status
  end

  def test_rate_limited_is_retried_after_retry_after
    assert_equal [], @gd.jobs(MockApi::LIMITED)
    assert_equal 2, @api.hits["GET /v1/desks/#{MockApi::LIMITED}/jobs"]
  end

  def test_rate_limited_without_retries_raises
    gd = client(@api, retries: 0)
    e = assert_raises(GaiaDesk::RefusedError) { gd.jobs(MockApi::LIMITED) }
    assert_equal "rate_limited", e.reason
    assert_equal 429, e.status
    assert_in_delta 0.0, e.retry_after
  end

  def test_a_lost_desk_is_retried_for_a_get_only
    assert_equal 4, @gd.stats(MockApi::FLAKY)["cpus"]
    assert_equal 2, @api.hits["GET /v1/desks/#{MockApi::FLAKY}/stats"]
    e = assert_raises(GaiaDesk::ConnectionLostError) { @gd.exec(MockApi::FLAKY, "echo once") }
    assert_equal 502, e.status
    assert_equal 1, @api.hits["POST /v1/desks/#{MockApi::FLAKY}/exec"]
  end

  def test_nothing_listening_is_a_network_error_after_retries
    port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    gd = GaiaDesk::Client.new(api_key: "k", base_url: "http://127.0.0.1:#{port}/v1", retries: 2, retry_base: 0.001)
    e = assert_raises(GaiaDesk::UnreachableError) { gd.devices }
    assert_equal "network", e.kind
    assert_equal "network", e.reason
  end

  def test_read_timeout
    server = TCPServer.new("127.0.0.1", 0)
    t = Thread.new do
      s = server.accept
      sleep 2
      s.close
    end
    gd = GaiaDesk::Client.new(api_key: "k", base_url: "http://127.0.0.1:#{server.addr[1]}/v1", timeout: 0.2, retries: 0)
    e = assert_raises(GaiaDesk::UnreachableError) { gd.devices }
    assert_match(/Timeout/, e.message)
  ensure
    t&.kill
    server&.close
  end

  def test_a_base_path_prefix_is_kept
    gd = GaiaDesk::Client.new(api_key: "k", base_url: "#{@api.url}/")
    gd.devices

    assert_equal "/v1/desks", last.path
  end
end
