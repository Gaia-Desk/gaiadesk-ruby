# frozen_string_literal: true

require "test_helper"

class WebhookTest < Minitest::Test
  W = GaiaDesk::Webhook
  SECRET = "whsec_#{'ab' * 32}".freeze
  BODY = '{"id":"evt_1b2c3d4e5f60718293a4b5c6","type":"desk.offline","created":1791300000,"data":{"desk":{"desk_id":"123456789"}}}'

  def test_a_signature_verifies
    header = W.sign(SECRET, BODY, t: 1_791_300_000)

    assert W.verify(SECRET, header, BODY, now: 1_791_300_010)
    assert_equal "desk.offline", W.construct_event(BODY, header, SECRET, now: 1_791_300_010)["type"]
  end

  def test_the_documented_hmac
    want = OpenSSL::HMAC.hexdigest("SHA256", SECRET, "1791300000.#{BODY}")

    assert_equal "t=1791300000,v1=#{want}", W.sign(SECRET, BODY, t: 1_791_300_000)
  end

  def test_refusals
    header = W.sign(SECRET, BODY, t: 1_791_300_000)

    refute W.verify(SECRET, header, BODY, now: 1_791_300_301), "too old"
    refute W.verify(SECRET, header, BODY, now: 1_791_299_699), "too far ahead"
    refute W.verify("whsec_other", header, BODY, now: 1_791_300_000)
    refute W.verify(SECRET, header, "#{BODY} ", now: 1_791_300_000)
    refute W.verify(SECRET, "garbage", BODY, now: 1_791_300_000)
    refute W.verify(SECRET, nil, BODY, now: 1_791_300_000)
    refute W.verify(SECRET, "t=1791300000,v1=zz", BODY, now: 1_791_300_000)
    e = assert_raises(W::SignatureError) { W.construct_event(BODY, header, SECRET, now: 1_791_400_000) }
    assert_equal "bad_signature", e.reason
  end

  def test_a_body_that_is_not_json
    header = W.sign(SECRET, "nope", t: 5)
    e = assert_raises(W::SignatureError) { W.construct_event("nope", header, SECRET, now: 5) }
    assert_equal "bad_body", e.reason
  end
end
