# frozen_string_literal: true

# Start a background job, follow its output, then wait for it.
#
#   GAIADESK_API_KEY=ak_… GAIADESK_DESK_TOKEN=gdagt_… ruby examples/run_a_job.rb 123456789

require "gaiadesk"

desk = ARGV.fetch(0) { abort "usage: ruby examples/run_a_job.rb <desk id>" }
gd = GaiaDesk.new(wake: 60) # ring a sleeping desk and wait up to a minute

job = gd.run_job(desk, "nightly", "./build.sh --release", shell: "bash", env: { "CI" => "1" }, cpu: 50, keep_awake: true)
puts "started #{job['name']} (#{job['state']})"

stream = gd.follow_job_logs(desk, "nightly") { |chunk| print chunk.text }
puts "-- #{stream.wait.message}"

r = gd.wait_job(desk, "nightly", timeout: "2h")
if r["timed_out"]
  puts "still running after two hours; stopping it"
  gd.kill_job(desk, "nightly")
else
  puts "exit code #{r['job']['exit_code']}"
end
