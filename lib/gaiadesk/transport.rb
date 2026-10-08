# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module GaiaDesk
  # The +api+ transport: GaiaDesk's hosted HTTPS API (<tt>https://api.gaiadesk.net/v1</tt>)
  # over Net::HTTP. The answers are the CLI's own JSON shapes (the API's contract
  # references the same schema) and failures the same error envelope. Desk
  # operations are end-to-end encrypted when the desk publishes a key ({E2E}).
  #
  # The HTTP layer is three methods the +local+ and +lan+ transports override,
  # the operations being the same: {#credentials}, {#connection} and
  # {#network_error}. Thread-safe: one connection per request.
  #
  # Use it through {Client}; its methods are documented there.
  class Transport
    include DeskOps
    include Account

    DEFAULT_API_URL = "https://api.gaiadesk.net/v1"
    # The most one file may be through the API, in bytes.
    API_FILE_LIMIT = 256 * 1024 * 1024
    # The longest one <tt>GET …/jobs/{name}/wait</tt> holds, in seconds (the API's +timeout+ maximum).
    API_WAIT_MAX = 870
    JSON_TYPE = "application/json"
    OCTET_TYPE = "application/octet-stream"
    # Reasons of a 4xx answer that asks to try again shortly.
    TRY_AGAIN = %w[rate_limited desk_busy idempotency_key_in_flight].freeze

    # @return [String] +api+, +local+ or +lan+
    attr_reader :name
    # @return [String] the API's base URL (+…/v1+), or +unix:+ / +pipe:+ and the address for +local+
    attr_reader :base_url
    # @return [Integer, nil] the client's +wake+ (seconds to wait for a sleeping desk)
    attr_reader :wake_secs
    # @return [E2E::Policy, nil] the end-to-end policy (+api+ only)
    attr_reader :e2e

    def initialize(api_key:, desk_token: nil, base_url: nil, wake: nil, timeout: nil, open_timeout: 30, e2e: :auto,
                   e2e_keys: nil, retries: 2, retry_base: 0.5, max_retry_wait: 60, on_warning: nil)
      raise UsageError.new("api_key must be a non-empty String", kind: "usage") unless api_key.is_a?(String) && !api_key.strip.empty?

      @name = "api"
      @key = api_key.strip
      @desk_token = Transport.check_desk_token(desk_token)
      @wake_secs = Transport.check_wake(wake)
      set_base(base_url || DEFAULT_API_URL, %w[http https], "base_url must be an http(s) URL: #{base_url.inspect}")
      set_http_options(timeout, open_timeout, retries, retry_base, max_retry_wait)
      mode, pinned = E2E.check_options(e2e, e2e_keys)
      @e2e = E2E::Policy.new(self, mode, pinned, warn: on_warning)
    end

    # +desk_token+ stripped, or the UsageError for one that is not a non-empty String.
    def self.check_desk_token(desk_token)
      return nil if desk_token.nil?
      unless desk_token.is_a?(String) && !desk_token.strip.empty?
        raise UsageError.new("desk_token must be a non-empty String (a scoped agent token, gdagt_…)", kind: "usage")
      end

      desk_token.strip
    end

    # +wake+ checked: whole seconds, 0 to 120.
    def self.check_wake(wake)
      return nil if wake.nil?
      raise UsageError.new("wake is whole seconds, 0 to 120", kind: "usage") unless wake.is_a?(Integer) && wake.between?(0, 120)

      wake
    end

    # ───────────────────────────── HTTP ─────────────────────────────

    # Every request's credential headers: the API key, and the desk token when there is one
    # (the call's own +desk_token:+ first).
    def credentials(call = {})
      h = { "Authorization" => "Bearer #{@key}" }
      token = call[:desk_token] ? Transport.check_desk_token(call[:desk_token]) : @desk_token
      h["X-GaiaDesk-Desk-Token"] = token if token
      h
    end

    # A fresh Net::HTTP (not started) for one request.
    def connection
      http = Net::HTTP.new(@host, @port)
      http.use_ssl = @https
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER if @https
      apply_timeouts(http)
    end

    # The error for a request that got no (complete) answer.
    def network_error(error, op)
      UnreachableError.new("the GaiaDesk API could not be reached (#{@base_url}): #{error.message} (#{error.class})",
                           kind: "network", reason: "network", exit_code: 255, argv: [op])
    end

    # Called once the connection is up, before a request byte is sent (+lan+ pins here).
    def after_connect(_http, _op); end

    # The path of a desk's routes: <tt>/desks/123456789</tt>.
    def desk_path(desk_id)
      "/desks/#{URI.encode_www_form_component(Args.check_desk(desk_id))}"
    end

    # Send one request; yields the open Net::HTTPResponse (status < 400) and returns what
    # the block returns. An HTTP failure is raised as the typed error from its envelope (a
    # sealed operation's, +seal+, with the desk's error opened into it).
    def request(method, path, query: nil, json: nil, body: nil, body_stream: nil, length: nil, accept: JSON_TYPE,
                headers: nil, content_type: OCTET_TYPE, seal: nil, wake: true, call: {}, &block)
      op = "#{method} #{path}"
      req = build_request(method, path, query, wake, call, accept, headers)
      if !json.nil?
        req["Content-Type"] = JSON_TYPE
        req.body = JSON.generate(json)
      elsif body_stream
        req["Content-Type"] = content_type
        req["Content-Length"] = length.to_s
        req.body_stream = body_stream
      elsif body
        req["Content-Type"] = content_type
        req.body = body
      end
      perform(req, op, seal, &block)
    end

    # A request answered with JSON (retried as {Client} documents).
    def json_call(method, path, **kw)
      with_retries(method == "GET") { request(method, path, **kw) { |res| read_json(res, "#{method} #{path}") } }
    end

    # A desk operation answered with JSON, sealed or not: what the plaintext call answers.
    def desk_call(op)
      desk_send(op) do |res, seal|
        r = read_json(res, op.label)
        seal.nil? ? r : E2E.unseal_json(r, seal, op.label, res.code.to_i)
      end
    end

    # Send a desk operation sealed when the policy says so, else in the clear, retried
    # where that is safe; yields <tt>(response, seal or nil)</tt>.
    def desk_send(op, &blk)
      rewind = op.upload ? -> { op.upload.rewind } : nil
      with_retries(op.method == "GET", rewind) { send_op(op, &blk) }
    end

    # The body as JSON (leading whitespace, a held wait's keep-alive, is still JSON).
    def read_json(res, op)
      data = res.read_body.to_s
      JSON.parse(data)
    rescue JSON::ParserError
      raise ProtocolError.new("the GaiaDesk API answered #{op} with something that is not JSON",
                              kind: "protocol", argv: [op], status: res.code.to_i, request_id: res["X-Request-Id"])
    end

    private

    def set_base(url, schemes, bad)
      @base_url = url.to_s.chomp("/")
      u = begin
        URI.parse(@base_url)
      rescue URI::InvalidURIError
        nil
      end
      raise UsageError.new(bad, kind: "usage") unless u && schemes.include?(u.scheme) && u.host && !u.host.empty?

      @https = u.scheme == "https"
      @host = u.hostname
      @port = u.port
      @prefix = u.path.to_s.chomp("/")
    end

    def set_http_options(timeout, open_timeout, retries, retry_base, max_retry_wait)
      @timeout = timeout
      @open_timeout = open_timeout
      raise UsageError.new("retries is an Integer >= 0", kind: "usage") unless retries.is_a?(Integer) && retries >= 0

      @retries = retries
      @retry_base = retry_base.to_f
      @max_retry_wait = max_retry_wait.to_f
    end

    def apply_timeouts(http)
      http.open_timeout = @open_timeout
      http.read_timeout = @timeout
      http.write_timeout = @timeout if http.respond_to?(:write_timeout=)
      # A body shorter than its Content-Length is a broken transfer, never a clean short file.
      http.ignore_eof = false if http.respond_to?(:ignore_eof=)
      http
    end

    def build_request(method, path, query, wake, call, accept, headers)
      q = (query || {}).compact
      w = call.key?(:wake) ? Transport.check_wake(call[:wake]) : @wake_secs
      q["wake_s"] = w if wake && !w.nil?
      uri = @prefix + path + (q.empty? ? "" : "?#{URI.encode_www_form(q)}")
      req = Net::HTTPGenericRequest.new(method, %w[POST PUT PATCH].include?(method), method != "HEAD", uri)
      credentials(call).each { |k, v| req[k] = v }
      req["Accept"] = accept
      req["Accept-Encoding"] = "identity"
      req["User-Agent"] = "gaiadesk-ruby/#{VERSION}"
      req["Idempotency-Key"] = call[:idempotency_key].to_s if call[:idempotency_key] && method == "POST"
      (headers || {}).each { |k, v| req[k] = v }
      req
    end

    def perform(req, op, seal)
      http = connection
      answered = false
      result = nil
      begin
        begin
          http.start
        rescue *HTTP::NETWORK_ERRORS => e
          raise staged(network_error(e, op), :connect)
        end
        after_connect(http, op)
        http.request(req) do |res|
          status = res.code.to_i
          raise staged(failure(res, status, op, seal), :status) if status >= 400

          answered = true
          result = yield res
        end
        result
      rescue Error
        raise
      rescue *HTTP::NETWORK_ERRORS => e
        err = network_error(e, op)
        raise answered ? err : staged(err, :sent)
      ensure
        begin
          http.finish if http.started?
        rescue StandardError
          nil
        end
      end
    end

    def failure(res, status, op, seal)
      data = begin
        res.read_body.to_s
      rescue *HTTP::NETWORK_ERRORS
        ""
      end
      data = E2E.unseal_error_body(data, seal, op, status) if seal
      api_error(status, data, res, op)
    end

    # The typed error for a failed request: its error envelope, else a ProtocolError.
    def api_error(status, body, res, op)
      parsed = begin
        JSON.parse(body.to_s)
      rescue JSON::ParserError
        nil
      end
      header_id = res["X-Request-Id"]
      retry_after = Float(res["Retry-After"], exception: false)
      env = Errors.envelope(parsed)
      if env.nil?
        return ProtocolError.new("the GaiaDesk API answered #{op} with HTTP #{status} and no error envelope",
                                 kind: "protocol", exit_code: 255, argv: [op], json: parsed, status: status,
                                 request_id: header_id, retry_after: retry_after)
      end
      rid = parsed["error"]["request_id"]
      Errors.for_kind(env.kind, env.message.empty? ? "HTTP #{status}" : env.message, env.reason,
                      exit_code: Errors.exit_for(env.kind), argv: [op], json: parsed, desk: env.desk, status: status,
                      request_id: rid.is_a?(String) ? rid : header_id, retry_after: retry_after)
    end

    def staged(error, stage)
      error.instance_variable_set(:@gaiadesk_stage, stage)
      error
    end

    def stage_of(error)
      error.instance_variable_get(:@gaiadesk_stage)
    end

    # ───────────────────────────── retries ─────────────────────────────

    def with_retries(idempotent, rewind = nil)
      attempt = 0
      begin
        yield
      rescue Error => e
        raise unless retry?(e, attempt, idempotent) && (rewind.nil? || rewind.call)

        sleep(retry_delay(e, attempt))
        attempt += 1
        retry
      end
    end

    # Whether a failed request may be sent again: never once its answer was handed on;
    # always when nothing was connected; a "try again" answer (429 +rate_limited+ /
    # +desk_busy+, 409 +idempotency_key_in_flight+) always; a lost connection or a 502 /
    # 504 (and a 503 with +Retry-After+) only for a GET.
    def retry?(err, attempt, idempotent)
      stage = stage_of(err)
      return false if stage.nil? || attempt >= @retries
      return false if err.retry_after && err.retry_after > @max_retry_wait

      case stage
      when :connect then true
      when :sent then idempotent
      else
        return true if TRY_AGAIN.include?(err.reason) || (err.status == 429 && err.retry_after)
        return idempotent if [502, 504].include?(err.status)

        err.status == 503 && !err.retry_after.nil? && idempotent
      end
    end

    def retry_delay(err, attempt)
      return err.retry_after if err.retry_after

      [@retry_base * (2**attempt), 8.0].min * (0.5 + (rand * 0.5))
    end

    # ───────────────────────────── end to end ─────────────────────────────

    # +op+ sealed when the policy says so, else in the clear. A plaintext operation refused
    # +e2e_required+ is sent again sealed, once (an upload only when its source can be read
    # again); a sealed one refused +e2e_decrypt_failed+ (the desk's key changed) again to
    # the key read anew, once.
    def send_op(op, &)
      pol = @e2e
      return open_plain(op, &) if pol.nil? || pol.mode == "off"

      key = pol.key_for(op.desk, call: op.call)
      if key.nil?
        begin
          return open_plain(op, &)
        rescue Error => e
          raise unless stage_of(e) == :status && e.status == 409 && e.reason == E2E::E2E_REQUIRED
          raise if op.upload && !op.upload.rewind

          key = pol.key_for(op.desk, refresh: true, must: true, call: op.call)
        end
      end
      again = true
      begin
        open_sealed(op, key, &)
      rescue Error => e
        raise unless again && stage_of(e) == :status && e.reason == "e2e_decrypt_failed"
        raise if op.upload && !op.upload.rewind

        again = false
        key = pol.key_for(op.desk, refresh: true, must: true, call: op.call)
        retry
      end
    end

    def open_plain(op)
      kw = { query: op.query, accept: op.accept, call: op.call }
      if op.upload&.bytes?
        request(op.method, op.path, body: op.upload.source, **kw) { |res| yield res, nil }
      elsif op.upload
        request(op.method, op.path, body_stream: op.upload.source, length: op.upload.size, **kw) { |res| yield res, nil }
      else
        request(op.method, op.path, json: op.json, **kw) { |res| yield res, nil }
      end
    end

    def open_sealed(op, key)
      seal = E2E.seal_request(key, op.desk, op.name, op.request)
      kw = { query: op.sealed_query, accept: op.accept, seal: seal, call: op.call }
      if op.method == "POST"
        request(op.method, op.path, json: { "e2e" => seal.envelope }, **kw) { |res| yield res, seal }
      elsif op.upload
        request(op.method, op.path, headers: { E2E::HEADER => seal.header }, body_stream: E2E::InputFrames.new(seal, op.upload),
                                    length: E2E.input_frames_length(op.upload.size), content_type: E2E::FRAMES_CONTENT_TYPE, **kw) do |res|
          yield res, seal
        end
      else
        request(op.method, op.path, headers: { E2E::HEADER => seal.header }, **kw) { |res| yield res, seal }
      end
    end
  end
end
