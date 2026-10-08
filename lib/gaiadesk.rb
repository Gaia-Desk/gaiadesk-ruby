# frozen_string_literal: true

require_relative "gaiadesk/version"
require_relative "gaiadesk/errors"
require_relative "gaiadesk/args"
require_relative "gaiadesk/e2e/crypto"
require_relative "gaiadesk/e2e/session"
require_relative "gaiadesk/http"
require_relative "gaiadesk/stream"
require_relative "gaiadesk/transport/desk_ops"
require_relative "gaiadesk/transport/account"
require_relative "gaiadesk/transport"
require_relative "gaiadesk/local"
require_relative "gaiadesk/client"
require_relative "gaiadesk/webhook"

# The GaiaDesk SDK for Ruby: drive GaiaDesk desks through GaiaDesk's HTTP API
# (hosted, the desk's own local API, or its LAN gateway). Start with {GaiaDesk::Client}.
module GaiaDesk
  # A client: <tt>GaiaDesk.new(...)</tt> is <tt>GaiaDesk::Client.new(...)</tt>.
  # @return [Client]
  def self.new(**options)
    Client.new(**options)
  end
end
