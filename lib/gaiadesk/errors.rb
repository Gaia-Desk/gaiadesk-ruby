# frozen_string_literal: true

module GaiaDesk
  # Base class of every error the SDK raises.
  #
  # Every failure of the GaiaDesk API is one envelope,
  # <tt>{"error": {"kind", "message", "reason"?, "desk"?, "request_id"}}</tt>, the
  # same object <tt>gaiadesk-cli --json</tt> prints. +kind+ is one of six
  # (+usage+, +refused+, +unreachable+, +connection_lost+, +failed+, +protocol+)
  # and picks the subclass; +reason+ is the finer cause. Rescue a subclass, or
  # branch on {#kind} / {#reason}.
  #
  # {#kind} is the finer reason when it is a well-known one (+offline+,
  # +unknown_desk+, +network+, +timeout+, ...), else the envelope's kind, or an
  # SDK kind (+e2e+, +local+).
  class Error < StandardError
    # @return [String] the kind (see the class description)
    attr_reader :kind
    # @return [String, nil] the finer cause the API gave (+missing_scope+, +desk_busy+, +admin_not_via_api+, ...)
    attr_reader :reason
    # @return [String, nil] the desk the failure concerned, when the API said
    attr_reader :desk
    # @return [Integer, nil] what +gaiadesk-cli+ would have exited with (254 refused, 1 failed, 255 its own error, ...)
    attr_reader :exit_code
    # @return [Integer, nil] the HTTP status of the failed request
    attr_reader :status
    # @return [String, nil] the failed request's id (+req_…+), to quote to support
    attr_reader :request_id
    # @return [Float, nil] seconds to wait before retrying (a 429's +Retry-After+)
    attr_reader :retry_after
    # @return [Array<String>] the operation (<tt>["POST /desks/123456789/exec"]</tt>)
    attr_reader :argv
    # @return [Object, nil] the parsed answer (the error envelope, or the result it came with)
    attr_accessor :json

    def initialize(message = nil, kind: "error", reason: nil, desk: nil, exit_code: nil, status: nil, request_id: nil,
                   retry_after: nil, argv: [], json: nil)
      super(message)
      @kind = kind
      @reason = reason
      @desk = desk
      @exit_code = exit_code
      @status = status
      @request_id = request_id
      @retry_after = retry_after
      @argv = Array(argv)
      @json = json
    end
  end

  # Bad arguments (kind +usage+), caught by the SDK or by the API (HTTP 400).
  class UsageError < Error; end

  # The credential or the desk said no (kind +refused+; HTTP 401, 403, 429; exit 254):
  # a missing scope, an expired or revoked token, the desk's opt-out, a rate limit,
  # administrator work asked of the API ({ADMIN_NOT_VIA_API}).
  class RefusedError < Error; end

  # The desk could not be reached (kind +unreachable+; HTTP 404, 409, 503, 504):
  # +unknown_desk+, offline (+silent+, +closed+, ...), +no_wake_path+, +network+.
  class UnreachableError < Error; end

  # The desk went away mid-operation (kind +connection_lost+; HTTP 502).
  class ConnectionLostError < Error; end

  # The operation ran and did not succeed (kind +failed+; HTTP 422, 500; exit 1):
  # a file failed to copy, no such job, ...
  class OperationFailedError < Error; end

  # The answer is not what the contract says (kind +protocol+): a desk too old for
  # the request (+desk_too_old+), or something that is not the documented JSON.
  class ProtocolError < Error; end

  # An operation could not be end-to-end encrypted, or its sealed answer did not
  # open (kind +e2e+). {#reason} says which: +e2e_unavailable+ (the desk publishes
  # no key where encryption is required), +e2e_key_mismatch+ (the server handed
  # out a key other than the pinned one), +e2e_decrypt_failed+ / +e2e_malformed+
  # (an answer was altered, reordered or not sealed). Nothing is sent in the clear
  # when this is raised before a request.
  class EndToEndError < Error; end

  # The +lan+ transport: the gateway's certificate is not the pinned one (kind
  # +unreachable+, reason +fingerprint_mismatch+). Nothing was sent to it.
  class FingerprintMismatchError < UnreachableError; end

  # <tt>exec(check: true)</tt>: the command ran and exited non-zero (or timed out).
  class CommandError < Error
    # @return [Hash] the whole ExecResult
    attr_reader :result

    def initialize(message, result:, **kw)
      super(message, **kw)
      @result = result
    end
  end

  # The six kinds of the error envelope.
  KINDS = %w[usage refused unreachable connection_lost failed protocol].freeze

  # The +reason+ of a RefusedError for administrator work (root / SYSTEM) asked of the API:
  # an +"admin": true+ exec or a token with the +admin+ scope. Administrator work runs only
  # through <tt>gaiadesk-cli exec --admin</tt>.
  ADMIN_NOT_VIA_API = "admin_not_via_api"

  # Helpers that map the API's error envelope onto the classes above.
  module Errors
    CLASSES = {
      "usage" => UsageError,
      "refused" => RefusedError,
      "unreachable" => UnreachableError,
      "connection_lost" => ConnectionLostError,
      "failed" => OperationFailedError,
      "protocol" => ProtocolError
    }.freeze

    UNREACHABLE_REASONS = %w[offline unknown_desk not_online network not_signed_in timeout].freeze
    # Finer causes (the envelope's +reason+) that become the error's +kind+.
    REASONS = (UNREACHABLE_REASONS + %w[connection_lost local interrupted]).freeze

    # What an answer says went wrong.
    Envelope = Struct.new(:kind, :message, :reason, :desk)

    module_function

    # The class for an envelope kind.
    def error_class(kind)
      CLASSES.fetch(kind, Error)
    end

    # The error's +kind+: the finer reason when it is a known one, else the kind.
    def sdk_kind(kind, reason)
      reason.is_a?(String) && REASONS.include?(reason) ? reason : kind
    end

    # THE place that knows how an error is spelled in the API's JSON:
    # <tt>{"error": {"kind", "message", "reason"?, "desk"?}}</tt>. +nil+ when the
    # JSON is not an error (including exec's own <tt>"error": null</tt>).
    # @return [Envelope, nil]
    def envelope(parsed)
      return nil unless parsed.is_a?(Hash)

      e = parsed["error"]
      return nil unless e.is_a?(Hash) && e["kind"].is_a?(String)

      Envelope.new(e["kind"], e["message"].is_a?(String) ? e["message"] : "", opt_str(e["reason"]), opt_str(e["desk"]))
    end

    def opt_str(value)
      value.is_a?(String) && !value.empty? ? value : nil
    end

    # The typed error for an envelope kind.
    def for_kind(kind, message, reason = nil, **details)
      error_class(kind).new(message, kind: sdk_kind(kind, reason), reason: reason, **details)
    end

    # gaiadesk-cli's exit code for a desk operation that failed with this kind.
    def exit_for(kind)
      { "refused" => 254, "failed" => 1, "interrupted" => 130 }.fetch(kind.to_s, 255)
    end

    # An exec result: returned, or the error it means. A command that never ran
    # (or whose connection went) is its typed error; +failed+ is the command's own
    # failure (could not start, stopped, timed out), a result unless nothing ran.
    def exec_outcome(result, check, op)
      env = envelope(result)
      if env
        never_ran = result["remote_code"].nil? && result["exit"] == 255
        if env.kind != "failed" || never_ran
          raise for_kind(env.kind, env.message.empty? ? env.kind : env.message, env.reason,
                         exit_code: result["exit"], argv: [op], json: result, desk: env.desk || opt_str(result["desk"]))
        end
      end
      if check && result["exit"] != 0
        why = result["timed_out"] ? "timed out" : "exited #{result['exit']}"
        raise CommandError.new("command on desk #{result['desk']} #{why}", result: result, kind: "failed",
                                                                           exit_code: result["exit"], argv: [op], json: result)
      end
      result
    end
  end
end
