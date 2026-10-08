# frozen_string_literal: true

require "etc"
require "socket"

module GaiaDesk
  # Where a desk's local API lives, and how its name is spelled (pure helpers).
  #
  # * macOS, Linux: the Unix socket <tt>$GAIADESK_API_DIR/api.sock</tt> (else
  #   <tt>~/.gaiadesk/api.sock</tt>), with the local admin token in +api-token+ beside it.
  # * Windows: the named pipe <tt>\\\\.\\pipe\\gaiadesk-api-<user></tt>
  #   (<tt>$GAIADESK_API_PIPE</tt>), the token in <tt>%USERPROFILE%\\.gaiadesk\\api-token</tt>.
  module Local
    PIPE_PREFIX = "\\\\.\\pipe\\"
    # What a client says when nothing serves the local API.
    UNAVAILABLE = "GaiaDesk is not serving its local API here: is the app running, and is " \
                  "Settings → GaiaDesk API → Local API on?"

    module_function

    # <tt>$GAIADESK_API_DIR</tt> when it is an absolute path, else <tt>~/.gaiadesk</tt>.
    def api_dir(env = ENV)
      d = env["GAIADESK_API_DIR"]
      return d if d && !d.empty? && absolute?(d)

      File.join(Dir.home, ".gaiadesk")
    end

    def absolute?(path)
      path.start_with?("/") || path.match?(%r{\A[A-Za-z]:[\\/]}) || path.start_with?("\\\\")
    end

    # The local API's Unix socket: <tt><api_dir>/api.sock</tt>.
    def socket_path(env = ENV)
      File.join(api_dir(env), "api.sock")
    end

    # The desk's local admin token file: <tt><api_dir>/api-token</tt>.
    def token_path(env = ENV)
      File.join(api_dir(env), "api-token")
    end

    # A user name as the pipe name has it: lowercased, every character outside
    # <tt>[a-z0-9._-]</tt> replaced by +_+, at most 64 characters, +user+ if empty.
    def pipe_user(user)
      u = user.to_s.downcase.gsub(/[^a-z0-9._-]/, "_")[0, 64]
      u.empty? ? "user" : u
    end

    # <tt>$GAIADESK_API_PIPE</tt>, else <tt>\\\\.\\pipe\\gaiadesk-api-<user></tt>
    # (<tt><user></tt>: <tt>%USERNAME%</tt>, else the login name).
    def pipe_name(env = ENV)
      return env["GAIADESK_API_PIPE"] if env["GAIADESK_API_PIPE"] && !env["GAIADESK_API_PIPE"].empty?

      user = env["USERNAME"].to_s
      if user.empty?
        user = begin
          Etc.getlogin.to_s
        rescue StandardError
          ""
        end
      end
      "#{PIPE_PREFIX}gaiadesk-api-#{pipe_user(user)}"
    end

    # This platform's local API address: the named pipe on Windows, else the Unix socket.
    def default_address(env = ENV)
      windows? ? pipe_name(env) : socket_path(env)
    end

    def windows?
      Gem.win_platform?
    end

    # An address starting with <tt>\\\\.\\pipe\\</tt> (any case, either slash) is a named pipe.
    def pipe?(address)
      address.tr("/", "\\").downcase.start_with?(PIPE_PREFIX)
    end
  end

  # The +local+ transport: the desk's own <tt>/v1</tt>, over its Unix socket or named
  # pipe. Credentials: an agent token as <tt>X-GaiaDesk-Desk-Token</tt>, else the
  # desk's local admin token (+gdlocal_…+) as Bearer. Never sealed: nothing leaves
  # the machine.
  class LocalTransport < Transport
    # @return [String] the socket path or pipe name
    attr_reader :address

    # How long to retry a pipe whose every instance is busy, in seconds.
    PIPE_BUSY_WAIT = 5.0

    # rubocop:disable-next Lint/MissingSuper
    def initialize(desk_token: nil, token: nil, socket_path: nil, timeout: nil, open_timeout: 30, retries: 2, retry_base: 0.5,
                   max_retry_wait: 60, env: ENV)
      @name = "local"
      @desk_token = Transport.check_desk_token(desk_token)
      if !token.nil? && !(token.is_a?(String) && !token.strip.empty?)
        raise UsageError.new("token must be a non-empty String (the desk's local admin token, gdlocal_…)", kind: "usage")
      end
      if token && @desk_token
        raise UsageError.new("give desk_token (an agent token) or token (the local admin token), not both", kind: "usage")
      end

      @env = env
      @token = token&.strip
      @address = socket_path || Local.default_address(env)
      @pipe = Local.pipe?(@address)
      @base_url = "#{@pipe ? 'pipe' : 'unix'}:#{@address}"
      @prefix = "/v1"
      @wake_secs = nil
      @e2e = nil
      set_http_options(timeout, open_timeout, retries, retry_base, max_retry_wait)
    end

    # The desk's local admin token: +token:+, else the +api-token+ file (read on every
    # request: it changes when the app does).
    def admin_token
      return @token if @token

      path = Local.token_path(@env)
      t = begin
        File.read(path, encoding: "UTF-8").strip
      rescue SystemCallError => e
        raise UnreachableError.new("#{Local::UNAVAILABLE} (no local admin token at #{path}: #{e.message}; or give desk_token:)",
                                   kind: "unreachable", reason: "local_api_unavailable", exit_code: 255, argv: ["local"])
      end
      if t.empty?
        raise UnreachableError.new("#{Local::UNAVAILABLE} (the local admin token file #{path} is empty)",
                                   kind: "unreachable", reason: "local_api_unavailable", exit_code: 255, argv: ["local"])
      end
      t
    end

    # An agent token as <tt>X-GaiaDesk-Desk-Token</tt> (no Authorization), else the admin token as Bearer.
    def credentials(call = {})
      token = call[:desk_token] ? Transport.check_desk_token(call[:desk_token]) : @desk_token
      return { "X-GaiaDesk-Desk-Token" => token } if token

      { "Authorization" => "Bearer #{admin_token}" }
    end

    def connection
      address = @address
      connector = if @pipe
                    -> { HTTP::PipeIO.new(open_pipe(address)) }
                  else
                    lambda {
                      raise Errno::EAFNOSUPPORT, "Unix sockets are not available on this platform" unless defined?(UNIXSocket)

                      UNIXSocket.new(address)
                    }
                  end
      apply_timeouts(HTTP::SocketHTTP.over(connector))
    end

    def network_error(error, op)
      if error.is_a?(Errno::ENOENT) || error.is_a?(Errno::ECONNREFUSED)
        return UnreachableError.new("#{Local::UNAVAILABLE} (nothing listening at #{@address})",
                                    kind: "unreachable", reason: "local_api_unavailable", exit_code: 255, argv: [op])
      end

      UnreachableError.new("GaiaDesk's local API (#{@address}) could not be reached: #{error.message}",
                           kind: "network", reason: "network", exit_code: 255, argv: [op])
    end

    private

    def open_pipe(name)
      deadline = E2E.now + PIPE_BUSY_WAIT
      begin
        File.open(name, "r+b")
      rescue Errno::EBUSY, Errno::EAGAIN
        raise if E2E.now > deadline

        sleep 0.05
        retry
      end
    end
  end

  # The +lan+ transport: a desk's LAN gateway (<tt>https://<desk>:7443/v1</tt>), its
  # self-signed certificate pinned by SHA-256 fingerprint (checked right after the
  # handshake, before any request byte is sent). Agent tokens only.
  class LanTransport < Transport
    # @return [String] the pinned fingerprint, normalized
    attr_reader :fingerprint

    # rubocop:disable-next Lint/MissingSuper
    def initialize(base_url:, fingerprint:, desk_token:, timeout: nil, open_timeout: 30, retries: 2, retry_base: 0.5, max_retry_wait: 60)
      @name = "lan"
      if base_url.nil? || base_url.to_s.empty?
        raise UsageError.new("the lan transport needs base_url (https://<desk>:7443/v1, from the desk's Settings)", kind: "usage")
      end

      set_base(base_url, %w[https], "the lan transport's base_url must be an https:// URL: #{base_url.inspect}")
      if fingerprint.nil?
        raise UsageError.new("the lan transport needs fingerprint (the gateway certificate's SHA-256, from the desk's Settings)",
                             kind: "usage")
      end

      @fingerprint = HTTP.normalize_fingerprint(fingerprint)
      @desk_token = Transport.check_desk_token(desk_token)
      if @desk_token.nil?
        raise UsageError.new("the lan transport needs desk_token (a scoped agent token, gdagt_…): the LAN gateway takes " \
                             "agent tokens only", kind: "usage")
      end

      @wake_secs = nil
      @e2e = nil
      set_http_options(timeout, open_timeout, retries, retry_base, max_retry_wait)
    end

    # The agent token as <tt>X-GaiaDesk-Desk-Token</tt>; no Authorization.
    def credentials(call = {})
      { "X-GaiaDesk-Desk-Token" => call[:desk_token] ? Transport.check_desk_token(call[:desk_token]) : @desk_token }
    end

    # TLS with no chain or hostname check: the pin, checked in {#after_connect}, is the identity.
    def connection
      http = Net::HTTP.new(@host, @port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      http.verify_hostname = false if http.respond_to?(:verify_hostname=)
      apply_timeouts(http)
    end

    # The certificate must be the pinned one, else {FingerprintMismatchError} and nothing is sent.
    def after_connect(http, op)
      cert = http.peer_cert
      got = cert ? HTTP.certificate_fingerprint(cert) : "none"
      return if got == @fingerprint

      http.finish
      raise FingerprintMismatchError.new(
        "the desk at #{@host}:#{@port} did not prove the identity you pinned: its certificate's SHA-256 fingerprint is " \
        "#{got}, not the pinned #{@fingerprint} (check the fingerprint in the desk's Settings → GaiaDesk API)",
        kind: "unreachable", reason: "fingerprint_mismatch", exit_code: 255, argv: [op]
      )
    end

    def network_error(error, op)
      UnreachableError.new("the desk's LAN gateway (#{@base_url}) could not be reached: #{error.message} (#{error.class})",
                           kind: "network", reason: "network", exit_code: 255, argv: [op])
    end
  end
end
