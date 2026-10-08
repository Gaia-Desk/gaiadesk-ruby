# frozen_string_literal: true

require_relative "lib/gaiadesk/version"

Gem::Specification.new do |spec|
  spec.name = "gaiadesk"
  spec.version = GaiaDesk::VERSION
  spec.authors = ["GaiaDesk"]
  spec.email = ["noreply@gaiadesk.net"]

  spec.summary = "Drive GaiaDesk desks from Ruby through the GaiaDesk API: commands, streams, files, jobs, tokens, webhooks."
  spec.description = <<~DESC
    The official Ruby SDK for GaiaDesk's Platform API: list desks and their reachability, wake them, run commands
    (with streaming output), copy files, run and follow background jobs, read stats, mint and revoke scoped agent
    tokens, read the audit trail, manage webhooks and support sessions. Desk operations are end-to-end encrypted
    (X25519, HKDF-SHA256, XChaCha20-Poly1305) with Ruby's own OpenSSL. Also talks to a desk's own local API (Unix
    socket or named pipe) and its LAN gateway (pinned TLS). No runtime dependencies.
  DESC
  spec.homepage = "https://github.com/Gaia-Desk/gaiadesk-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://www.rubydoc.info/gems/gaiadesk",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE"]
  spec.require_paths = ["lib"]
end
