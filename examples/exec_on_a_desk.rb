# frozen_string_literal: true

# Run a command on a desk, then stream another's output as it is produced.
#
#   GAIADESK_API_KEY=ak_… GAIADESK_DESK_TOKEN=gdagt_… ruby examples/exec_on_a_desk.rb 123456789

require "gaiadesk"

desk = ARGV.fetch(0) { abort "usage: ruby examples/exec_on_a_desk.rb <desk id>" }
gd = GaiaDesk.new # $GAIADESK_API_KEY and $GAIADESK_DESK_TOKEN

begin
  r = gd.exec(desk, "uname -a", timeout: "30s")
  puts "exit #{r['exit']}: #{r['stdout']}"

  # Streamed: each chunk as it arrives; the result is the exit event.
  s = gd.exec_stream(desk, %w[ls -la], cwd: "/tmp") { |chunk| print chunk.text }
  puts "-- exited #{s.result['exit']}"

  # A non-zero exit is a result, unless check: true.
  gd.exec(desk, "false", check: true)
rescue GaiaDesk::CommandError => e
  puts "the command failed: exit #{e.result['exit']}"
rescue GaiaDesk::UnreachableError => e
  warn "desk #{desk} is not reachable (#{e.reason}): #{e.message}"
rescue GaiaDesk::RefusedError => e
  warn "refused (#{e.reason}); request #{e.request_id}"
end
