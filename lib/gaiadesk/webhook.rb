# frozen_string_literal: true

require "json"
require "openssl"

module GaiaDesk
  # Verifying the webhook deliveries GaiaDesk POSTs to your endpoint.
  #
  # Each delivery carries <tt>GaiaDesk-Signature: t=<unix seconds>,v1=<hex></tt>, where
  # +v1+ is the HMAC-SHA256 of <tt>"<t>.<raw body>"</tt> keyed with the subscription's
  # secret (+whsec_…+). Recompute it over the raw bytes, compare in constant time, and
  # reject a +t+ more than five minutes from now. De-duplicate by the event id
  # (<tt>GaiaDesk-Event-Id</tt>): delivery is at least once.
  #
  # @example A Rack / Rails endpoint
  #   event = GaiaDesk::Webhook.construct_event(request.raw_post, request.headers["GaiaDesk-Signature"], ENV["GAIADESK_WEBHOOK_SECRET"])
  #   case event["type"]
  #   when "desk.offline" then ...
  #   end
  module Webhook
    # The header carrying the signature.
    SIGNATURE_HEADER = "GaiaDesk-Signature"
    # How far +t+ may be from now, in seconds.
    TOLERANCE = 300

    # A delivery that did not verify.
    class SignatureError < Error; end

    module_function

    # Whether +header+ is a valid signature of +raw_body+ under +secret+.
    # @param secret [String] the subscription's +whsec_…+ secret
    # @param header [String] the <tt>GaiaDesk-Signature</tt> header
    # @param raw_body [String] the request body exactly as received
    # @param now [Integer] the current Unix time
    # @param tolerance [Integer] seconds +t+ may be off
    # @return [Boolean]
    def verify(secret, header, raw_body, now: Time.now.to_i, tolerance: TOLERANCE)
      parts = header.to_s.split(",").to_h do |p|
        k, v = p.strip.split("=", 2)
        [k, v]
      end
      t = parts["t"]
      return false unless t&.match?(/\A\d+\z/) && (now - t.to_i).abs <= tolerance

      got = parts["v1"].to_s
      return false unless got.match?(/\A[0-9a-f]{64}\z/)

      want = OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, "#{t}.#{raw_body}")
      secure_compare(want, got)
    end

    # The delivery's event (a Hash) once its signature verifies.
    # @raise [SignatureError] when it does not, or the body is not a JSON object
    # @return [Hash] <tt>{"id", "type", "created", "data"}</tt>
    def construct_event(raw_body, header, secret, now: Time.now.to_i, tolerance: TOLERANCE)
      unless verify(secret, header, raw_body, now: now, tolerance: tolerance)
        raise SignatureError.new("the webhook delivery's signature did not verify (or its timestamp is too old)",
                                 kind: "refused", reason: "bad_signature")
      end

      event = JSON.parse(raw_body)
      raise SignatureError.new("the webhook delivery is not a JSON object", kind: "protocol", reason: "bad_body") unless event.is_a?(Hash)

      event
    rescue JSON::ParserError
      raise SignatureError.new("the webhook delivery is not JSON", kind: "protocol", reason: "bad_body")
    end

    # The signature header GaiaDesk would send for +raw_body+ at time +t+ (for tests).
    def sign(secret, raw_body, t: Time.now.to_i)
      "t=#{t},v1=#{OpenSSL::HMAC.hexdigest('SHA256', secret.to_s, "#{t}.#{raw_body}")}"
    end

    def secure_compare(a, b)
      return false unless a.bytesize == b.bytesize

      if OpenSSL.respond_to?(:fixed_length_secure_compare)
        OpenSSL.fixed_length_secure_compare(a, b)
      else
        a.bytes.zip(b.bytes).reduce(0) { |acc, (x, y)| acc | (x ^ y) }.zero?
      end
    end
  end
end
