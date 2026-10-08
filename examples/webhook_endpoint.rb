# frozen_string_literal: true

# A Rack endpoint for GaiaDesk webhooks: verify each delivery, then act on it.
#
#   GAIADESK_WEBHOOK_SECRET=whsec_… rackup examples/webhook_endpoint.rb  (with `run WebhookEndpoint` in config.ru)

require "gaiadesk"

# Answers 2xx once a delivery is verified (GaiaDesk retries anything else).
class WebhookEndpoint
  def self.call(env)
    body = env["rack.input"].read
    event = GaiaDesk::Webhook.construct_event(body, env["HTTP_GAIADESK_SIGNATURE"], ENV.fetch("GAIADESK_WEBHOOK_SECRET"))
    case event["type"]
    when "desk.offline" then warn "desk #{event['data']['desk']['desk_id']} went offline: #{event['data']['desk']['reason_text']}"
    when "job.finished" then warn "job #{event['data']['job']['name']} finished"
    end
    [200, {}, ["ok"]]
  rescue GaiaDesk::Webhook::SignatureError
    [400, {}, ["bad signature"]]
  end
end
