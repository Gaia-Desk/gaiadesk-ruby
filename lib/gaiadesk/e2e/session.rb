# frozen_string_literal: true

require "json"

module GaiaDesk
  # The caller's side of end-to-end encrypted desk operations: the policy, the
  # sealed requests, and reading sealed answers back (see crypto.rb for the primitives).
  module E2E
    # The modes of the +e2e:+ option.
    MODES = %w[auto require off].freeze
    # How long a desk's key (<tt>GET /desks/{id}</tt>) is used before it is read again, in seconds.
    CACHE_SECS = 300.0
    # How long a desk that must be sealed to but lists no key is woken for, by default.
    WAKE_SECS = 30
    # The reason a desk (or the server for it) refuses a plaintext operation (409 +refused+).
    E2E_REQUIRED = "e2e_required"

    module_function

    def e2e_error(message, reason, **kw)
      EndToEndError.new(message, kind: "e2e", reason: reason, exit_code: 255, **kw)
    end

    # +e2e:+ and +e2e_keys:+ checked: the mode, and each pinned key decoded.
    # @return [Array(String, Hash{String => String})]
    def check_options(mode, keys)
      m = mode.to_s
      raise UsageError.new("e2e is :auto, :require or :off (not #{mode.inspect})", kind: "usage") unless MODES.include?(m)

      pinned = {}
      unless keys.nil?
        raise UsageError.new("e2e_keys maps desk ids to their e2e_pub (base64url)", kind: "usage") unless keys.is_a?(Hash)

        keys.each do |desk, pub|
          pinned[desk.to_s] = key32(pub)
        rescue ArgumentError
          raise UsageError.new("e2e_keys[#{desk.inspect}] is not a 32-byte base64url X25519 key", kind: "usage")
        end
      end
      [m, pinned]
    end

    # One transport's end-to-end policy and its cache of desks' keys.
    class Policy
      # @return [String] +auto+, +require+ or +off+
      attr_reader :mode

      def initialize(transport, mode, pinned, warn: nil)
        @t = transport
        @mode = mode
        @pinned = pinned
        @cache = {}
        @lock = Mutex.new
        @warned = {}
        @warn = warn || ->(message) { Kernel.warn(message) }
      end

      # <tt>GET /desks/{id}</tt> (cached): its +e2e_pub+, +e2e_required+ and +features+.
      def desk_info(desk, refresh: false, call: {})
        hit = @lock.synchronize { @cache[desk] }
        return hit[1] if hit && !refresh && E2E.now < hit[0]

        r = @t.json_call("GET", @t.desk_path(desk), wake: false, call: call)
        info = r.is_a?(Hash) ? r : {}
        @lock.synchronize { @cache[desk] = [E2E.now + CACHE_SECS, info] }
        info
      end

      # The key to seal desk +desk+'s operation to, or +nil+ to send it in the clear
      # (with a warning where the policy says so). Raises where it must be sealed and
      # cannot be. +must+: the desk refused plaintext (+e2e_required+).
      def key_for(desk, refresh: false, must: false, call: {})
        lookup_error = nil
        begin
          info = desk_info(desk, refresh: refresh, call: call)
        rescue Error => e
          info = {}
          lookup_error = e
        end
        required = must || @mode == "require" || info["e2e_required"] == true
        key = server_key(desk, info) || @pinned[desk]
        unless E2E.available?
          if required
            raise E2E.e2e_error("desk #{desk} requires end-to-end encryption, which this Ruby's OpenSSL cannot do " \
                                "(it needs OpenSSL 1.1.0 or later)", "e2e_unavailable", desk: desk)
          end
          if key
            warn_once("crypto", "gaiadesk: this Ruby's OpenSSL has no X25519/ChaCha20-Poly1305, so desk operations " \
                                "through the API are sent without end-to-end encryption")
            return nil
          end
        end
        return key if key

        unless required
          why = lookup_error ? "could not be read (#{lookup_error.message})" : "publishes no end-to-end key"
          warn_once("nokey:#{desk}", "gaiadesk: desk #{desk} #{why}, so its operations through the API are sent " \
                                     "without end-to-end encryption")
          return nil
        end
        wake(desk, call)
        begin
          key = server_key(desk, desk_info(desk, refresh: true, call: call))
        rescue EndToEndError
          raise
        rescue Error => e
          raise E2E.e2e_error("the end-to-end key of desk #{desk} could not be read: #{e.message}", "e2e_unavailable", desk: desk)
        end
        return key if key

        raise E2E.e2e_error("desk #{desk} publishes no end-to-end key (it is offline, or its GaiaDesk is too old), and " \
                            "end-to-end encryption is required; nothing was sent", "e2e_unavailable", desk: desk)
      end

      private

      def wake(desk, call)
        wait = call[:wake] || @t.wake_secs || WAKE_SECS
        @t.json_call("POST", "#{@t.desk_path(desk)}/wake", json: { "wait_s" => [wait, 90].min }, wake: false, call: call)
      rescue Error
        nil # already online, nothing to ring, no desks:write: the key is read again either way
      end

      def server_key(desk, info)
        pub = info["e2e_pub"]
        return nil unless pub.is_a?(String) && !pub.empty?

        key = begin
          E2E.key32(pub)
        rescue ArgumentError
          raise E2E.e2e_error("desk #{desk} published an end-to-end key that is not a 32-byte X25519 key", "e2e_malformed", desk: desk)
        end
        pinned = @pinned[desk]
        if pinned && key != pinned
          raise E2E.e2e_error("the GaiaDesk API handed out an end-to-end key for desk #{desk} that is not the one pinned " \
                              "in e2e_keys; nothing was sent", "e2e_key_mismatch", desk: desk)
        end
        key
      end

      def warn_once(key, message)
        first = @lock.synchronize { @warned[key] ? false : (@warned[key] = true) }
        @warn.call(message) if first
      end
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # A file's bytes going up: a String, or an IO of +size+ bytes (sent again only
    # when it can be rewound).
    class Upload
      # @return [String, IO]
      attr_reader :source
      # @return [Integer]
      attr_reader :size

      def initialize(source, size)
        @source = source
        @size = size
        @start = !source.is_a?(String) && source.respond_to?(:pos) ? source.pos : nil
      rescue StandardError
        @start = nil
      end

      # Whether it is a String in memory.
      def bytes?
        @source.is_a?(String)
      end

      # Ready to be read again from the start: false when it cannot be (a pipe).
      def rewind
        return true if bytes?
        return false if @start.nil?

        @source.seek(@start)
        true
      rescue StandardError
        false
      end
    end

    # One desk operation, both ways: in the clear (+query+, +json+, +upload+ as the
    # body) and sealed (+request+, the sealed request's operation; +sealed_query+,
    # what stays in the URL).
    class DeskOp
      attr_reader :desk, :name, :request, :method, :path, :query, :sealed_query, :json, :upload, :accept
      # @return [Hash] per-call options (+desk_token+, +wake+, +idempotency_key+)
      attr_reader :call

      def initialize(desk, name, request, method, path, query: nil, sealed_query: nil, json: nil, upload: nil,
                     accept: "application/json", call: {})
        @desk = desk
        @name = name
        @request = { "op" => name }.merge(request)
        @method = method
        @path = path
        @query = query
        @sealed_query = sealed_query
        @json = json
        @upload = upload
        @accept = accept
        @call = call
      end

      # <tt>"POST /desks/123456789/exec"</tt>
      def label
        "#{@method} #{@path}"
      end
    end

    # An upload's NDJSON body, read by Net::HTTP: one sealed input frame per line, each at
    # most 48 KiB of the file (flag 1 on the last, which is empty for an empty file).
    class InputFrames
      def initialize(seal, upload)
        @seal = seal
        @upload = upload
        @left = upload.size
        @at = 0
        @buf = "".b
        @done = false
      end

      # IO-like +read+ for IO.copy_stream.
      def read(len = nil, out = nil)
        fill while !@done && (len.nil? || @buf.bytesize < len)
        if @buf.empty? && @done
          return len.nil? ? "".b : nil
        end

        chunk = len.nil? ? @buf : @buf.byteslice(0, len)
        @buf = len.nil? ? "".b : (@buf.byteslice(len, @buf.bytesize) || "".b)
        out ? out.replace(chunk) : chunk
      end

      private

      def fill
        n = [INPUT_CHUNK, @left].min
        data = if @upload.bytes?
                 @upload.source.byteslice(@at, n) || "".b
               else
                 n.zero? ? "".b : (@upload.source.read(n) || "".b)
               end
        raise IOError, "the file changed size while it was being sent" unless data.bytesize == n

        @at += n
        @left -= n
        @buf << JSON.generate(@seal.seal_input(@left.zero?, data)) << "\n"
        @done = true if @left.zero?
      end
    end

    # ───────────────────────────── answers ─────────────────────────────

    def open_all(seal, frames, op, status)
      unless frames.is_a?(Array) && !frames.empty?
        raise e2e_error("the GaiaDesk API answered #{op} with no sealed events", "e2e_malformed", argv: [op], status: status)
      end

      open_frames(seal, frames)
    rescue OpenError => e
      raise e2e_error("the end-to-end encrypted answer to #{op} did not open: #{e.message}", e.reason, argv: [op], status: status)
    end

    # The error envelope with the opened error's kind, message and reason in place of the placeholder.
    def envelope_with(parsed, event)
      e = parsed["error"].dup
      e["kind"] = event["kind"] if event["kind"].is_a?(String)
      e["message"] = event["message"] if event["message"].is_a?(String)
      if event["reason"].is_a?(String)
        e["reason"] = event["reason"]
      else
        e.delete("reason")
      end
      { "error" => e }
    end

    def event_error(event, desk, op, status)
      kind = event["kind"].is_a?(String) ? event["kind"] : "failed"
      message = event["message"].is_a?(String) ? event["message"] : "the desk reported an error"
      reason = event["reason"].is_a?(String) ? event["reason"] : nil
      err = { "kind" => kind, "message" => message, "desk" => desk }
      err["reason"] = reason if reason
      Errors.for_kind(kind, message, reason, exit_code: Errors.exit_for(kind), argv: [op], json: { "error" => err },
                                             desk: desk, status: status)
    end

    # A sealed JSON answer as the plaintext call's: the last event's +result+; an error
    # envelope (a held wait's failure) with its real message; a desk error in a 200 raised.
    def unseal_json(parsed, seal, op, status)
      if parsed.is_a?(Hash) && parsed["e2e"].is_a?(Hash)
        events = open_all(seal, parsed["e2e"]["events"], op, status)
        last = events.last
        if Errors.envelope(parsed)
          unless last["event"] == "error"
            raise e2e_error("the GaiaDesk API answered #{op} with an error whose sealed events end otherwise", "e2e_malformed",
                            argv: [op], status: status)
          end
          return envelope_with(parsed, last)
        end
        return last["result"] if last["event"] == "exit" && last.key?("result")
        raise event_error(last, seal.desk, op, status) if last["event"] == "error"

        raise e2e_error("the sealed answer to #{op} ended without its result", "e2e_malformed", argv: [op], status: status)
      end
      return parsed if Errors.envelope(parsed) # the server's own failure (a held wait whose desk went away): never sealed

      raise e2e_error("the GaiaDesk API answered the end-to-end encrypted #{op} in the clear", "e2e_malformed",
                      argv: [op], status: status)
    end

    # An HTTP error's body with the desk's real error opened into its envelope (the server's own errors are as they are).
    def unseal_error_body(data, seal, op, status)
      parsed = parse_or_nil(data)
      return data unless parsed.is_a?(Hash) && parsed["e2e"].is_a?(Hash) && Errors.envelope(parsed)

      events = open_all(seal, parsed["e2e"]["events"], op, status)
      unless events.last["event"] == "error"
        raise e2e_error("the GaiaDesk API answered #{op} with an error whose sealed events end otherwise", "e2e_malformed",
                        argv: [op], status: status)
      end
      JSON.generate(envelope_with(parsed, events.last))
    end

    def parse_or_nil(data)
      JSON.parse(data)
    rescue JSON::ParserError
      nil
    end

    def bytes_of(data)
      return nil unless data.is_a?(String) && data.match?(%r{\A[A-Za-z0-9+/]*={0,2}\z}) && (data.length % 4).zero?

      data.unpack1("m0")
    rescue ArgumentError
      nil
    end

    # Text decoded incrementally: a UTF-8 character split across chunks waits for its end.
    class Utf8Carry
      def initialize
        @pending = "".b
      end

      # The text +bytes+ completes (+final+: flush what is left).
      def decode(bytes, final: false)
        buf = @pending + bytes.b
        keep = final ? 0 : incomplete_tail(buf)
        @pending = buf.byteslice(buf.bytesize - keep, keep)
        buf.byteslice(0, buf.bytesize - keep).force_encoding(Encoding::UTF_8).scrub("\uFFFD")
      end

      private

      # How many bytes at the end begin a character that is not complete yet.
      def incomplete_tail(buf)
        n = buf.bytesize
        (1..[3, n].min).each do |back|
          b = buf.getbyte(n - back)
          next if b & 0xC0 == 0x80 # a continuation byte: look further back

          need = if b >= 0xF0 then 4
                 elsif b >= 0xE0 then 3
                 elsif b >= 0xC0 then 2
                 else 1
                 end
          return need > back ? back : 0
        end
        0
      end
    end

    # A sealed stream's events as the plaintext stream's (the server's ExecEvents for
    # +exec+, LogEvents for +logs+): text with a UTF-8 carry per stream, +exit+ as
    # ExecExit, the log's +end+ / +interrupted+, +error+ with the CLI's exit code.
    class EventMapper
      def initialize(seal, kind, desk)
        @seal = seal
        @kind = kind
        @desk = desk
        @carry = { "stdout" => Utf8Carry.new, "stderr" => Utf8Carry.new }
      end

      # The plaintext events one +sealed+ SSE event's data opens to.
      def map(data)
        frame = begin
          JSON.parse(data)
        rescue JSON::ParserError
          raise OpenError.new("e2e_malformed", "a sealed event is not JSON")
        end
        # Its data names the event, as every /v1 SSE event's does: {"event": "sealed", "seq", "nonce", "ciphertext"}.
        if frame.is_a?(Hash) && frame.fetch("event", "sealed") != "sealed"
          raise OpenError.new("e2e_malformed", "a sealed event's data names another event")
        end

        map_event(@seal.open_event_json(frame))
      end

      def map_event(event)
        name = event["event"]
        return output(name, event) if %w[stdout stderr].include?(name)
        return exited(event["result"]) if name == "exit"

        error = { "kind" => event["kind"], "message" => event["message"], "desk" => @desk }
        error["reason"] = event["reason"] if event["reason"].is_a?(String)
        return [{ "event" => "error", "exit" => error["kind"] == "refused" ? 254 : 255, "error" => error }] if @kind == "exec"

        [{ "event" => "error", "error" => error }]
      end

      private

      def output(name, event)
        b = E2E.bytes_of(event["data"])
        return [] if b.nil?

        stream = @kind == "exec" ? name : "stdout"
        text = @carry[stream].decode(b)
        return [] if text.empty?

        [{ "event" => @kind == "exec" ? name : "output", "data" => text }]
      end

      def exited(result)
        out = []
        (@kind == "exec" ? %w[stdout stderr] : %w[stdout]).each do |stream|
          rest = @carry[stream].decode("".b, final: true)
          out << { "event" => @kind == "exec" ? stream : "output", "data" => rest } unless rest.empty?
        end
        if @kind == "exec"
          o = (result.is_a?(Hash) ? result : {}).except("stdout", "stderr", "truncated")
          out << o.merge("event" => "exit")
        elsif result.is_a?(Hash) && result["interrupted"] == true
          out << { "event" => "interrupted" }
        else
          out << { "event" => "end", "job" => result.is_a?(Hash) ? result["job"] : nil }
        end
        out
      end
    end

    # A sealed download (NDJSON of sealed events): each +stdout+ event's bytes to the
    # block, until +exit+ (its CopyResult, returned) or +error+ (raised). Missing its last
    # event, it is incomplete (a ConnectionLostError).
    def read_sealed_file(response, seal, op, &block)
      check_frames_type(response, op)
      buf = "".b
      done = nil
      response.read_body do |bytes|
        next if done

        buf << bytes
        while !done && (i = buf.index("\n"))
          line = buf.byteslice(0, i)
          buf = buf.byteslice(i + 1, buf.bytesize - i - 1)
          done = file_event(seal, line, op, &block)
        end
      end
      done ||= file_event(seal, buf, op, &block)
      return done[0] if done

      raise ConnectionLostError.new("the download of #{op} ended before the file did",
                                    kind: "connection_lost", exit_code: 255, argv: [op])
    end

    def check_frames_type(response, op)
      ctype = response["Content-Type"].to_s.split(";").first.to_s.strip
      return if ctype == FRAMES_CONTENT_TYPE

      raise e2e_error("the GaiaDesk API answered the end-to-end encrypted #{op} with #{ctype.empty? ? 'no type' : ctype}, " \
                      "not sealed events", "e2e_malformed", argv: [op], status: response.code.to_i)
    end

    # One line of a sealed download: its bytes to the block; <tt>[result]</tt> once it ended.
    def file_event(seal, line, op)
      return nil if line.strip.empty?

      ev = open_line(seal, line, op)
      case ev["event"]
      when "stdout"
        b = bytes_of(ev["data"]) or raise e2e_error("a sealed chunk of #{op} is not base64", "e2e_malformed", argv: [op])
        yield b
        nil
      when "exit" then [ev["result"]]
      when "error" then raise event_error(ev, seal.desk, op, nil)
      end
    end

    def open_line(seal, line, op)
      seal.open_event_json(JSON.parse(line.force_encoding(Encoding::UTF_8)))
    rescue JSON::ParserError
      raise e2e_error("a sealed event of #{op} is not JSON", "e2e_malformed", argv: [op])
    rescue OpenError => e
      raise e2e_error("the end-to-end encrypted download did not open: #{e.message}", e.reason, argv: [op])
    end
  end
end
