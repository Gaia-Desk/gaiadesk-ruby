# frozen_string_literal: true

require "json"
require "openssl"
require "securerandom"

module GaiaDesk
  # End-to-end sealing of desk operations over the hosted API (v1): the
  # caller's side of GaiaDesk's +protocol/src/e2e.rs+, so the server relays
  # only ciphertext.
  #
  # Per operation:
  #
  # 1. an ephemeral X25519 key pair; <tt>shared = X25519(eph, desk e2e_pub)</tt>
  #    (an all-zero result is refused);
  # 2. <tt>prk = HKDF-SHA256-Extract(salt = "gaiadesk desk-op e2e v1", shared)</tt>,
  #    and for each label +request+, +input+, +event+:
  #    <tt>key = HKDF-Expand(prk, label || 0x00 || eph_pub || desk_pub, 32)</tt>;
  # 3. every message XChaCha20-Poly1305 with a random 24-byte nonce and the
  #    associated data <tt>"gaiadesk-e2e/v1 <label>" 0x00 desk 0x00 op</tt>
  #    (plus <tt>0x00 seq</tt>, u64 big-endian, for input and events).
  #
  # Everything comes from Ruby's own OpenSSL binding (no extra gem): X25519
  # (+OpenSSL::PKey+), HKDF (+OpenSSL::KDF.hkdf+) and the IETF
  # ChaCha20-Poly1305 AEAD. OpenSSL has no XChaCha20-Poly1305, so it is built
  # the standard way (draft-irtf-cfrg-xchacha-03): HChaCha20 over the key and
  # the nonce's first 16 bytes, then ChaCha20-Poly1305 with that subkey and the
  # nonce <tt>0000 || nonce[16, 8]</tt>. HChaCha20 comes from OpenSSL's raw
  # ChaCha20 block (its keystream block 0 is <tt>rounds(state) + state</tt>, so
  # the initial state's words are subtracted back out): no ChaCha rounds are
  # written here. The shared test vectors (+test/fixtures/e2e_vectors.json+)
  # pin every step byte for byte.
  module E2E
    # What a desk that opens sealed operations lists in +features+.
    FEATURE = "desk_op_e2e"
    VERSION = 1
    # The header that carries a sealed request (base64url of its JSON) on GET, DELETE and the upload's PUT.
    HEADER = "GaiaDesk-E2E"
    # The content type of a sealed upload's body and a sealed download's answer.
    FRAMES_CONTENT_TYPE = "application/x-ndjson"
    HKDF_SALT = "gaiadesk desk-op e2e v1".b.freeze
    INPUT_MORE = 0
    INPUT_LAST = 1
    # The most file bytes one sealed input frame carries.
    INPUT_CHUNK = 48 * 1024
    LABELS = %w[request input event].freeze
    # The desk events a sealed answer carries.
    EVENTS = %w[stdout stderr exit error].freeze

    SIGMA = "expand 32-byte k".b.freeze
    X25519_PKCS8_PREFIX = ["302e020100300506032b656e04220420"].pack("H*").freeze
    X25519_SPKI_PREFIX = ["302a300506032b656e032100"].pack("H*").freeze
    ZERO32 = ("\0" * 32).b.freeze
    private_constant :SIGMA, :X25519_PKCS8_PREFIX, :X25519_SPKI_PREFIX, :ZERO32

    # A sealed message did not open: +reason+ is +e2e_decrypt_failed+ or +e2e_malformed+
    # (or +e2e_weak_key+ for a desk key that is not a usable X25519 key).
    class OpenError < StandardError
      # @return [String]
      attr_reader :reason

      def initialize(reason, message)
        super(message)
        @reason = reason
      end
    end

    module_function

    # Whether this Ruby's OpenSSL has everything sealing needs (X25519, HKDF,
    # ChaCha20 and ChaCha20-Poly1305). OpenSSL 1.1.0 and later do.
    # @return [Boolean]
    def available?
      return @available unless @available.nil?

      @available = begin
        OpenSSL::Cipher.new("chacha20-poly1305")
        OpenSSL::Cipher.new("chacha20")
        OpenSSL::KDF.respond_to?(:hkdf) && !public_key(("\x01" * 32).b).nil?
      rescue StandardError
        false
      end
    end

    # ───────────────────────────── pure helpers ─────────────────────────────

    # base64url without padding.
    # @param bytes [String]
    # @return [String]
    def b64encode(bytes)
      [bytes].pack("m0").tr("+/", "-_").delete("=")
    end

    # base64url, padding optional; ArgumentError for anything else.
    # @param str [String]
    # @return [String] binary
    def b64decode(str)
      raise ArgumentError, "not base64url" unless str.is_a?(String) && str.match?(/\A[A-Za-z0-9_-]*={0,2}\z/)

      t = str.delete("=")
      raise ArgumentError, "not base64url" if t.length % 4 == 1

      (t.tr("-_", "+/") + ("=" * ((4 - (t.length % 4)) % 4))).unpack1("m0")
    end

    # A base64url X25519 public key: exactly 32 bytes, else ArgumentError.
    def key32(str)
      k = b64decode(str)
      raise ArgumentError, "a key is 32 bytes" unless k.bytesize == 32

      k
    end

    # The associated data of one sealed message.
    # @param label [String] +request+, +input+ or +event+
    # @param desk [String] the desk id
    # @param op [String] the operation's name (+exec+, +file_put+, ...)
    # @param seq [Integer, nil] the frame's place (input and events)
    def associated_data(label, desk, op, seq = nil)
      a = "gaiadesk-e2e/v1 #{label}".b << "\0" << desk.to_s.b << "\0" << op.to_s.b
      a << "\0" << [seq].pack("Q>") unless seq.nil?
      a
    end

    # A request's plaintext: <tt>{"v":1,"ts":<unix seconds>,"request":{…}}</tt>.
    def inner_request(request, now = nil)
      JSON.generate({ "v" => VERSION, "ts" => now || Time.now.to_i, "request" => request }).b
    end

    # The +GaiaDesk-E2E+ header for a sealed request envelope.
    def header_value(envelope)
      b64encode(JSON.generate(envelope))
    end

    # The length of +n+ bytes as unpadded base64.
    def b64_len(num)
      ((4 * num) + 2) / 3
    end

    # Bytes of the NDJSON body that uploads a +size+-byte file as sealed input frames.
    def input_frames_length(size)
      total = 0
      seq = 0
      left = size
      loop do
        n = [INPUT_CHUNK, left].min
        total += %({"seq":#{seq},"nonce":"","ciphertext":""}\n).bytesize + b64_len(24) + b64_len(1 + n + 16)
        left -= n
        seq += 1
        return total if left <= 0
      end
    end

    # ───────────────────────────── the primitives ─────────────────────────────

    # HChaCha20 (draft-irtf-cfrg-xchacha-03 §2.2) from OpenSSL's ChaCha20 block function.
    # @param key [String] 32 bytes
    # @param nonce16 [String] 16 bytes
    # @return [String] the 32-byte subkey
    def hchacha20(key, nonce16)
      raise ArgumentError, "HChaCha20 takes a 32-byte key and a 16-byte nonce" unless key.bytesize == 32 && nonce16.bytesize == 16

      c = OpenSSL::Cipher.new("chacha20")
      c.encrypt
      c.key = key
      c.iv = nonce16 # OpenSSL's 16-byte IV is the state's words 12-15: counter || nonce
      out = (c.update(("\0" * 64).b) + c.final).unpack("V16")
      sigma = SIGMA.unpack("V4")
      n = nonce16.unpack("V4")
      words = (0..3).map { |i| (out[i] - sigma[i]) & 0xFFFFFFFF } + (0..3).map { |i| (out[12 + i] - n[i]) & 0xFFFFFFFF }
      words.pack("V8")
    end

    # XChaCha20-Poly1305: the ciphertext followed by its 16-byte tag.
    def xchacha_seal(key, nonce, plaintext, aad)
      sub, iv = xchacha_ietf(key, nonce)
      c = OpenSSL::Cipher.new("chacha20-poly1305")
      c.encrypt
      c.key = sub
      c.iv = iv
      c.auth_data = aad
      body = plaintext.empty? ? "".b : c.update(plaintext)
      body << c.final
      body.b << c.auth_tag(16)
    end

    # XChaCha20-Poly1305; {OpenError} when it does not authenticate.
    def xchacha_open(key, nonce, ciphertext, aad)
      raise OpenError.new("e2e_malformed", "a sealed message is shorter than its tag") if ciphertext.bytesize < 16

      sub, iv = xchacha_ietf(key, nonce)
      c = OpenSSL::Cipher.new("chacha20-poly1305")
      c.decrypt
      c.key = sub
      c.iv = iv
      c.auth_tag = ciphertext.byteslice(-16, 16)
      c.auth_data = aad
      body = ciphertext.byteslice(0, ciphertext.bytesize - 16)
      out = body.empty? ? "".b : c.update(body)
      out << c.final
      out.b
    rescue OpenSSL::Cipher::CipherError
      raise OpenError.new("e2e_decrypt_failed", "a sealed message did not open: it was altered, or is not this operation's")
    end

    def xchacha_ietf(key, nonce)
      raise ArgumentError, "an XChaCha20 nonce is 24 bytes" unless nonce.bytesize == 24

      [hchacha20(key, nonce.byteslice(0, 16)), ("\0" * 4).b + nonce.byteslice(16, 8)]
    end

    # The X25519 public key of a 32-byte secret.
    def public_key(secret)
      der = private_pkey(secret).public_to_der
      der.byteslice(der.bytesize - 32, 32).b
    end

    # X25519, refusing an all-zero (non-contributory) result.
    def exchange(secret, public)
      shared = begin
        private_pkey(secret).derive(OpenSSL::PKey.read(X25519_SPKI_PREFIX + public))
      rescue OpenSSL::PKey::PKeyError
        ZERO32 # OpenSSL refuses a low-order point itself
      end
      raise OpenError.new("e2e_weak_key", "the desk's end-to-end key is not a usable X25519 key") if shared.b == ZERO32

      shared.b
    end

    def private_pkey(secret)
      raise ArgumentError, "an X25519 secret is 32 bytes" unless secret.bytesize == 32

      OpenSSL::PKey.read(X25519_PKCS8_PREFIX + secret.b)
    end

    # The operation's three keys: HKDF-SHA256(salt, shared) expanded per label.
    # @return [Hash{String => String}]
    def derive(shared, eph_pub, desk_pub)
      LABELS.to_h do |label|
        info = label.b + "\0".b + eph_pub.b + desk_pub.b
        [label, OpenSSL::KDF.hkdf(shared, salt: HKDF_SALT, info: info, length: 32, hash: "SHA256").b]
      end
    end

    # Seal +plaintext+ with a given ephemeral secret and nonce (the test vectors'
    # entry point; never reuse either).
    # @return [Seal]
    def seal_request_with(eph, nonce, desk_pub, desk, op, plaintext)
      eph_pub = public_key(eph)
      keys = derive(exchange(eph, desk_pub), eph_pub, desk_pub)
      ct = xchacha_seal(keys["request"], nonce, plaintext, associated_data("request", desk, op))
      envelope = { "v" => VERSION, "pub" => b64encode(eph_pub), "nonce" => b64encode(nonce), "ciphertext" => b64encode(ct) }
      Seal.new(keys, desk, op, envelope)
    end

    # Seal desk operation +request+ (<tt>{"op" => op, …}</tt>) to desk +desk+'s key, now.
    # @return [Seal]
    def seal_request(desk_pub, desk, op, request)
      seal_request_with(SecureRandom.random_bytes(32), SecureRandom.random_bytes(24), desk_pub, desk, op, inner_request(request))
    end

    # Every event of a JSON answer, opened in order.
    def open_frames(seal, frames)
      frames.map { |f| seal.open_event_json(f) }
    end

    # One operation's seal (the caller's side): its sealed request (+envelope+),
    # its input frames going up and the desk's events coming back, each in order.
    class Seal
      # @return [String] the desk id
      attr_reader :desk
      # @return [String] the operation's name
      attr_reader :op
      # @return [Hash] <tt>{"v", "pub", "nonce", "ciphertext"}</tt>: the body's +e2e+ member or the header's JSON
      attr_reader :envelope

      def initialize(keys, desk, op, envelope)
        @keys = keys
        @desk = desk
        @op = op
        @envelope = envelope
        @next_input = 0
        @next_event = 0
      end

      # The +GaiaDesk-E2E+ header value.
      def header
        E2E.header_value(@envelope)
      end

      # The next input frame with a given nonce (the vectors' entry point).
      def seal_input_with(nonce, last, data)
        seq = @next_input
        @next_input += 1
        plain = [last ? INPUT_LAST : INPUT_MORE].pack("C") + data.b
        ct = E2E.xchacha_seal(@keys["input"], nonce, plain, E2E.associated_data("input", @desk, @op, seq))
        { "seq" => seq, "nonce" => E2E.b64encode(nonce), "ciphertext" => E2E.b64encode(ct) }
      end

      # The next input frame, <tt>{"seq", "nonce", "ciphertext"}</tt>.
      def seal_input(last, data)
        seal_input_with(SecureRandom.random_bytes(24), last, data)
      end

      # The next event's plaintext: it must be the next in order (a gap, repeat or change fails).
      def open_event(frame)
        seq = frame.is_a?(Hash) ? frame["seq"] : nil
        raise OpenError.new("e2e_malformed", "a sealed event is malformed") unless seq.is_a?(Integer)
        unless seq == @next_event
          raise OpenError.new("e2e_decrypt_failed", "a sealed event arrived out of order (expected #{@next_event}, got #{seq})")
        end

        begin
          nonce = E2E.b64decode(frame["nonce"])
          ct = E2E.b64decode(frame["ciphertext"])
        rescue ArgumentError
          raise OpenError.new("e2e_malformed", "a sealed event is malformed")
        end
        raise OpenError.new("e2e_malformed", "a sealed event is malformed") if nonce.bytesize != 24 || ct.bytesize < 16

        plain = E2E.xchacha_open(@keys["event"], nonce, ct, E2E.associated_data("event", @desk, @op, seq))
        @next_event += 1
        plain
      end

      # The next event as the desk event it carries (+stdout+/+stderr+/+exit+/+error+).
      def open_event_json(frame)
        e = begin
          JSON.parse(open_event(frame).force_encoding(Encoding::UTF_8))
        rescue JSON::ParserError
          nil
        end
        unless e.is_a?(Hash) && EVENTS.include?(e["event"])
          raise OpenError.new("e2e_malformed", "a sealed event opened to something that is not an event")
        end

        e
      end
    end
  end
end
