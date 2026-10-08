# frozen_string_literal: true

require "test_helper"

class ErrorsTest < Minitest::Test
  Errs = GaiaDesk::Errors

  def test_envelope
    env = Errs.envelope({ "error" => { "kind" => "refused", "message" => "no", "reason" => "missing_scope", "desk" => "123456789" } })

    assert_equal %w[refused no missing_scope 123456789], env.to_a
    assert_nil Errs.envelope({ "error" => nil, "exit" => 0 })
    assert_nil Errs.envelope("text")
    assert_nil Errs.envelope({ "error" => { "message" => "no kind" } })
    assert_equal "", Errs.envelope({ "error" => { "kind" => "failed" } }).message
  end

  def test_kinds_pick_classes
    { "usage" => GaiaDesk::UsageError, "refused" => GaiaDesk::RefusedError, "unreachable" => GaiaDesk::UnreachableError,
      "connection_lost" => GaiaDesk::ConnectionLostError, "failed" => GaiaDesk::OperationFailedError,
      "protocol" => GaiaDesk::ProtocolError, "new_kind" => GaiaDesk::Error }.each do |kind, cls|
      e = Errs.for_kind(kind, "m")

      assert_instance_of cls, e
      assert_equal kind, e.kind
    end
  end

  def test_known_reasons_become_the_kind
    e = Errs.for_kind("unreachable", "gone", "offline")

    assert_equal "offline", e.kind
    assert_equal "offline", e.reason
    e = Errs.for_kind("refused", "no", "missing_scope")

    assert_equal "refused", e.kind
    assert_equal "missing_scope", e.reason
  end

  def test_exit_codes
    assert_equal 254, Errs.exit_for("refused")
    assert_equal 1, Errs.exit_for("failed")
    assert_equal 130, Errs.exit_for("interrupted")
    assert_equal 255, Errs.exit_for("protocol")
  end

  def test_every_error_is_a_standard_error
    assert_operator GaiaDesk::Error, :<, StandardError
    assert_operator GaiaDesk::FingerprintMismatchError, :<, GaiaDesk::UnreachableError
    assert_operator GaiaDesk::Webhook::SignatureError, :<, GaiaDesk::Error
  end

  def result(exit_code, error: nil, remote_code: exit_code, timed_out: false)
    { "desk" => "123456789", "exit" => exit_code, "remote_code" => remote_code, "error" => error, "timed_out" => timed_out }
  end

  def test_exec_outcome_returns_a_non_zero_exit
    r = result(3)

    assert_same r, Errs.exec_outcome(r, false, "op")
  end

  def test_exec_outcome_check
    e = assert_raises(GaiaDesk::CommandError) { Errs.exec_outcome(result(3), true, "op") }
    assert_equal 3, e.result["exit"]
    assert_equal "failed", e.kind
    assert_match(/exited 3/, e.message)
    e = assert_raises(GaiaDesk::CommandError) do
      Errs.exec_outcome(result(124, remote_code: nil, timed_out: true, error: { "kind" => "failed", "message" => "t" }), true, "op")
    end
    assert_match(/timed out/, e.message)
  end

  def test_exec_outcome_a_failed_run_is_a_result
    r = result(124, remote_code: nil, timed_out: true, error: { "kind" => "failed", "message" => "timed out", "reason" => "timeout" })

    assert_same r, Errs.exec_outcome(r, false, "op")
  end

  def test_exec_outcome_never_ran
    r = result(255, remote_code: nil, error: { "kind" => "failed", "message" => "could not start" })
    assert_raises(GaiaDesk::OperationFailedError) { Errs.exec_outcome(r, false, "op") }
  end

  def test_exec_outcome_refused_admin
    GaiaDesk::ADMIN_REASONS.each do |reason|
      r = result(254, remote_code: nil, error: { "kind" => "refused", "message" => "no", "reason" => reason })
      e = assert_raises(GaiaDesk::RefusedError) { Errs.exec_outcome(r, false, "op") }
      assert_predicate e, :admin_refusal?
      assert_equal reason, e.reason
      assert_equal 254, e.exit_code
      assert_equal "123456789", e.desk
    end
    refute_predicate Errs.for_kind("refused", "x", "missing_scope"), :admin_refusal?
  end

  def test_blocked_by_os_policy_is_a_failed_result
    r = result(1, error: { "kind" => "failed", "message" => "blocked", "reason" => "blocked_by_os_policy" })

    assert_equal "blocked_by_os_policy", Errs.exec_outcome(r, false, "op")["error"]["reason"]
  end
end
