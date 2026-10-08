# frozen_string_literal: true

require "test_helper"

# The desk-served transports: +local+ over a Unix socket (and the named-pipe IO
# adapter, driven over a socket here), +lan+ over TLS with a pinned certificate.
class LocalLanTest < Minitest::Test
  D = MockApi::DESK

  def unix?
    defined?(UNIXServer) && !Gem.win_platform?
  end

  # ───────────────────────────── helpers (pure) ─────────────────────────────

  def test_local_paths
    env = { "GAIADESK_API_DIR" => "/srv/gd" }

    assert_equal "/srv/gd/api.sock", GaiaDesk::Local.socket_path(env)
    assert_equal "/srv/gd/api-token", GaiaDesk::Local.token_path(env)
    assert_equal File.join(Dir.home, ".gaiadesk", "api.sock"), GaiaDesk::Local.socket_path({ "GAIADESK_API_DIR" => "relative" })
  end

  def test_pipe_names
    assert_equal "\\\\.\\pipe\\gaiadesk-api-ada_lovelace", GaiaDesk::Local.pipe_name({ "USERNAME" => "Ada Lovelace" })
    assert_equal "\\\\.\\pipe\\custom", GaiaDesk::Local.pipe_name({ "GAIADESK_API_PIPE" => "\\\\.\\pipe\\custom" })
    assert_equal "user", GaiaDesk::Local.pipe_user("")
    assert_equal "a" * 64, GaiaDesk::Local.pipe_user("A" * 80)
    assert GaiaDesk::Local.pipe?("//./PIPE/x")
    refute GaiaDesk::Local.pipe?("/tmp/api.sock")
  end

  def test_fingerprints
    fp = (["AB"] * 32).join

    assert_equal (["ab"] * 32).join(":"), GaiaDesk::HTTP.normalize_fingerprint(fp)
    assert_equal (["ab"] * 32).join(":"), GaiaDesk::HTTP.normalize_fingerprint((["ab"] * 32).join(" "))
    assert_raises(GaiaDesk::UsageError) { GaiaDesk::HTTP.normalize_fingerprint("ab:cd") }
    cert, = TestCert.generate

    assert_equal GaiaDesk::HTTP.normalize_fingerprint(OpenSSL::Digest::SHA256.hexdigest(cert.to_der)),
                 GaiaDesk::HTTP.certificate_fingerprint(cert)
  end

  # ───────────────────────────── local ─────────────────────────────

  def with_local
    skip "no Unix sockets here" unless unix?
    Dir.mktmpdir("gd", "/tmp") do |dir|
      api = MockApi.new(:local, server_kind: :unix, unix_path: File.join(dir, "api.sock"))
      File.write(File.join(dir, "api-token"), "#{MockApi::ADMIN_TOKEN}\n")
      yield api, dir
    ensure
      api&.close
    end
  end

  def test_local_with_the_admin_token_file
    with_local do |api, dir|
      gd = GaiaDesk.new(transport: :local, env: { "GAIADESK_API_DIR" => dir })

      assert_equal([D], gd.devices["devices"].map { |d| d["desk_id"] })
      r = gd.exec(D, "echo local")

      assert_equal "local\n", r["stdout"]
      req = api.log.last

      assert_equal "Bearer #{MockApi::ADMIN_TOKEN}", req.header("authorization")
      assert_equal "localhost", req.header("host")
      assert_equal "/v1/desks/#{D}/exec", req.path
      assert_equal({ "command" => "echo local" }, JSON.parse(req.body), "never sealed")
      assert_equal ["/v1/desks", "/v1/desks/#{D}/exec"], api.log.map(&:path), "no key lookup"
    end
  end

  def test_local_with_an_agent_token
    with_local do |api, dir|
      gd = GaiaDesk.new(transport: :local, desk_token: "gdagt_basic", socket_path: File.join(dir, "api.sock"))
      gd.stats(D)
      req = api.log.last

      assert_equal "gdagt_basic", req.header("x-gaiadesk-desk-token")
      assert_nil req.header("authorization")
    end
  end

  def test_local_every_desk_op
    with_local do |api, dir|
      gd = GaiaDesk.new(transport: :local, env: { "GAIADESK_API_DIR" => dir })

      assert_equal("tick\n", gd.exec_stream(D, "slow").then { |s| s.next_chunk.text.tap { s.kill } })
      gd.run_job(D, "j", "quick x")

      assert_equal(["j"], gd.jobs(D).map { |j| j["name"] })
      refute gd.wait_job(D, "j", timeout: 5)["timed_out"]
      assert_equal "line one\nline two\n", gd.follow_job_logs(D, "j").read_all["stdout"]
      gd.upload_bytes("bytes", D, "/tmp/l")

      assert_equal "bytes", gd.download_bytes(D, "/tmp/l")
      assert_equal "line one\nline two\n", gd.job_logs(D, "j")
      assert_equal 8, gd.stats(D)["cpus"]
      assert_equal "killed", gd.kill_job(D, "j")["state"]
      refute(api.log.any? { |r| r.query.key?("wake_s") })
    end
  end

  def test_local_does_not_serve_the_fleet_routes
    with_local do |_api, dir|
      gd = GaiaDesk.new(transport: :local, env: { "GAIADESK_API_DIR" => dir })

      %i[webhooks support_sessions audit].each { |m| assert_raises(GaiaDesk::UsageError) { gd.public_send(m) } }
      assert_raises(GaiaDesk::UsageError) { gd.desk(D) }
      assert_raises(GaiaDesk::UsageError) { gd.wake(D) }
      e = assert_raises(GaiaDesk::UnreachableError) { gd.stats("987654321") }
      assert_equal "unknown_desk", e.kind
    end
  end

  def test_local_with_nothing_listening
    skip "no Unix sockets here" unless unix?
    Dir.mktmpdir("gd", "/tmp") do |dir|
      File.write(File.join(dir, "api-token"), "gdlocal_x")
      gd = GaiaDesk.new(transport: :local, env: { "GAIADESK_API_DIR" => dir }, retries: 0)
      e = assert_raises(GaiaDesk::UnreachableError) { gd.devices }
      assert_equal "local_api_unavailable", e.reason
      File.delete(File.join(dir, "api-token"))
      e = assert_raises(GaiaDesk::UnreachableError) { gd.devices }
      assert_equal "local_api_unavailable", e.reason
      assert_match(/no local admin token/, e.message)
    end
  end

  def test_the_pipe_adapter_carries_http
    with_local do |api, dir|
      sock = File.join(dir, "api.sock")
      http = GaiaDesk::HTTP::SocketHTTP.over(-> { GaiaDesk::HTTP::PipeIO.new(UNIXSocket.new(sock)) })
      http.start
      res = http.request(Net::HTTP::Get.new("/v1/desks", "Authorization" => "Bearer #{MockApi::ADMIN_TOKEN}"))
      http.finish

      assert_equal "200", res.code
      assert_equal([D], JSON.parse(res.body)["devices"].map { |d| d["desk_id"] })
      assert_equal 1, api.log.size
    end
  end

  # ───────────────────────────── lan ─────────────────────────────

  def with_lan
    cert, key = TestCert.generate
    api = MockApi.new(:lan, server_kind: :tls, cert: cert, key: key)
    yield api, GaiaDesk::HTTP.certificate_fingerprint(cert)
  ensure
    api&.close
  end

  def test_lan_with_the_pinned_certificate
    with_lan do |api, fp|
      gd = GaiaDesk.new(transport: :lan, base_url: api.url, fingerprint: fp.delete(":").upcase, desk_token: "gdagt_basic")

      assert_equal "lan\n", gd.exec(D, "echo lan")["stdout"]
      s = gd.exec_stream(D, "echo streamed")

      assert_equal "streamed\n", s.read_all["stdout"]
      req = api.log.last

      assert_equal "gdagt_basic", req.header("x-gaiadesk-desk-token")
      assert_nil req.header("authorization")
    end
  end

  def test_lan_with_another_certificate_sends_nothing
    with_lan do |api, _fp|
      gd = GaiaDesk.new(transport: :lan, base_url: api.url, fingerprint: "00" * 32, desk_token: "gdagt_basic", retries: 3)
      e = assert_raises(GaiaDesk::FingerprintMismatchError) { gd.exec(D, "echo never") }
      assert_equal "fingerprint_mismatch", e.reason
      assert_equal "unreachable", e.kind
      assert_match(/did not prove the identity you pinned/, e.message)
      sleep 0.05

      assert_empty api.log, "no request byte was sent"
    end
  end
end
