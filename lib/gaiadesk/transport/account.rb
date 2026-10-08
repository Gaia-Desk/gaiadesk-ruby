# frozen_string_literal: true

require "uri"

module GaiaDesk
  # The hosted API's own routes (not desk operations): one desk and its reach log,
  # waking, the audit trail, webhooks and support sessions. Mixed into {Transport};
  # documented on {Client}. The desk-served transports (+local+, +lan+) do not serve them.
  module Account
    # The webhook events a subscription can name.
    WEBHOOK_EVENTS = %w[desk.online desk.offline desk.woke job.finished support.session.joined support.session.ended].freeze
    # A support session's modes.
    SUPPORT_MODES = %w[view cobrowse].freeze

    # <tt>GET /desks/{id}</tt>: one desk, with +features+, +e2e_pub+, +e2e_required+ and +wake+ hints.
    def desk(desk_id, call: {})
      account_only("desk")
      json_call("GET", desk_path(desk_id), wake: false, call: call)
    end

    # <tt>GET /desks/{id}/reach</tt>: <tt>{"desk_id", "since", "events"}</tt>, newest first.
    def reach(desk_id, since: nil, limit: nil, call: {})
      account_only("reach")
      query = { "since" => int_or_nil(since, "since"), "limit" => int_or_nil(limit, "limit") }
      json_call("GET", "#{desk_path(desk_id)}/reach", query: query, wake: false, call: call)
    end

    # <tt>POST /desks/{id}/wake</tt>: <tt>{"desk_id", "online", "woke", "already_online", "rang", "waited_ms"}</tt>.
    def wake(desk_id, wait: nil, call: {})
      account_only("wake")
      body = {}
      unless wait.nil?
        w = Args.seconds(wait, "wait")
        raise UsageError.new("wait is at most 90 seconds", kind: "usage") if w > 90

        body["wait_s"] = w
      end
      json_call("POST", "#{desk_path(desk_id)}/wake", json: body, wake: false, call: call)
    end

    # <tt>GET /audit</tt>: the events (newest first).
    def audit(desk: nil, actor: nil, action: nil, token: nil, since_ms: nil, until_ms: nil, limit: nil, call: {})
      account_only("audit")
      q = { "desk" => desk && Args.check_desk(desk), "actor" => actor, "action" => action, "token" => token,
            "since_ms" => ms_or_nil(since_ms, "since_ms"), "until_ms" => ms_or_nil(until_ms, "until_ms"),
            "limit" => int_or_nil(limit, "limit") }
      r = json_call("GET", "/audit", query: q, wake: false, call: call)
      list_field(r, "events", "GET /audit")
    end

    # <tt>GET /webhooks</tt>: the subscriptions (never their secrets).
    def webhooks(call: {})
      account_only("webhooks")
      list_field(json_call("GET", "/webhooks", wake: false, call: call), "webhooks", "GET /webhooks")
    end

    # <tt>POST /webhooks</tt>: the subscription with its +secret+ (shown once).
    def create_webhook(url:, events:, description: nil, call: {})
      account_only("create_webhook")
      list = Array(events).map(&:to_s)
      raise UsageError.new("create_webhook needs at least one event", kind: "usage") if list.empty?

      unknown = list - WEBHOOK_EVENTS
      raise UsageError.new("unknown webhook event(s): #{unknown.join(', ')}", kind: "usage") unless unknown.empty?

      body = { "url" => url.to_s, "events" => list }
      body["description"] = description.to_s unless description.nil?
      json_call("POST", "/webhooks", json: body, wake: false, call: call)
    end

    # <tt>DELETE /webhooks/{webhook_id}</tt>: <tt>{"deleted"}</tt>.
    def delete_webhook(webhook_id, call: {})
      account_only("delete_webhook")
      id = webhook_id.to_s
      raise UsageError.new("not a webhook id: #{webhook_id.inspect}", kind: "usage") unless id.match?(/\Awh_[0-9a-f]{16}\z/)

      json_call("DELETE", "/webhooks/#{id}", wake: false, call: call)
    end

    # <tt>POST /support/sessions</tt>: the session with its +embed_token+ (shown once).
    def create_support_session(mode: nil, customer: nil, expires_in: nil, origin: nil, call: {})
      account_only("create_support_session")
      body = {}
      unless mode.nil?
        raise UsageError.new("mode is :view or :cobrowse", kind: "usage") unless SUPPORT_MODES.include?(mode.to_s)

        body["mode"] = mode.to_s
      end
      body["customer"] = customer.transform_keys(&:to_s) unless customer.nil?
      body["expires_in"] = Args.seconds(expires_in, "expires_in") unless expires_in.nil?
      body["origin"] = origin.to_s unless origin.nil?
      json_call("POST", "/support/sessions", json: body, wake: false, call: call)
    end

    # <tt>GET /support/sessions</tt>: the sessions, newest first (open ones, or +state: :all+).
    def support_sessions(state: nil, limit: nil, call: {})
      account_only("support_sessions")
      raise UsageError.new("state is :open or :all", kind: "usage") unless state.nil? || %w[open all].include?(state.to_s)

      r = json_call("GET", "/support/sessions", query: { "state" => state&.to_s, "limit" => int_or_nil(limit, "limit") },
                                                wake: false, call: call)
      list_field(r, "sessions", "GET /support/sessions")
    end

    # <tt>GET /support/sessions/{session_id}</tt>: one session.
    def support_session(session_id, call: {})
      account_only("support_session")
      id = session_id.to_s
      raise UsageError.new("not a support session id: #{session_id.inspect}", kind: "usage") unless id.match?(/\Ass_[0-9a-f]{16}\z/)

      json_call("GET", "/support/sessions/#{id}", wake: false, call: call)
    end

    private

    # The desk-served transports answer these 404 +no_such_route+; say so before asking.
    def account_only(what)
      return if name == "api"

      raise UsageError.new("#{what} is the hosted API's; the #{name} transport (served by the desk) does not serve it",
                           kind: "usage", argv: [what])
    end

    def int_or_nil(value, what)
      return nil if value.nil?
      return value.to_i if value.is_a?(Time)
      raise UsageError.new("#{what} is an Integer", kind: "usage") unless value.is_a?(Integer)

      value
    end

    def ms_or_nil(value, what)
      value.is_a?(Time) ? (value.to_r * 1000).to_i : int_or_nil(value, what)
    end

    def list_field(result, key, op)
      return result[key] if result.is_a?(Hash) && result[key].is_a?(Array)

      raise ProtocolError.new("the GaiaDesk API answered #{op} without {#{key.inspect}: [...]}", kind: "protocol", argv: [op], json: result)
    end
  end
end
