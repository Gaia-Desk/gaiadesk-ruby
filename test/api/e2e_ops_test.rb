# frozen_string_literal: true

require "test_helper"

# End-to-end encrypted desk operations against the mock API, whose desk opens them
# with its own secret: every operation sealed, nothing readable on the wire, and
# every policy branch (pinning, require, e2e_required, a rotated key, answers that
# do not open).
class E2eOpsTest < Minitest::Test
  D = MockApi::E2E_DESK
  E = GaiaDesk::E2E

  def setup
    @api = MockApi.new
    @warnings = []
    @gd = client(@api, desk_token: "gdagt_basic", warnings: @warnings)
  end

  def teardown
    @api.close
  end

  def desk_ops
    @api.log.reject { |r| r.path == "/v1/desks/#{D}" || r.path.end_with?("/wake") }
  end

  # Nothing of +secrets+ in any desk-op request's URL, headers or body.
  def assert_nothing_in_the_clear(*secrets)
    desk_ops.each do |r|
      wire = [r.path, r.query.to_a.join("="), r.headers.to_a.join(":"), r.body].join("\n")

      secrets.each { |s| refute_includes wire, s, "#{r.method} #{r.path} carried #{s.inspect}" }
    end
  end

  def test_exec_sealed
    r = @gd.exec(D, "echo top-secret-output", env: { "TOKEN" => "env-secret" })

    assert_equal "top-secret-output\n", r["stdout"]
    req = desk_ops.last
    body = JSON.parse(req.body)

    assert_equal %w[e2e], body.keys
    assert_equal %w[v pub nonce ciphertext], body["e2e"].keys
    assert_empty @warnings
    assert_nothing_in_the_clear("top-secret-output", "env-secret", "TOKEN")
  end

  def test_admin_not_via_api_comes_back_sealed
    e = assert_raises(GaiaDesk::RefusedError) { @gd.exec(D, "adminwork") }
    assert_equal "admin_not_via_api", e.reason
    e = assert_raises(GaiaDesk::RefusedError) { client(@api).create_token(D, name: "root", scopes: %w[admin]) }
    assert_equal "admin_not_via_api", e.reason
    assert_equal 403, e.status
  end

  def test_exec_stream_sealed
    s = @gd.exec_stream(D, "utf8")

    assert_equal "h\u00e9llo w\u00f6rld \u2713\n", s.read_all["stdout"]
    assert_equal 0, s.wait.exit_code
    assert_equal "exit", s.result["event"]
    req = desk_ops.last

    assert_equal({ "stream" => "1" }, req.query)
    s = @gd.exec_stream(D, "err sealed-stderr")

    assert_equal "sealed-stderr\n", s.read_all["stderr"]
    assert_equal 3, s.exit_code
    assert_nothing_in_the_clear("utf8", "sealed-stderr")
  end

  def test_a_lost_desk_in_a_sealed_stream
    s = @gd.exec_stream(D, "lost")

    assert_equal "partial\n", s.read_all["stdout"]
    assert_equal "connection_lost", s.result["error"]["kind"]
  end

  def test_kill_a_sealed_stream
    s = @gd.exec_stream(D, "slow")

    assert_equal "tick\n", s.next_chunk.text
    s.kill

    assert_equal 130, s.wait(5).exit_code
  end

  def test_jobs_sealed
    @gd.run_job(D, "secretjob", "quick ./deploy --password hunter2", env: { "K" => "v" })

    assert_equal(["secretjob"], @gd.jobs(D).map { |j| j["name"] })
    assert_equal "line one\nline two\n", @gd.job_logs(D, "secretjob")
    assert_equal "two\n", @gd.job_logs(D, "secretjob", tail: 4)
    assert_empty desk_ops.last.query, "tail rides inside the seal"
    chunks = []
    s = @gd.follow_job_logs(D, "secretjob", tail: 100) { |c| chunks << c.text }

    assert_equal "line one\nline two\n", chunks.join
    assert_equal "end", s.result["event"]
    assert_equal({ "follow" => "1" }, desk_ops.last.query)
    r = @gd.wait_job(D, "secretjob", timeout: 30)

    refute r["timed_out"]
    assert_empty desk_ops.last.query, "timeout rides inside the seal"
    assert_equal [30], @api.waits
    assert_equal "killed", @gd.kill_job(D, "secretjob")["state"]
    assert_nothing_in_the_clear("hunter2", "deploy")
  end

  def test_held_waits_sealed
    @gd.run_job(D, "held2", "./x")

    refute @gd.wait_job(D, "held2", timeout: 60)["timed_out"]
    @gd.run_job(D, "heldfail2", "./x")
    e = assert_raises(GaiaDesk::ConnectionLostError) { @gd.wait_job(D, "heldfail2", timeout: 60) }
    assert_match(/went away during the wait/, e.message, "the desk's own message, opened")
  end

  def test_a_sealed_error_opens_to_the_desks_message
    e = assert_raises(GaiaDesk::OperationFailedError) { @gd.kill_job(D, "ghost") }
    assert_equal "no job named ghost", e.message
    assert_equal 422, e.status
  end

  def test_files_sealed
    data = (0..255).to_a.pack("C*") * 500
    r = @gd.upload_bytes(data, D, "/secret/path.bin")

    assert_equal data.bytesize, r["bytes"]
    assert_equal data, @api.desks[D].files["/secret/path.bin"]
    put = desk_ops.find { |x| x.method == "PUT" }

    assert_equal "application/x-ndjson", put.header("content-type")
    assert_empty put.query
    assert_equal E.input_frames_length(data.bytesize), put.body.bytesize
    assert_equal data, @gd.download_bytes(D, "/secret/path.bin")
    io = StringIO.new
    r = @gd.download(D, "/secret/path.bin", io)

    assert_equal data.bytesize, r["bytes"]
    assert_nothing_in_the_clear("/secret/path.bin", "secret")
  end

  def test_empty_and_streamed_uploads_sealed
    @gd.upload_bytes("", D, "/tmp/empty")

    assert_equal "", @api.desks[D].files["/tmp/empty"]
    Dir.mktmpdir do |dir|
      path = File.join(dir, "big.bin")
      File.binwrite(path, "B" * 200_000)
      @gd.upload(path, D, "/tmp/")

      assert_equal "B" * 200_000, @api.desks[D].files["/tmp/big.bin"]
      @gd.download(D, "/tmp/big.bin", File.join(dir, "back.bin"))

      assert_equal "B" * 200_000, File.binread(File.join(dir, "back.bin"))
    end
  end

  def test_sealed_download_errors
    e = assert_raises(GaiaDesk::UsageError) { @gd.download_bytes(D, "/tmp") }
    assert_equal "is_folder", e.reason
    e = assert_raises(GaiaDesk::ConnectionLostError) { @gd.download_bytes(D, "/tmp/cut") }
    assert_match(/ended before the file did/, e.message)
  end

  def test_stats_and_tokens_sealed
    assert_equal 8, @gd.stats(D)["cpus"]
    gd = client(@api)
    t = gd.create_token(D, name: "sealed-name", scopes: %w[exec])["tokens"].first

    assert_equal "sealed-name", t["name"]
    assert_includes gd.list_tokens(D).map { |x| x["name"] }, "sealed-name"
    gd.revoke_token(D, t["id"])

    assert_nothing_in_the_clear("sealed-name")
  end

  def test_off_sends_in_the_clear
    gd = client(@api, desk_token: "gdagt_basic", e2e: :off)
    gd.exec(D, "echo plain")

    assert_equal({ "command" => "echo plain" }, JSON.parse(@api.log.last.body))
    assert_equal 1, @api.log.size, "no key lookup"
  end

  def test_the_key_is_cached
    @gd.stats(D)
    @gd.stats(D)

    assert_equal 1, @api.hits["GET /v1/desks/#{D}"]
  end

  def test_a_pinned_key
    gd = client(@api, desk_token: "gdagt_basic", e2e_keys: { D => TestHelpers::VECTORS["desk_pub"] })

    assert_equal 8, gd.stats(D)["cpus"]
    other = E.b64encode(E.public_key(("\x07" * 32).b))
    gd = client(@api, desk_token: "gdagt_basic", e2e_keys: { D => other })
    @api.server.clear_log
    e = assert_raises(GaiaDesk::EndToEndError) { gd.stats(D) }
    assert_equal "e2e_key_mismatch", e.reason
    assert_equal "e2e", e.kind
    assert_empty desk_ops, "nothing was sent"
  end

  def test_require_with_a_desk_without_a_key
    gd = client(@api, desk_token: "gdagt_basic", e2e: :require)
    e = assert_raises(GaiaDesk::EndToEndError) { gd.stats(MockApi::DESK) }
    assert_equal "e2e_unavailable", e.reason
    assert_equal 1, @api.hits["POST /v1/desks/#{MockApi::DESK}/wake"], "woken and asked again first"
    refute(@api.log.any? { |r| r.path.end_with?("/stats") })
  end

  def test_require_wakes_a_desk_and_seals
    gd = client(@api, desk_token: "gdagt_basic", e2e: :require)

    assert_equal 8, gd.stats(MockApi::NOKEY_REQUIRED_DESK)["cpus"]
    assert @api.woken
  end

  def test_a_desk_that_requires_it_is_sealed_from_the_start
    assert_equal "x\n", @gd.exec(MockApi::REQUIRED_DESK, "echo x")["stdout"]
    assert_empty @warnings
  end

  def test_e2e_required_refusal_is_sent_again_sealed
    gd = client(@api, desk_token: "gdagt_basic")
    # Its info said nothing yet (cached before it published): the plaintext refusal triggers the sealed resend.
    gd.transport.e2e.instance_variable_get(:@cache)[MockApi::REQUIRED_DESK] = [E.now + 300, {}]

    assert_equal "x\n", gd.exec(MockApi::REQUIRED_DESK, "echo x")["stdout"]
    assert_equal 2, @api.hits["POST /v1/desks/#{MockApi::REQUIRED_DESK}/exec"]
  end

  def test_a_rotated_key_is_read_again_once
    @gd.stats(D) # caches the old key
    @api.rotated = true

    assert_equal 8, @gd.stats(D)["cpus"]
    assert_equal 2, @api.hits["GET /v1/desks/#{D}"]
  end

  def test_an_upload_from_a_pipe_is_not_resent
    @gd.stats(D)
    @api.rotated = true
    reader, writer = IO.pipe
    writer.write("abc")
    writer.close
    e = assert_raises(GaiaDesk::RefusedError) { @gd.upload(reader, D, "/tmp/p", size: 3) }
    assert_equal "e2e_decrypt_failed", e.reason
  end

  def test_a_plaintext_answer_to_a_sealed_call_is_refused
    gd = client(@api, desk_token: "gdagt_basic")
    seal = E.seal_request(E.key32(TestHelpers::VECTORS["desk_pub"]), D, "stats", { "op" => "stats" })
    e = assert_raises(GaiaDesk::EndToEndError) { E.unseal_json({ "cpus" => 1 }, seal, "GET stats", 200) }
    assert_equal "e2e_malformed", e.reason
    e = assert_raises(GaiaDesk::EndToEndError) { E.unseal_json({ "e2e" => { "v" => 1, "events" => [] } }, seal, "GET stats", 200) }
    assert_equal "e2e_malformed", e.reason
    tampered = { "seq" => 0, "nonce" => E.b64encode("n" * 24), "ciphertext" => E.b64encode("c" * 40) }
    e = assert_raises(GaiaDesk::EndToEndError) { E.unseal_json({ "e2e" => { "v" => 1, "events" => [tampered] } }, seal, "GET stats", 200) }
    assert_equal "e2e_decrypt_failed", e.reason
    assert_equal "api", gd.backend
  end

  def test_auto_without_a_key_warns_once_per_desk
    @gd.stats(MockApi::DESK)
    @gd.stats(MockApi::DESK)

    assert_equal 1, @warnings.size
    assert_match(/without end-to-end encryption/, @warnings.first)
  end
end
