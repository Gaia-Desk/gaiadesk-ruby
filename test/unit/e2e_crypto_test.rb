# frozen_string_literal: true

require "test_helper"

# The shared vectors (protocol/src/e2e/vectors.json, byte for byte the same file as
# the TypeScript and Python SDKs'), and the primitives' refusals.
class E2eCryptoTest < Minitest::Test
  E = GaiaDesk::E2E
  V = TestHelpers::VECTORS

  def seal
    E.seal_request_with(hex(V["eph_secret_hex"]), E.b64decode(V["request"]["nonce"]), E.key32(V["desk_pub"]), V["desk_id"],
                        V["op"], V["request_plaintext"].b)
  end

  def test_available
    assert_predicate E, :available?
  end

  def test_desk_public_key
    assert_equal V["desk_pub"], E.b64encode(E.public_key(hex(V["desk_secret_hex"])))
  end

  def test_ephemeral_public_key
    assert_equal V["request"]["pub"], E.b64encode(E.public_key(hex(V["eph_secret_hex"])))
  end

  def test_sealed_request_matches_byte_for_byte
    assert_equal V["request"], seal.envelope
  end

  def test_request_header_matches
    assert_equal V["request_header"], seal.header
  end

  def test_associated_data
    assert_equal V["aad_request_hex"], E.associated_data("request", V["desk_id"], V["op"]).unpack1("H*")
    assert_equal V["aad_event_1_hex"], E.associated_data("event", V["desk_id"], V["op"], 1).unpack1("H*")
  end

  def test_hkdf_salt
    assert_equal V["hkdf_salt"], E::HKDF_SALT
  end

  def test_input_frames_match
    s = seal
    V["inputs"].each do |i|
      f = s.seal_input_with(E.b64decode(i["nonce"]), i["last"], i["data"])

      assert_equal({ "seq" => i["seq"], "nonce" => i["nonce"], "ciphertext" => i["ciphertext"] }, f)
    end
  end

  def test_events_open_in_order
    s = seal

    V["events"].each { |e| assert_equal e["plaintext"].b, s.open_event(e) }
  end

  def test_events_open_as_json
    s = seal
    first = s.open_event_json(V["events"][0])

    assert_equal({ "event" => "stdout", "data" => "dmVjdG9yCg==" }, first)
    assert_equal({ "event" => "exit", "result" => { "exit" => 0 } }, s.open_event_json(V["events"][1]))
  end

  def test_the_desk_opens_the_request_with_its_secret
    ds = DeskSeal.open(hex(V["desk_secret_hex"]), V["desk_id"], V["op"], V["request"])

    assert_equal JSON.parse(V["request_plaintext"])["request"], ds.request
    assert_equal 1_791_000_000, ds.ts
  end

  def test_a_gap_fails
    err = assert_raises(E::OpenError) { seal.open_event(V["events"][1]) }
    assert_equal "e2e_decrypt_failed", err.reason
  end

  def test_a_repeat_fails
    s = seal
    s.open_event(V["events"][0])
    assert_raises(E::OpenError) { s.open_event(V["events"][0]) }
  end

  def test_a_changed_byte_fails
    ct = E.b64decode(V["events"][0]["ciphertext"])
    ct.setbyte(3, ct.getbyte(3) ^ 1)
    err = assert_raises(E::OpenError) { seal.open_event(V["events"][0].merge("ciphertext" => E.b64encode(ct))) }
    assert_equal "e2e_decrypt_failed", err.reason
  end

  def test_another_ops_event_fails
    other = E.seal_request_with(hex(V["eph_secret_hex"]), E.b64decode(V["request"]["nonce"]), E.key32(V["desk_pub"]), V["desk_id"],
                                "stats", V["request_plaintext"].b)
    assert_raises(E::OpenError) { other.open_event(V["events"][0]) }
  end

  def test_malformed_frames
    s = seal
    [nil, {}, { "seq" => "0" }, { "seq" => 0, "nonce" => "!!", "ciphertext" => "AA" },
     { "seq" => 0, "nonce" => E.b64encode("x" * 23), "ciphertext" => E.b64encode("y" * 20) },
     { "seq" => 0, "nonce" => E.b64encode("x" * 24), "ciphertext" => E.b64encode("y" * 15) }].each do |f|
      err = assert_raises(E::OpenError) { s.open_event(f) }
      assert_equal "e2e_malformed", err.reason
    end
  end

  def test_an_event_that_is_not_one
    k = E.derive(E.exchange(hex(V["eph_secret_hex"]), E.key32(V["desk_pub"])), E.public_key(hex(V["eph_secret_hex"])), E.key32(V["desk_pub"]))
    nonce = "n" * 24
    ct = E.xchacha_seal(k["event"], nonce, '{"event":"other"}', E.associated_data("event", V["desk_id"], V["op"], 0))
    err = assert_raises(E::OpenError) { seal.open_event_json({ "seq" => 0, "nonce" => E.b64encode(nonce), "ciphertext" => E.b64encode(ct) }) }
    assert_equal "e2e_malformed", err.reason
  end

  def test_a_low_order_key_is_refused
    zero = ("\0" * 32).b
    err = assert_raises(E::OpenError) { E.exchange(hex(V["eph_secret_hex"]), zero) }
    assert_equal "e2e_weak_key", err.reason
  end

  def test_xchacha_round_trip_with_empty_plaintext
    key = "k" * 32
    nonce = "n" * 24
    ct = E.xchacha_seal(key, nonce, "".b, "aad")

    assert_equal 16, ct.bytesize
    assert_equal "".b, E.xchacha_open(key, nonce, ct, "aad")
  end

  # draft-irtf-cfrg-xchacha-03 §2.2.1's test vector.
  def test_hchacha20_draft_vector
    key = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    nonce = hex("000000090000004a0000000031415927")

    assert_equal "82413b4227b27bfed30e42508a877d73a0f9e4d58a74a853c12ec41326d3ecdc", E.hchacha20(key, nonce).unpack1("H*")
  end

  # draft-irtf-cfrg-xchacha-03 §A.3.1's AEAD test vector.
  def test_xchacha20_poly1305_draft_vector
    plaintext = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."
    aad = hex("50515253c0c1c2c3c4c5c6c7")
    key = hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
    nonce = hex("404142434445464748494a4b4c4d4e4f5051525354555657")
    out = E.xchacha_seal(key, nonce, plaintext, aad)

    assert_equal "c0875924c1c7987947deafd8780acf49", out.byteslice(-16, 16).unpack1("H*")
    assert_equal "bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb",
                 out.byteslice(0, 32).unpack1("H*")
    assert_equal plaintext.b, E.xchacha_open(key, nonce, out, aad)
  end

  def test_base64url
    assert_equal "AQID", E.b64encode("\x01\x02\x03".b)
    assert_equal "_-8", E.b64encode("\xff\xef".b)
    assert_equal "\xff\xef".b, E.b64decode("_-8")
    assert_equal "\xff\xef".b, E.b64decode("_-8=")
    assert_raises(ArgumentError) { E.b64decode("a+b/") }
    assert_raises(ArgumentError) { E.b64decode("abcde") }
    assert_raises(ArgumentError) { E.key32("AQID") }
  end

  def test_input_frames_length_is_the_body_length
    [0, 1, 100, E::INPUT_CHUNK - 1, E::INPUT_CHUNK, E::INPUT_CHUNK + 1, (3 * E::INPUT_CHUNK) + 17].each do |size|
      s = E.seal_request(E.key32(V["desk_pub"]), V["desk_id"], "file_put", { "op" => "file_put" })
      body = E::InputFrames.new(s, E::Upload.new(("z" * size).b, size)).read

      assert_equal E.input_frames_length(size), body.bytesize, "size #{size}"
      assert_equal [size.zero? ? 1 : (size + E::INPUT_CHUNK - 1) / E::INPUT_CHUNK, 1].max, body.count("\n")
    end
  end

  def test_input_frames_read_in_pieces
    s = E.seal_request(E.key32(V["desk_pub"]), V["desk_id"], "file_put", { "op" => "file_put" })
    io = StringIO.new(("q" * 100_000).b)
    frames = E::InputFrames.new(s, E::Upload.new(io, 100_000))
    out = +"".b
    while (piece = frames.read(4096))
      out << piece
    end

    assert_equal E.input_frames_length(100_000), out.bytesize
  end

  def test_a_file_that_shrinks_while_sent
    s = E.seal_request(E.key32(V["desk_pub"]), V["desk_id"], "file_put", { "op" => "file_put" })
    frames = E::InputFrames.new(s, E::Upload.new(StringIO.new("short".b), 10))
    assert_raises(IOError) { frames.read }
  end

  def test_utf8_carry
    c = E::Utf8Carry.new
    b = "h\u00e9\u2713!".b
    out = b.bytes.map { |x| c.decode([x].pack("C")) }.join

    assert_equal "h\u00e9\u2713!", out
    assert_equal "\uFFFD", E::Utf8Carry.new.decode("\xe2\x9c".b, final: true)
  end

  def test_inner_request
    assert_equal '{"v":1,"ts":5,"request":{"op":"stats"}}', E.inner_request({ "op" => "stats" }, 5)
  end
end
