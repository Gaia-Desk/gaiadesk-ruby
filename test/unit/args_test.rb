# frozen_string_literal: true

require "test_helper"

class ArgsTest < Minitest::Test
  A = GaiaDesk::Args

  def test_seconds
    assert_equal 90, A.seconds(90, "t")
    assert_equal 2, A.seconds(1.2, "t")
    assert_equal 90, A.seconds("90", "t")
    assert_equal 30, A.seconds("30s", "t")
    assert_equal 600, A.seconds("10m", "t")
    assert_equal 5400, A.seconds("1h30m", "t")
    assert_equal 604_800, A.seconds("7d", "t")
    assert_equal 1_209_600, A.seconds("2w", "t")
    %w[-1 abc 10x 1.5h].each { |bad| assert_raises(GaiaDesk::UsageError) { A.seconds(bad, "t") } }
    assert_raises(GaiaDesk::UsageError) { A.seconds(-1, "t") }
    assert_raises(GaiaDesk::UsageError) { A.seconds(true, "t") }
  end

  def test_desk_and_job_names
    assert_equal "123456789", A.check_desk(" 123456789 ")
    ["", " ", "12 34", "-x", nil].each { |bad| assert_raises(GaiaDesk::UsageError) { A.check_desk(bad) } }
    assert_equal "nightly.build_1-a", A.check_job_name("nightly.build_1-a")
    ["-x", "a b", "a/b", ""].each { |bad| assert_raises(GaiaDesk::UsageError) { A.check_job_name(bad) } }
  end

  def test_env
    assert_equal({ "A" => "1", "B" => "" }, A.check_env({ A: "1", "B" => "" }))
    assert_nil A.check_env(nil)
    [{ "A=B" => "x" }, { "" => "x" }, { "A B" => "x" }, { "A" => 1 }, { "A" => "x\0" }].each do |bad|
      e = assert_raises(GaiaDesk::UsageError) { A.check_env(bad) }
      refute_includes e.message, "x\0"
    end
    assert_raises(GaiaDesk::UsageError) { A.check_env([%w[A 1]]) }
  end

  def test_exec_spec
    assert_equal({ "command" => "uname -a" }, A.exec_spec("uname -a"))
    assert_equal({ "argv" => %w[make test], "shell" => "pwsh", "env" => { "CI" => "1" }, "cwd" => "src", "timeout_secs" => 600,
                   "stdin" => "data" },
                 A.exec_spec(%w[make test], shell: :powershell, env: { "CI" => "1" }, cwd: "src", timeout: "10m", stdin: "data"))
    assert_equal "from io", A.exec_spec("cat", stdin: StringIO.new("from io"))["stdin"]
    assert_raises(GaiaDesk::UsageError) { A.exec_spec("") }
    assert_raises(GaiaDesk::UsageError) { A.exec_spec([]) }
    assert_raises(GaiaDesk::UsageError) { A.exec_spec("x", shell: "fish") }
    assert_raises(ArgumentError) { A.exec_spec("x", admin: true) }
    refute_includes A::TOKEN_SCOPES, "admin"
  end

  def test_job_spec
    spec = A.job_spec("nightly", "./build.sh", priority: :low, cpu: 50, mem: "2G", keep_awake: true, cwd: "w", shell: "bash", env: { "X" => "1" })

    assert_equal({ "name" => "nightly", "command" => ["./build.sh"],
                   "limits" => { "priority" => "low", "cpu_percent" => 50, "mem_mb" => 2048, "keep_awake" => true },
                   "cwd" => "w", "shell" => "bash", "env" => { "X" => "1" } }, spec)
    assert_equal 512, A.mem_mb("512M")
    assert_raises(GaiaDesk::UsageError) { A.mem_mb("lots") }
    assert_raises(GaiaDesk::UsageError) { A.job_spec("n", "x", shell: "none") }
    assert_raises(GaiaDesk::UsageError) { A.job_spec("n", "x", shell: "default") }
  end

  def test_mint_spec
    assert_equal({ "name" => "ci", "expires_secs" => 604_800, "scopes" => %w[exec cp jobs] }, A.mint_spec(name: "ci"))
    s = A.mint_spec(name: "ops", expires: "1d", scopes: %w[exec shell])

    assert_equal %w[exec shell], s["scopes"]
    assert_equal 86_400, s["expires_secs"]
    assert_equal({ "name" => "c", "expires_secs" => 60, "scopes" => ["cp"], "cwd" => "/srv", "low_priv" => true },
                 A.mint_spec(name: "c", expires: 60, scopes: ["cp"], cwd: "/srv", low_priv: true))
    assert_raises(GaiaDesk::UsageError) { A.mint_spec(name: "") }
  end
end
