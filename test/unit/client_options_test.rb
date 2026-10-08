# frozen_string_literal: true

require "test_helper"

class ClientOptionsTest < Minitest::Test
  def with_env(vars)
    old = vars.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def test_api_is_the_default
    gd = GaiaDesk.new(api_key: "ak_x")

    assert_equal "api", gd.backend
    assert_equal "https://api.gaiadesk.net/v1", gd.transport.base_url
  end

  def test_api_key_from_the_environment
    with_env("GAIADESK_API_KEY" => "ak_env", "GAIADESK_DESK_TOKEN" => "gdagt_env") do
      gd = GaiaDesk::Client.new

      assert_equal({ "Authorization" => "Bearer ak_env", "X-GaiaDesk-Desk-Token" => "gdagt_env" }, gd.transport.credentials)
    end
    with_env("GAIADESK_API_KEY" => nil) do
      assert_raises(GaiaDesk::UsageError) { GaiaDesk::Client.new }
    end
  end

  def test_refusals
    assert_raises(GaiaDesk::UsageError) { GaiaDesk.new(api_key: " ") }
    assert_raises(GaiaDesk::UsageError) { GaiaDesk.new(api_key: "k", base_url: "ftp://x") }
    assert_raises(GaiaDesk::UsageError) { GaiaDesk.new(api_key: "k", wake: 121) }
    assert_raises(GaiaDesk::UsageError) { GaiaDesk.new(api_key: "k", e2e: :maybe) }
    assert_raises(GaiaDesk::UsageError) { GaiaDesk.new(api_key: "k", e2e_keys: { "1" => "short" }) }
    assert_raises(GaiaDesk::UsageError) { GaiaDesk.new(api_key: "k", desk_token: "") }
    assert_raises(GaiaDesk::UsageError) { GaiaDesk.new(api_key: "k", fingerprint: "ab") }
    assert_raises(GaiaDesk::UsageError) { GaiaDesk.new(transport: :carrier_pigeon) }
    assert_raises(GaiaDesk::UsageError) { GaiaDesk.new(transport: :local, api_key: "k") }
    assert_raises(GaiaDesk::UsageError) { GaiaDesk.new(transport: :local, token: "t", desk_token: "gdagt_x") }
    assert_raises(GaiaDesk::UsageError) { GaiaDesk.new(transport: :lan, base_url: "https://x:7443/v1", fingerprint: "ab" * 32) }
    assert_raises(GaiaDesk::UsageError) { GaiaDesk.new(transport: :lan, base_url: "http://x:7443/v1", fingerprint: "ab" * 32, desk_token: "gdagt_x") }
    assert_raises(GaiaDesk::UsageError) { GaiaDesk.new(transport: :lan, base_url: "https://x:7443/v1", desk_token: "gdagt_x") }
    assert_raises(GaiaDesk::UsageError) { GaiaDesk.new(api_key: "k", retries: -1) }
  end

  def test_per_call_options_are_checked
    gd = GaiaDesk.new(api_key: "k", base_url: "http://127.0.0.1:9/v1")
    assert_raises(GaiaDesk::UsageError) { gd.exec("123456789", "x", wake: 500) }
    assert_raises(GaiaDesk::UsageError) { gd.exec("123456789", "x", idempotency_key: "") }
    assert_raises(GaiaDesk::UsageError) { gd.exec("123456789", "x", idempotency_key: "caf\u00e9") }
    assert_raises(GaiaDesk::UsageError) { gd.exec("not a desk", "x") }
  end

  def test_pinned_keys_are_decoded
    gd = GaiaDesk.new(api_key: "k", e2e: :require, e2e_keys: { 481_902_774 => TestHelpers::VECTORS["desk_pub"] })

    assert_equal "require", gd.transport.e2e.mode
  end

  def test_local_and_lan_build
    Dir.mktmpdir do |dir|
      env = { "GAIADESK_API_DIR" => dir }
      gd = GaiaDesk.new(transport: :local, env: env)

      assert_equal "local", gd.backend
      expected = GaiaDesk::Local.windows? ? "pipe:#{GaiaDesk::Local.pipe_name(env)}" : "unix:#{File.join(dir, 'api.sock')}"

      assert_equal expected, gd.transport.base_url
    end
    lan = GaiaDesk.new(transport: :lan, base_url: "https://gaiadesk-123456789.local:7443/v1", fingerprint: "#{'AB:' * 31}AB",
                       desk_token: "gdagt_x")

    assert_equal "lan", lan.backend
    assert_equal (["ab"] * 32).join(":"), lan.transport.fingerprint
  end
end
