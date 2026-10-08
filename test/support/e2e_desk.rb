# frozen_string_literal: true

require "json"
require "securerandom"

# The DESK's side of an end-to-end encrypted operation, for the mock API: open the
# caller's sealed request with the desk's secret, open its input frames, seal the
# desk's events. Built from the SDK's own primitives, whose bytes the shared vectors pin.
class DeskSeal
  E = GaiaDesk::E2E

  attr_reader :request, :keys

  # Open +envelope+ (the body's +e2e+ or the header's JSON) sealed for operation +op+.
  # Raises E::OpenError when it does not open.
  def self.open(desk_secret, desk, op, envelope)
    desk_pub = E.public_key(desk_secret)
    eph_pub = E.key32(envelope["pub"])
    keys = E.derive(E.exchange(desk_secret, eph_pub), eph_pub, desk_pub)
    plain = E.xchacha_open(keys["request"], E.b64decode(envelope["nonce"]), E.b64decode(envelope["ciphertext"]),
                           E.associated_data("request", desk, op))
    inner = JSON.parse(plain)
    new(keys, desk, op, inner)
  end

  def initialize(keys, desk, op, inner)
    @keys = keys
    @desk = desk
    @op = op
    @inner = inner
    @request = inner["request"]
    @next_event = 0
    @next_input = 0
  end

  def ts
    @inner["ts"]
  end

  # The next event sealed: <tt>{"seq", "nonce", "ciphertext"}</tt>.
  def seal_event(event)
    seq = @next_event
    @next_event += 1
    nonce = SecureRandom.random_bytes(24)
    ct = E.xchacha_seal(@keys["event"], nonce, JSON.generate(event).b, E.associated_data("event", @desk, @op, seq))
    { "seq" => seq, "nonce" => E.b64encode(nonce), "ciphertext" => E.b64encode(ct) }
  end

  # The next input frame opened: [last?, bytes].
  def open_input(frame)
    raise E::OpenError.new("e2e_decrypt_failed", "input out of order") unless frame["seq"] == @next_input

    plain = E.xchacha_open(@keys["input"], E.b64decode(frame["nonce"]), E.b64decode(frame["ciphertext"]),
                           E.associated_data("input", @desk, @op, frame["seq"]))
    @next_input += 1
    [plain.getbyte(0) == 1, plain.byteslice(1, plain.bytesize - 1)]
  end
end
