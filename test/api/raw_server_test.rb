# frozen_string_literal: true

require "test_helper"
require_relative "../support/raw_server"

# A peer that drops or stalls a connection is a typed error within the client's
# timeouts, never a hang: proven on a raw TCP server (no HTTP framework). Every SDK
# call runs bounded, so a hang fails its test in 10 s instead of hanging the suite.
class RawServerTest < Minitest::Test
  D = "123456789"
  DROPS = %i[close_before_response reset_before_response].freeze
  DROPS_AND_BODY = (DROPS + %i[close_after_body]).freeze

  def setup
    @srv = RawServer.new(:silent)
  end

  def teardown
    @srv.close
  end

  def gd(retries: 2, response: 30, idle: 30)
    GaiaDesk::Client.new(api_key: "ak_t", desk_token: "gdagt_t", base_url: @srv.url, e2e: :off, retries: retries,
                         retry_base: 0.005, response_timeout: response, idle_timeout: idle)
  end

  # Runs the block on a thread; fails the test when it has not finished in +secs+.
  def bounded(secs = 10, &)
    th = Thread.new(&)
    th.report_on_exception = false
    unless th.join(secs)
      th.kill

      flunk "hung for more than #{secs} s"
    end
    th.value
  end

  def elapsed
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
  end

  def counts
    { "GET" => @srv.count("GET"), "PUT" => @srv.count("PUT"), "POST" => @srv.count("POST") }
  end

  # ───────────────────────── dropped before any answer byte ─────────────────────────

  def test_a_get_dropped_before_any_answer_is_unreachable_network_and_retried
    DROPS.each do |mode|
      [[2, 3], [0, 1]].each do |retries, sent|
        @srv.mode = mode
        c = gd(retries: retries)
        { "download_bytes" => -> { c.download_bytes(D, "/x") }, "stats" => -> { c.stats(D) } }.each do |what, call|
          @srv.reset_counts
          e = bounded { assert_raises(GaiaDesk::UnreachableError) { call.call } }

          assert_equal "network", e.kind, "#{mode} #{what}"
          assert_equal "network", e.reason
          # The first try and the SDK's retries; Net::HTTP itself re-sends nothing (max_retries 0).
          assert_equal({ "GET" => sent, "PUT" => 0, "POST" => 0 }, counts, "#{mode} #{what} retries #{retries}")
        end
      end
    end
  end

  def test_a_body_dropped_before_any_answer_is_sent_exactly_once
    big = Random.new(7).bytes(4 << 20)
    DROPS_AND_BODY.each do |mode|
      @srv.mode = mode
      c = gd
      calls = {
        "upload (streamed IO)" => ["PUT", -> { c.upload(StringIO.new(big), D, "/big.bin", size: big.bytesize) }],
        "upload_bytes" => ["PUT", -> { c.upload_bytes(big, D, "/big.bin") }],
        "exec" => ["POST", -> { c.exec(D, "echo hi") }],
        "run_job" => ["POST", -> { c.run_job(D, "nightly", "make") }]
      }
      calls.each do |what, (method, call)|
        @srv.reset_counts
        e = bounded { assert_raises(GaiaDesk::UnreachableError) { call.call } }

        assert_equal "network", e.kind, "#{mode} #{what}"
        assert_equal 1, @srv.count(method), "#{mode} #{what}: sent once"
        assert_equal 0, @srv.count("GET"), "#{mode} #{what}"
      end

      @srv.reset_counts
      s = bounded { c.exec_stream(D, "echo hi").tap(&:wait) }

      assert_equal 255, s.wait.exit_code, mode.to_s
      assert_equal "unreachable", s.result["error"]["kind"]
      assert_equal "network", s.result["error"]["reason"]
      assert_equal({ "GET" => 0, "PUT" => 0, "POST" => 1 }, counts, "#{mode} exec_stream")
    end
  end

  # ───────────────────────── stalled mid-answer ─────────────────────────

  def test_a_body_that_stalls_is_connection_lost_timeout_within_idle_timeout
    @srv.mode = :stall_mid_body
    c = gd(idle: 1)
    got = []
    e = nil
    t = elapsed { e = bounded { assert_raises(GaiaDesk::ConnectionLostError) { c.download_stream(D, "/x") { |b| got << b } } } }

    assert_equal ["hello"], got
    assert_equal "timeout", e.kind
    assert_equal "timeout", e.reason
    assert_match(/idle_timeout/, e.message)
    assert_operator t, :<, 5
    assert_equal 1, @srv.count("GET"), "a timeout mid-answer is not retried"

    Dir.mktmpdir do |dir|
      e = bounded { assert_raises(GaiaDesk::ConnectionLostError) { c.download(D, "/x", File.join(dir, "x.bin")) } }

      assert_equal "timeout", e.kind
      assert_empty Dir.children(dir), "no partial file left"
    end
  end

  def test_a_failed_download_keeps_the_file_it_would_have_replaced
    @srv.mode = :stall_mid_body
    Dir.mktmpdir do |dir|
      path = File.join(dir, "x.bin")
      File.binwrite(path, "before")

      bounded { assert_raises(GaiaDesk::ConnectionLostError) { gd(idle: 1).download(D, "/x", path) } }

      assert_equal ["x.bin"], Dir.children(dir)
      assert_equal "before", File.binread(path)
    end
  end

  def test_json_that_stalls_is_connection_lost_timeout
    @srv.mode = :stall_mid_json
    e = nil
    t = elapsed { e = bounded { assert_raises(GaiaDesk::ConnectionLostError) { gd(retries: 0, idle: 1).stats(D) } } }

    assert_equal "timeout", e.kind
    assert_match(/stats: nothing for 1 s \(idle_timeout\)/, e.message)
    assert_operator t, :<, 5
  end

  def test_an_event_stream_that_stalls_ends_connection_lost
    @srv.mode = :stall_mid_events
    c = gd(idle: 1)
    s = c.exec_stream(D, "echo hi")
    out = bounded { s.read_all }

    assert_equal "hi", out["stdout"]
    exit = bounded { s.wait }

    assert_equal 255, exit.exit_code
    assert_equal({ "kind" => "connection_lost", "reason" => "timeout" }, s.result["error"].slice("kind", "reason"))
    assert_match(/idle_timeout/, exit.message)

    logs = c.follow_job_logs(D, "nightly")
    bounded { logs.wait }

    assert_equal 255, logs.wait.exit_code
    assert_equal "connection_lost", logs.result["error"]["kind"]
  end

  # ───────────────────────── silent ─────────────────────────

  def test_a_silent_server_is_unreachable_timeout_within_response_timeout_and_not_retried
    @srv.mode = :silent
    c = gd(response: 1)
    e = nil
    t = elapsed { e = bounded { assert_raises(GaiaDesk::UnreachableError) { c.stats(D) } } }

    assert_equal "timeout", e.kind
    assert_equal "timeout", e.reason
    assert_match(/did not answer GET \S+ within 1 s \(response_timeout\)/, e.message)
    assert_operator t, :<, 5

    e = bounded { assert_raises(GaiaDesk::UnreachableError) { c.upload_bytes("a" * 16_384, D, "/x") } }

    assert_equal "timeout", e.kind
    assert_equal({ "GET" => 1, "PUT" => 1, "POST" => 0 }, counts)
  end

  def test_the_response_timeout_bounds_the_whole_wait_not_each_read
    @srv.mode = :trickle_head
    e = nil
    t = elapsed { e = bounded { assert_raises(GaiaDesk::UnreachableError) { gd(response: 1).stats(D) } } }

    assert_equal "timeout", e.kind
    assert_operator t, :<, 3
  end

  def test_a_stream_is_killed_promptly_while_the_server_is_silent
    @srv.mode = :silent
    s = gd(response: 60).exec_stream(D, "sleep 100")
    sleep 0.2
    s.kill
    exit = bounded(5) { s.wait }

    assert_equal 130, exit.exit_code
  end

  def test_no_limit_waits_past_where_a_limit_would_end
    @srv.mode = :silent
    s = gd(response: nil, idle: nil).exec_stream(D, "x")

    assert_nil s.wait(1.5).exit_code, "still waiting with no limit"
    s.kill

    assert_equal 130, bounded(5) { s.wait }.exit_code
  end

  # ───────────────────────── stress ─────────────────────────

  def test_stress_drops_never_hang_and_bodies_go_once
    c = gd(retries: 1)
    body = "u" * (512 << 10)
    300.times do |i|
      @srv.mode = DROPS_AND_BODY[i % 3]
      e = bounded do
        assert_raises(GaiaDesk::UnreachableError) { i.even? ? c.download_bytes(D, "/x") : c.upload_bytes(body, D, "/x") }
      end

      assert_equal "network", e.kind, "iteration #{i} (#{@srv.mode})"
    end

    assert_equal 150, @srv.count("PUT")
    assert_equal 300, @srv.count("GET"), "150 downloads, each retried once"
  end

  # ───────────────────────── the local transport over a Unix socket ─────────────────────────

  def test_the_local_transport_times_out_too
    skip "no Unix sockets here" if Gem.win_platform? || !defined?(UNIXServer)

    Dir.mktmpdir do |dir|
      path = File.join(dir, "api.sock")
      srv = RawServer.new(:silent, server: UNIXServer.new(path))
      begin
        c = GaiaDesk::Client.new(transport: :local, socket_path: path, desk_token: "gdagt_t", retries: 0,
                                 response_timeout: 1, idle_timeout: 1)
        e = bounded { assert_raises(GaiaDesk::UnreachableError) { c.stats(D) } }

        assert_equal "timeout", e.kind
        assert_match(/local API .*\(response_timeout\)/, e.message)
        srv.mode = :stall_mid_json
        e = bounded { assert_raises(GaiaDesk::ConnectionLostError) { c.stats(D) } }

        assert_equal "timeout", e.kind
      ensure
        srv.close
      end
    end
  end

  # ───────────────────────── options ─────────────────────────

  def test_timeouts_are_validated
    [0, -1, "5", Float::INFINITY, Float::NAN].each do |bad|
      %i[response_timeout idle_timeout].each do |opt|
        assert_raises(GaiaDesk::UsageError, "#{opt}: #{bad.inspect}") { GaiaDesk.new(api_key: "k", opt => bad) }
        assert_raises(GaiaDesk::UsageError) { GaiaDesk.new(transport: :local, token: "t", opt => bad) }
        assert_raises(GaiaDesk::UsageError) do
          GaiaDesk.new(transport: :lan, base_url: "https://x:7443/v1", fingerprint: "ab" * 32, desk_token: "gdagt_x", opt => bad)
        end
      end
    end
    assert_raises(GaiaDesk::UsageError) { GaiaDesk.new(api_key: "k", timeout: 5, idle_timeout: 10) }

    t = GaiaDesk.new(api_key: "k").transport

    assert_equal [960, 90], [t.response_timeout, t.idle_timeout]
    t = GaiaDesk.new(api_key: "k", response_timeout: nil, idle_timeout: nil).transport

    assert_equal [nil, nil], [t.response_timeout, t.idle_timeout]
    t = GaiaDesk.new(api_key: "k", response_timeout: 0.5, idle_timeout: 2).transport

    assert_equal [0.5, 2], [t.response_timeout, t.idle_timeout]
    t = GaiaDesk.new(api_key: "k", timeout: 7).transport

    assert_equal [7, 7], [t.response_timeout, t.idle_timeout], "0.1.0's timeout sets both"
  end

  def test_net_http_never_resends_by_itself
    lan = GaiaDesk.new(transport: :lan, base_url: "https://x:7443/v1", fingerprint: "ab" * 32, desk_token: "gdagt_x")
    local = GaiaDesk.new(transport: :local, token: "t", socket_path: "/nowhere.sock")

    [gd, lan, local].each do |c|
      assert_equal 0, c.transport.connection.max_retries, c.backend
    end
  end
end
