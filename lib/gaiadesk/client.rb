# frozen_string_literal: true

module GaiaDesk
  # Drive GaiaDesk desks through GaiaDesk's HTTP API.
  #
  # Three transports, the same methods, results and errors:
  #
  # * +:api+ (default): the hosted API, <tt>https://api.gaiadesk.net/v1</tt>, with an
  #   API key (+ak_…+) or a signed-in person's session token. Desk operations are
  #   end-to-end encrypted when the desk publishes a key.
  # * +:local+: code running on a desk talks to its own GaiaDesk over its Unix socket
  #   (macOS, Linux) or named pipe (Windows), with the desk's local admin token or an
  #   agent token.
  # * +:lan+: a desk's opt-in LAN gateway over HTTPS, its certificate pinned by
  #   fingerprint, with an agent token.
  #
  # Results are the CLI's own JSON objects as Hashes with String keys (+"exit"+,
  # +"stdout"+, +"job"+, ...), exactly the shapes of <tt>gaiadesk-cli --json</tt> and
  # the API's contract. Failures raise a subclass of {Error}.
  #
  # Every desk operation takes, per call, +desk_token:+ (a scoped agent token for
  # this call instead of the client's) and +wake:+ (if the desk is asleep, ring it
  # and wait up to this many seconds, 0-120).
  #
  # @example
  #   gd = GaiaDesk::Client.new(api_key: ENV["GAIADESK_API_KEY"], desk_token: ENV["GAIADESK_DESK_TOKEN"])
  #   r = gd.exec("123456789", "uname -a")
  #   puts r["stdout"]
  class Client
    # @return [Transport] the transport (its +name+ is +api+, +local+ or +lan+)
    attr_reader :transport

    OPTIONS = {
      "api" => %i[api_key desk_token base_url wake e2e e2e_keys on_warning],
      "local" => %i[desk_token token socket_path env],
      "lan" => %i[base_url fingerprint desk_token]
    }.freeze
    private_constant :OPTIONS

    # @param options [Hash] the transport's own options:
    # @param transport [Symbol, String] +:api+ (default), +:local+ or +:lan+
    # @option options [String] :api_key +:api+: an API key (+ak_…+) or a person's session token
    #   (default: <tt>$GAIADESK_API_KEY</tt>)
    # @option options [String] :desk_token a scoped agent token (+gdagt_…+), sent as
    #   <tt>X-GaiaDesk-Desk-Token</tt>. From an API key, desk operations need one.
    #   (+:api+ default: <tt>$GAIADESK_DESK_TOKEN</tt>; required for +:lan+)
    # @option options [String] :base_url +:api+: default <tt>https://api.gaiadesk.net/v1</tt>;
    #   +:lan+: <tt>https://<desk>:7443/v1</tt> (required)
    # @option options [Integer] :wake +:api+: if a desk is asleep, ring it and wait up to this many seconds (0-120)
    # @option options [Symbol] :e2e +:api+: +:auto+ (seal whenever the desk publishes a key),
    #   +:require+ (never in the clear) or +:off+
    # @option options [Hash{String => String}] :e2e_keys +:api+: <tt>{desk_id => e2e_pub}</tt> to pin desks' keys
    # @option options [#call] :on_warning +:api+: called with each one-time warning (default +Kernel#warn+)
    # @option options [String] :token +:local+: the desk's local admin token (default: the +api-token+ file)
    # @option options [String] :socket_path +:local+: another socket path or pipe name
    # @option options [Hash] :env +:local+: the environment to find the socket in (default +ENV+)
    # @option options [String] :fingerprint +:lan+: the gateway certificate's SHA-256 (as the desk's Settings shows it)
    # @param response_timeout [Numeric, nil] seconds an answer has to begin (its status and headers), sending the
    #   request included (default 16 minutes, above the API's 15-minute limit on a call; +nil+: no limit). Exceeded:
    #   an {UnreachableError}, kind +timeout+
    # @param idle_timeout [Numeric, nil] seconds a read of an answer's body (JSON, a download, an event stream) may
    #   wait (default 90; streams and held waits send a keep-alive every 15 s; +nil+: no limit). Exceeded: a
    #   {ConnectionLostError}, kind +timeout+
    # @param timeout [Numeric, nil] deprecated (0.1.0): sets +response_timeout+ and +idle_timeout+ both
    # @param open_timeout [Numeric, nil] seconds to connect
    # @param retries [Integer] how many times a request is sent again when that is safe (see the README)
    # @param max_retry_wait [Numeric] the longest +Retry-After+ honoured, in seconds
    # @raise [UsageError] for a missing or misplaced option
    def initialize(transport: :api, response_timeout: Transport::DEFAULT_RESPONSE_TIMEOUT, idle_timeout: Transport::DEFAULT_IDLE_TIMEOUT,
                   timeout: nil, open_timeout: 30, retries: 2, retry_base: 0.5, max_retry_wait: 60, **options)
      name = transport.to_s
      raise UsageError.new("transport is :api, :local or :lan (not #{transport.inspect})", kind: "usage") unless OPTIONS.key?(name)

      misplaced = options.keys - OPTIONS[name]
      raise UsageError.new("#{misplaced.join(', ')}: not an option of the #{name} transport", kind: "usage") unless misplaced.empty?

      http = { response_timeout: response_timeout, idle_timeout: idle_timeout, timeout: timeout, open_timeout: open_timeout,
               retries: retries, retry_base: retry_base, max_retry_wait: max_retry_wait }
      @transport = build(name, options, http)
    end

    # Which transport runs the operations: +"api"+, +"local"+ or +"lan"+.
    def backend
      @transport.name
    end

    # ───────────────────────────── desks ─────────────────────────────

    # The desks on the account and its team (<tt>GET /desks</tt>): <tt>{"devices", "sources",
    # "notes", "identity"}</tt>, online desks first. Over +local+ / +lan+: the desk itself.
    # @param desk_id [String, nil] only this desk
    # @return [Hash]
    def devices(desk_id: nil)
      @transport.devices(desk_id: desk_id)
    end

    # One desk (<tt>GET /desks/{id}</tt>): online or not, why it went offline, +features+,
    # +e2e_pub+, +e2e_required+ and its +wake+ hints. Hosted API only.
    # @return [Hash]
    def desk(desk_id)
      @transport.desk(desk_id)
    end

    # The desk's online / offline history (<tt>GET /desks/{id}/reach</tt>, newest first).
    # @param since [Integer, Time, nil] Unix seconds (default seven days ago; the log keeps thirty)
    # @param limit [Integer, nil] at most this many (1-1000, default 200)
    # @return [Hash] <tt>{"desk_id", "since", "events"}</tt>
    def reach(desk_id, since: nil, limit: nil)
      @transport.reach(desk_id, since: since, limit: limit)
    end

    # Ring the desk's doorbell and ask its LAN siblings to Wake-on-LAN it (<tt>POST /desks/{id}/wake</tt>).
    # @param wait [Integer, String, nil] wait up to this long (at most 90 s) for it to come online
    # @param idempotency_key [String, nil] a retry with the same key gets the first answer again
    # @return [Hash] <tt>{"desk_id", "online", "woke", "already_online", "rang", "waited_ms"}</tt>
    def wake(desk_id, wait: nil, idempotency_key: nil)
      @transport.wake(desk_id, wait: wait, call: call_opts(nil, nil, idempotency_key))
    end

    # ───────────────────────────── commands ─────────────────────────────

    # Run ONE command on a desk (<tt>POST /desks/{id}/exec</tt>): its exit code, stdout and stderr.
    #
    # @param command [String, Array<String>] a String is one command line for the desk's
    #   shell; an Array, separate arguments (each quoted for the desk's shell)
    # @param stdin [String, IO, nil] text for its stdin, then end of input
    # @param check [Boolean] raise {CommandError} when it exits non-zero
    # @param shell [String, Symbol, nil] +default+, +none+, +sh+, +bash+, +zsh+, +cmd+, +pwsh+ (+powershell+)
    # @param timeout [Integer, String, nil] stop it after this long (+"10m"+); at most 15 minutes
    # @param cwd [String, nil] the directory it starts in on the desk
    # @param env [Hash{String => String}, nil] environment variables (never logged)
    # @param admin [Boolean] run it as administrator (root / SYSTEM): needs a token with the
    #   +admin+ scope and the desk owner's Admin access; a refusal is a {RefusedError}
    #   whose {Error#admin_refusal?} is true
    # @return [Hash] the ExecResult: +exit+, +stdout+, +stderr+, +remote_code+, +timed_out+, +error+, ...
    # @raise [RefusedError, UnreachableError, ...] when the command never ran
    def exec(desk_id, command, stdin: nil, check: false, shell: nil, timeout: nil, cwd: nil, env: nil, admin: false,
             desk_token: nil, wake: nil, idempotency_key: nil)
      @transport.exec(desk_id, command, check: check, stdin: stdin, shell: shell, timeout: timeout, cwd: cwd, env: env, admin: admin,
                                        call: call_opts(desk_token, wake, idempotency_key))
    end

    # {#exec}, streaming (<tt>?stream=1</tt>): the output as it is produced.
    #
    # Without a block, the {Stream} (Enumerable over {Chunk}s; +wait+, +result+, +kill+).
    # With a block, each {Chunk} is yielded as it arrives and the finished {Stream} is
    # returned (its +result+ is the +exit+ or +error+ event).
    #
    # @example
    #   s = gd.exec_stream(desk, ["make", "test"]) { |c| print c.text }
    #   s.result["exit"]
    # @return [Stream]
    def exec_stream(desk_id, command, stdin: nil, shell: nil, timeout: nil, cwd: nil, env: nil, admin: false,
                    desk_token: nil, wake: nil, &block)
      s = @transport.exec_stream(desk_id, command, stdin: stdin, shell: shell, timeout: timeout, cwd: cwd, env: env, admin: admin,
                                                   call: call_opts(desk_token, wake))
      drain(s, &block)
    end
    # ───────────────────────────── jobs ─────────────────────────────

    # Start a named background job that outlives this request (<tt>POST /desks/{id}/jobs</tt>).
    # @param name [String] letters, digits, <tt>. _ -</tt>
    # @param command [String, Array<String>] one command line, or words
    # @param priority [String, nil] +low+, +normal+, ...
    # @param cpu [Integer, nil] CPU cap, percent
    # @param mem [Integer, String, nil] memory cap: megabytes, or +"512M"+ / +"4G"+
    # @param keep_awake [Boolean, nil] keep the desk awake while it runs
    # @param cwd [String, nil] where it starts
    # @param shell [String, nil] +sh+, +bash+, +zsh+, +cmd+, +pwsh+ (+powershell+)
    # @param env [Hash, nil] environment variables
    # @return [Hash] the Job
    def run_job(desk_id, name, command, priority: nil, cpu: nil, mem: nil, keep_awake: nil, cwd: nil, shell: nil, env: nil,
                desk_token: nil, wake: nil, idempotency_key: nil)
      @transport.run_job(desk_id, name, command, priority: priority, cpu: cpu, mem: mem, keep_awake: keep_awake, cwd: cwd,
                                                 shell: shell, env: env, call: call_opts(desk_token, wake, idempotency_key))
    end

    # The desk's background jobs (<tt>GET /desks/{id}/jobs</tt>).
    # @return [Array<Hash>]
    def jobs(desk_id, desk_token: nil, wake: nil)
      @transport.jobs(desk_id, call: call_opts(desk_token, wake))
    end

    # Block until a job is no longer running (<tt>GET …/jobs/{name}/wait</tt>).
    # @param timeout [Integer, String, nil] give up then: +timed_out+ is true and the job still running
    # @return [Hash] <tt>{"job", "timed_out"}</tt>; a job that exited non-zero is a result, not an error
    def wait_job(desk_id, name, timeout: nil, desk_token: nil, wake: nil)
      @transport.wait_job(desk_id, name, timeout: timeout, call: call_opts(desk_token, wake))
    end

    # Stop a job and everything it started (<tt>DELETE /desks/{id}/jobs/{name}</tt>).
    # @return [Hash] the Job
    def kill_job(desk_id, name, desk_token: nil, wake: nil)
      @transport.kill_job(desk_id, name, call: call_opts(desk_token, wake))
    end

    # A job's output so far, stdout and stderr together (<tt>GET …/jobs/{name}/logs</tt>).
    # @param tail [Integer, nil] only the last this many bytes
    # @return [String]
    def job_logs(desk_id, name, tail: nil, desk_token: nil, wake: nil)
      r = job_log_result(desk_id, name, tail: tail, desk_token: desk_token, wake: wake)
      r.is_a?(Hash) && r["output"].is_a?(String) ? r["output"] : ""
    end

    # The whole JobLogs answer: <tt>{"job", "output"}</tt>.
    # @return [Hash]
    def job_log_result(desk_id, name, tail: nil, desk_token: nil, wake: nil)
      @transport.job_logs(desk_id, name, tail: tail, call: call_opts(desk_token, wake))
    end

    # Follow a job's output until it ends (<tt>?follow=1</tt>). {Stream#kill} stops following, not the job.
    # Its +result+ is the +end+ (the job as it ended), +interrupted+ or +error+ event.
    # With a block, as {#exec_stream}.
    # @return [Stream]
    def follow_job_logs(desk_id, name, tail: nil, desk_token: nil, wake: nil, &block)
      drain(@transport.follow_job_logs(desk_id, name, tail: tail, call: call_opts(desk_token, wake)), &block)
    end

    # CPU, memory, disks and running jobs, as the desk measures them (<tt>GET /desks/{id}/stats</tt>).
    # @return [Hash] the StatsReport
    def stats(desk_id, desk_token: nil, wake: nil)
      @transport.stats(desk_id, call: call_opts(desk_token, wake))
    end

    # ───────────────────────────── files ─────────────────────────────

    # Upload one file (<tt>PUT /desks/{id}/files?path=</tt>, at most 256 MB).
    # @param local [String, IO] a path, or an IO to read (give +size:+ when it cannot be known)
    # @param remote [String] the path on the desk; ending in +/+ keeps the local file's name
    # @return [Hash] the CopyResult
    # @raise [OperationFailedError] when the desk could not write it
    def upload(local, desk_id, remote, size: nil, desk_token: nil, wake: nil)
      @transport.upload(local, desk_id, remote, size: size, call: call_opts(desk_token, wake))
    end

    # Write bytes in memory to +remote+ on the desk.
    # @return [Hash] the CopyResult
    def upload_bytes(data, desk_id, remote, desk_token: nil, wake: nil)
      @transport.upload_bytes(data, desk_id, remote, call: call_opts(desk_token, wake))
    end

    # Download one file (<tt>GET /desks/{id}/files?path=</tt>, at most 256 MB).
    # @param local [String, IO] a path (a folder, or a path ending in a separator, keeps the
    #   remote name), or an IO to write to
    # @return [Hash] the CopyResult
    def download(desk_id, remote, local, desk_token: nil, wake: nil)
      @transport.download(desk_id, remote, local, call: call_opts(desk_token, wake))
    end

    # A file's bytes (a binary String).
    # @return [String]
    def download_bytes(desk_id, remote, desk_token: nil, wake: nil)
      @transport.download_bytes(desk_id, remote, call: call_opts(desk_token, wake))
    end

    # A file's bytes to the block as they arrive (no file system needed). Without a
    # block, an Enumerator of the chunks.
    # @yieldparam bytes [String] binary
    # @return [Hash, nil] the desk's CopyResult when the download was end-to-end encrypted
    def download_stream(desk_id, remote, desk_token: nil, wake: nil, &block)
      return enum_for(:download_stream, desk_id, remote, desk_token: desk_token, wake: wake) unless block

      @transport.download_stream(desk_id, remote, call: call_opts(desk_token, wake), &block)
    end

    # ───────────────────────────── tokens ─────────────────────────────

    # Mint a scoped agent token on each desk (<tt>POST /desks/{id}/tokens</tt>). Token
    # administration is the desk owner's: a signed-in person's own session on their own desk.
    # @param desks [String, Array<String>]
    # @param name [String]
    # @param expires [Integer, String] default +"7d"+
    # @param scopes [Array<String>] default <tt>exec cp jobs</tt>; +admin+ is never implied
    # @param cwd [String, nil] confine its work to this folder
    # @param low_priv [Boolean] run its work as the desk's low-privilege agent user
    # @return [Hash] <tt>{"tokens" => [...]}</tt>, each with its +secret+ (shown once)
    def create_token(desks, name:, expires: nil, scopes: nil, cwd: nil, low_priv: false, desk_token: nil, wake: nil,
                     idempotency_key: nil)
      @transport.create_token(desks, name: name, expires: expires, scopes: scopes, cwd: cwd, low_priv: low_priv,
                                     call: call_opts(desk_token, wake, idempotency_key))
    end

    # The desk's agent tokens (never their secrets).
    # @return [Array<Hash>]
    def list_tokens(desk_id, desk_token: nil, wake: nil)
      @transport.list_tokens(desk_id, call: call_opts(desk_token, wake))
    end

    # Revoke an agent token by id or name; its live sessions and jobs end.
    # @return [Hash] <tt>{"revoked", "stopped_sessions"}</tt>
    def revoke_token(desk_id, token_id, desk_token: nil, wake: nil)
      @transport.revoke_token(desk_id, token_id, call: call_opts(desk_token, wake))
    end

    # ───────────────────────────── audit ─────────────────────────────

    # Audit events about the caller and their own desks, newest first (<tt>GET /audit</tt>).
    # @param desk [String, nil] only events about this desk
    # @param actor [String, nil] only events by this actor id
    # @param action [String, nil] only this action, or every one under a prefix ending +.*+ (+"api.*"+)
    # @param token [String, nil] only events by this agent token id or API key id
    # @param since_ms [Integer, Time, nil]
    # @param until_ms [Integer, Time, nil]
    # @param limit [Integer, nil] at most this many (1-500, default 100)
    # @return [Array<Hash>]
    def audit(desk: nil, actor: nil, action: nil, token: nil, since_ms: nil, until_ms: nil, limit: nil)
      @transport.audit(desk: desk, actor: actor, action: action, token: token, since_ms: since_ms, until_ms: until_ms, limit: limit)
    end

    # Every audit event matching the filters, newest first, fetched a page at a time
    # (+page_size+ per request, walking back with +until_ms+). Without a block, a lazy
    # Enumerator.
    # @yieldparam event [Hash]
    def each_audit_event(desk: nil, actor: nil, action: nil, token: nil, since_ms: nil, until_ms: nil, page_size: 500, &block)
      filters = { desk: desk, actor: actor, action: action, token: token, since_ms: since_ms }
      pages = Pagination.audit(@transport, filters, until_ms, page_size)
      return pages.lazy unless block

      pages.each(&block)
    end
    # ───────────────────────────── webhooks ─────────────────────────────

    # The account's webhook subscriptions (never their secrets).
    # @return [Array<Hash>]
    def webhooks
      @transport.webhooks
    end

    # Subscribe an HTTPS endpoint to events. Keep the answer's +secret+: it is never shown again.
    # @param events [Array<String>] of {Account::WEBHOOK_EVENTS}
    # @return [Hash]
    def create_webhook(url:, events:, description: nil, idempotency_key: nil)
      @transport.create_webhook(url: url, events: events, description: description, call: call_opts(nil, nil, idempotency_key))
    end

    # Unsubscribe (deliveries still queued for it are dropped).
    # @return [Hash] <tt>{"deleted"}</tt>
    def delete_webhook(webhook_id)
      @transport.delete_webhook(webhook_id)
    end

    # ───────────────────────────── support sessions ─────────────────────────────

    # Create a support session for the embed SDK. Keep +embed_token+ for the page: it is never shown again.
    # @param mode [Symbol, String, nil] +:view+ (default) or +:cobrowse+
    # @param customer [Hash, nil] who the customer is (at most 16 short fields)
    # @param expires_in [Integer, String, nil] seconds until it ends (60 to 86400; default 3600)
    # @param origin [String, nil] the page origin the embed must run on
    # @return [Hash] the session, with +id+, +join_code+, +join_url+ and +embed_token+
    def create_support_session(mode: nil, customer: nil, expires_in: nil, origin: nil, idempotency_key: nil)
      @transport.create_support_session(mode: mode, customer: customer, expires_in: expires_in, origin: origin,
                                        call: call_opts(nil, nil, idempotency_key))
    end

    # The support sessions of the account and its team, newest first.
    # @param state [Symbol, nil] +:open+ (default) or +:all+
    # @return [Array<Hash>]
    def support_sessions(state: nil, limit: nil)
      @transport.support_sessions(state: state, limit: limit)
    end

    # One support session's state.
    # @return [Hash]
    def support_session(session_id)
      @transport.support_session(session_id)
    end

    private

    def build(name, options, http)
      case name
      when "api"
        key = options.fetch(:api_key, ENV.fetch("GAIADESK_API_KEY", nil))
        raise UsageError.new("the api transport needs api_key (or $GAIADESK_API_KEY)", kind: "usage") if key.nil?

        token = options.key?(:desk_token) ? options[:desk_token] : env_token
        Transport.new(api_key: key, desk_token: token, base_url: options[:base_url], wake: options[:wake],
                      e2e: options.fetch(:e2e, :auto), e2e_keys: options[:e2e_keys], on_warning: options[:on_warning], **http)
      when "local"
        LocalTransport.new(desk_token: options[:desk_token], token: options[:token], socket_path: options[:socket_path],
                           env: options.fetch(:env, ENV), **http)
      else
        LanTransport.new(base_url: options[:base_url], fingerprint: options[:fingerprint], desk_token: options[:desk_token], **http)
      end
    end

    def env_token
      t = ENV.fetch("GAIADESK_DESK_TOKEN", nil)
      t.nil? || t.strip.empty? ? nil : t
    end

    def call_opts(desk_token, wake, idempotency_key = nil)
      c = {}
      c[:desk_token] = desk_token unless desk_token.nil?
      c[:wake] = Transport.check_wake(wake) unless wake.nil?
      unless idempotency_key.nil?
        k = idempotency_key.to_s
        unless k.match?(/\A[\x20-\x7e]{1,255}\z/)
          raise UsageError.new("idempotency_key is 1 to 255 printable ASCII characters", kind: "usage")
        end

        c[:idempotency_key] = k
      end
      c
    end

    def drain(stream, &)
      return stream unless block_given?

      stream.each(&)
      stream.wait
      stream
    end
  end

  # Paging helpers.
  module Pagination
    module_function

    # Every audit event, newest first: a page at a time, each next page ending
    # (+until_ms+) at the oldest event seen so far; events already seen are skipped.
    # @return [Enumerator]
    def audit(transport, filters, until_ms, page_size)
      Enumerator.new do |y|
        seen = {}
        upper = until_ms
        loop do
          page = transport.audit(**filters, until_ms: upper, limit: page_size)
          fresh = page.reject { |e| seen[e["id"]] }
          fresh.each do |e|
            seen[e["id"]] = true
            y << e
          end
          break if page.size < page_size

          oldest = page.map { |e| e["occurred_at_ms"] }.grep(Integer).min
          break if oldest.nil?

          # A page of nothing new means one millisecond holds a full page: step past it.
          upper = fresh.empty? ? oldest - 1 : oldest
        end
      end
    end
  end
end
