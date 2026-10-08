# frozen_string_literal: true

# Upload a file, read it back, and download it (end-to-end encrypted when the desk publishes a key).
#
#   GAIADESK_API_KEY=ak_… GAIADESK_DESK_TOKEN=gdagt_… ruby examples/copy_a_file.rb 123456789 report.csv

require "gaiadesk"

desk, local = ARGV
abort "usage: ruby examples/copy_a_file.rb <desk id> <file>" unless desk && local

gd = GaiaDesk.new(e2e: :require) # never in the clear
up = gd.upload(local, desk, "/tmp/")
puts "uploaded #{up['bytes']} bytes to #{up['destination']}"

bytes = gd.download_bytes(desk, up["destination"])
puts "read back #{bytes.bytesize} bytes"

File.open("#{local}.copy", "wb") { |f| gd.download(desk, up["destination"], f) }
puts "downloaded to #{local}.copy"
