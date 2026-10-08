# frozen_string_literal: true

# The same operations, served by a desk itself: its local API (code running on the desk)
# and its LAN gateway (another machine on its network, the certificate pinned).

require "gaiadesk"

here = GaiaDesk.new(transport: :local) # the socket or pipe, and the local admin token, are found
me = here.devices["devices"].first
puts "this desk is #{me['desk_id']}"
puts here.stats(me["desk_id"])["hostname"]

if ENV["GAIADESK_LAN_URL"]
  lan = GaiaDesk.new(transport: :lan, base_url: ENV["GAIADESK_LAN_URL"], # https://gaiadesk-123456789.local:7443/v1
                     fingerprint: ENV.fetch("GAIADESK_LAN_FINGERPRINT"), # Settings → GaiaDesk API shows it
                     desk_token: ENV.fetch("GAIADESK_DESK_TOKEN"))
  puts lan.exec(me["desk_id"], "hostname")["stdout"]
end
