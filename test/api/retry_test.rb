# frozen_string_literal: true

require "test_helper"
require_relative "../support/raw_server"

# The retry rule (the README's "Retries"), the same in every GaiaDesk SDK, on a raw TCP
# server: what is sent again, how often, and what never is. Every call is bounded, so a
# hang fails its test in 10 s.
class RetryTest < Minitest::Test
  D = "123456789"

  def setup
    @srv = RawServer.new(:ok)
  end

  def teardown
    @srv.close
  end

  def gd(retries: 2, base: 0.005, url: @srv.url, **kw)
    GaiaDesk::Client.new(api_key: "ak_t", desk_token: "gdagt_t", base_url: url, e2e: :off, retries: retries, retry_base: base,
                         response_timeout: 30, idle_timeout: 30, **kw)
  end

  def bounded(secs = 10, &)
    th = Thread.new(&)
    th.report_on_exception = false
    unless th.join(secs)
      th.kill

      flunk "hung for more than #{secs} s"
    end
    th.value
  end

  def counts
    %w[GET PUT POST DELETE].to_h { |m| [m, @srv.count(m)] }
  end

  # Each call by method: a GET, an exec POST, an upload PUT, a DELETE, a POST with an Idempotency-Key.
  def calls(c)
    { "GET" => -> { c.stats(D) },
      "POST" => -> { c.exec(D, "echo hi") },
      "PUT" => -> { c.upload_bytes("data", D, "/x") },
      "DELETE" => -> { c.kill_job(D, "nightly") },
      "POST keyed" => -> { c.exec(D, "echo hi", idempotency_key: "run-1") } }
  end

  # Runs each call with the server in +mode+; yields the method, the error (or nil) and how often it arrived.
  def each_call(client)
    calls(client).each do |what, call|
      @srv.reset_counts
      err = bounded do
        call.call
        nil
      rescue GaiaDesk::Error => e
        e
      end
      method = what.split.first
      yield what, err, @srv.count(method)
    end
  end

  # ───────────────────────── the connection was never made ─────────────────────────

  def test_a_refused_connect_is_retried_for_any_method_until_the_server_appears
    port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    late = nil
    opener = Thread.new do
      sleep 0.1
      late = RawServer.new(:ok, server: TCPServer.new("127.0.0.1", port))
    end
    r = bounded { gd(retries: 4, base: 0.1, url: "http://127.0.0.1:#{port}/v1").exec(D, "echo hi") }
    opener.join

    assert_equal 0, r["exit"]
    assert_equal 1, late.count("POST"), "the server saw exactly one POST"
  ensure
    opener&.join
    late&.close
  end

  def test_a_refused_connect_with_no_retries_fails_at_once
    port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    e = bounded { assert_raises(GaiaDesk::UnreachableError) { gd(retries: 0, url: "http://127.0.0.1:#{port}/v1").exec(D, "x") } }

    assert_equal "network", e.kind
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t, :<, 1
  end

  # ───────────────────────── lost after sending ─────────────────────────

  def test_a_connection_lost_before_any_answer_is_retried_for_a_get_only
    %i[close_before_response reset_before_response].each do |mode|
      @srv.mode = mode
      each_call(gd) do |what, err, n|
        assert_kind_of GaiaDesk::UnreachableError, err, "#{mode} #{what}"
        assert_equal "network", err.kind
        assert_equal(what == "GET" ? 3 : 1, n, "#{mode} #{what}")
      end
    end
  end

  # ───────────────────────── statuses ─────────────────────────

  def test_502_503_504_are_retried_for_a_get_only
    @srv.mode = :status
    [502, 503, 504].each do |code|
      @srv.status = [code, nil, nil]
      each_call(gd) do |what, err, n|
        assert_equal code, err&.status, "#{code} #{what}"
        assert_equal(what == "GET" ? 3 : 1, n, "#{code} #{what}")
      end
    end
  end

  def test_a_permanent_503_is_not_retried
    @srv.mode = :status
    %w[api_disabled desk_ops_disabled local_api_off].each do |reason|
      @srv.status = [503, nil, reason]
      @srv.reset_counts
      e = bounded { assert_raises(GaiaDesk::Error) { gd.stats(D) } }

      assert_equal 503, e.status
      assert_equal 1, @srv.count("GET"), reason
    end
  end

  def test_a_503_waits_for_its_retry_after
    @srv.mode = :status
    @srv.status = [503, "1", nil]
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    bounded { assert_raises(GaiaDesk::Error) { gd(retries: 1).stats(D) } }

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t, :>=, 0.95
    assert_equal 2, @srv.count("GET")
  end

  def test_429_and_a_key_in_flight_are_retried_for_any_method
    @srv.mode = :status
    [[429, "0", "rate_limited"], [429, nil, "desk_busy"], [409, nil, "idempotency_key_in_flight"]].each do |status|
      @srv.status = status
      each_call(gd) do |what, err, n|
        assert_equal status[0], err&.status, "#{status} #{what}"
        assert_equal 3, n, "#{status} #{what}"
      end
    end
  end

  def test_a_retry_after_past_max_retry_wait_is_raised_at_once
    @srv.mode = :status
    @srv.status = [429, "120", "rate_limited"]
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    e = bounded { assert_raises(GaiaDesk::RefusedError) { gd.exec(D, "x") } }

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t, :<, 1
    assert_in_delta 120.0, e.retry_after
    assert_equal 1, @srv.count("POST")
  end

  def test_other_statuses_are_not_retried
    @srv.mode = :status
    [[500, nil, nil], [409, nil, "silent"], [404, nil, "unknown_desk"]].each do |status|
      @srv.status = status
      @srv.reset_counts

      bounded { assert_raises(GaiaDesk::Error) { gd.stats(D) } }

      assert_equal 1, @srv.count("GET"), status.inspect
    end
  end

  # ───────────────────────── timeouts ─────────────────────────

  def test_timeouts_are_never_retried
    { silent: GaiaDesk::UnreachableError, stall_mid_json: GaiaDesk::ConnectionLostError }.each do |mode, cls|
      @srv.mode = mode
      @srv.reset_counts
      e = bounded { assert_raises(cls) { gd(response_timeout: 0.5, idle_timeout: 0.5).stats(D) } }

      assert_equal "timeout", e.kind
      assert_equal 1, @srv.count("GET"), mode.to_s
    end
  end

  def test_a_connect_timeout_is_kind_timeout_and_not_retried
    connects = 0
    c = gd(open_timeout: 0.2)
    c.transport.define_singleton_method(:connection) do
      connects += 1
      http = super()
      http.define_singleton_method(:connect) { raise Net::OpenTimeout, "execution expired" }
      http
    end
    e = bounded { assert_raises(GaiaDesk::UnreachableError) { c.stats(D) } }

    assert_equal "timeout", e.kind
    assert_match(/open_timeout/, e.message)
    assert_equal 1, connects
  end

  # ───────────────────────── a kept-alive connection the server drops ─────────────────────────

  def test_a_dropped_keep_alive_never_resends_a_change
    @srv.mode = :keep_alive_then_close
    c = gd
    bounded { c.stats(D) }
    calls(c).each do |what, call|
      next if what == "GET"

      @srv.reset_counts
      err = bounded do
        call.call
        nil
      rescue GaiaDesk::Error => e
        e
      end

      assert_equal 1, @srv.count(what.split.first), what
      assert(err.nil? || (err.is_a?(GaiaDesk::UnreachableError) && err.kind == "network"), "#{what}: #{err.inspect}")
    end
  end

  # ───────────────────────── retries off ─────────────────────────

  def test_no_retries_sends_everything_once
    modes = [[:close_before_response], [:reset_before_response], [:status, [502, nil, nil]], [:status, [503, nil, nil]],
             [:status, [429, "0", "rate_limited"]], [:status, [409, nil, "idempotency_key_in_flight"]]]
    modes.each do |mode, status|
      @srv.mode = mode
      @srv.status = status
      each_call(gd(retries: 0)) do |what, err, n|
        refute_nil err, "#{mode} #{status} #{what}"
        assert_equal 1, n, "#{mode} #{status} #{what}"
      end
    end
  end

  # ───────────────────────── the delays ─────────────────────────

  def test_the_backoff
    t = GaiaDesk::Client.new(api_key: "k").transport

    assert_equal [2, 0.25, 8.0, 60.0], [t.retries, t.retry_base, t.retry_max_delay, t.max_retry_wait]
    assert_in_delta 0.125, GaiaDesk::Transport.backoff(0, random: 0)
    assert_in_delta 0.25, GaiaDesk::Transport.backoff(0, random: 1)
    assert_in_delta 0.5, GaiaDesk::Transport.backoff(1, random: 1)
    assert_in_delta 8.0, GaiaDesk::Transport.backoff(10, random: 1), 0.001, "capped at 8 s"
    assert_in_delta 4.0, GaiaDesk::Transport.backoff(10, random: 0)
    200.times do
      d = GaiaDesk::Transport.backoff(2)

      assert_operator d, :>=, 0.5
      assert_operator d, :<=, 1.0
    end
    assert_in_delta 3.0, GaiaDesk::Transport.backoff(5, base: 1, cap: 3, random: 1)
  end

  def test_retry_options_are_validated
    [-1, Float::NAN, Float::INFINITY, "1"].each do |bad|
      %i[retry_base retry_max_delay max_retry_wait].each do |opt|
        assert_raises(GaiaDesk::UsageError, "#{opt} #{bad.inspect}") { GaiaDesk.new(api_key: "k", opt => bad) }
      end
    end
    assert_raises(GaiaDesk::UsageError) { GaiaDesk.new(api_key: "k", retries: -1) }
    assert_raises(GaiaDesk::UsageError) { GaiaDesk.new(api_key: "k", retries: 1.5) }
    assert_equal 0, GaiaDesk.new(api_key: "k", retries: 0).transport.retries
  end
end
