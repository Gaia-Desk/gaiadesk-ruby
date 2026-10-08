# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "gaiadesk"
require "minitest/autorun"
require "json"
require "tmpdir"
require "stringio"
require_relative "support/mock_api"

module TestHelpers
  VECTORS = JSON.parse(File.read(File.expand_path("fixtures/e2e_vectors.json", __dir__)))

  def hex(str)
    [str].pack("H*")
  end

  # A client on the mock API, quiet about plaintext warnings unless asked.
  def client(api, **opts)
    warnings = opts.delete(:warnings) || []
    GaiaDesk::Client.new(api_key: opts.delete(:api_key) || "sess_person", base_url: api.url, retry_base: 0.01,
                         on_warning: ->(m) { warnings << m }, **opts)
  end
end

Minitest::Test.include(TestHelpers)
