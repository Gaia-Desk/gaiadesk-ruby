# Changelog

All notable changes to the `gaiadesk` gem. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-10-08

First release: the GaiaDesk Platform API (`/v1`) from Ruby.

### Added

- `GaiaDesk::Client` over three transports with the same methods, results and
  errors: `:api` (the hosted API, `https://api.gaiadesk.net/v1`), `:local` (a
  desk's own API over its Unix socket or Windows named pipe) and `:lan` (a desk's
  LAN gateway over TLS with a pinned certificate fingerprint).
- Fleet routes: `devices`, `desk`, `reach`, `wake`, `audit` (and the paging
  `each_audit_event`), `webhooks` / `create_webhook` / `delete_webhook`, and
  support sessions (`create_support_session`, `support_sessions`, `support_session`).
- Desk operations: `exec` (with `stdin`, `shell`, `env`, `cwd`, `timeout`, `check`
  and `admin: true` for administrator commands), `exec_stream` (a threaded,
  Enumerable `Stream` of chunks, block form, `kill`), `run_job`, `jobs`,
  `wait_job` (held waits, waits longer than one request), `kill_job`, `job_logs`,
  `follow_job_logs`, `stats`, `upload` / `upload_bytes` (paths, IOs, bytes),
  `download` / `download_bytes` / `download_stream`, `create_token`,
  `list_tokens`, `revoke_token` (including the `admin` scope, never implied).
- End-to-end encryption of every desk operation on the `:api` transport
  (X25519, HKDF-SHA256, XChaCha20-Poly1305) with Ruby's own OpenSSL, no extra
  gem: `e2e: :auto | :require | :off`, pinned keys (`e2e_keys`), the
  `e2e_required` resend and the rotated-key retry. Passes GaiaDesk's shared test
  vectors byte for byte, and the XChaCha20 draft's own vectors.
- Typed errors (`UsageError`, `RefusedError`, `UnreachableError`,
  `ConnectionLostError`, `OperationFailedError`, `ProtocolError`,
  `EndToEndError`, `CommandError`, `FingerprintMismatchError`) with `kind`,
  `reason`, `status`, `request_id`, `retry_after`, `exit_code`; the admin
  refusals (`admin_scope_missing`, `admin_not_enabled`, `admin_denied`,
  `admin_unavailable`) via `Error#admin_refusal?`.
- Retries with backoff where they are safe (nothing connected; 429 / busy with
  `Retry-After`; 502 / 504 and lost connections for GETs), per-call
  `desk_token:`, `wake:` and `idempotency_key:`, read and connect timeouts.
- `GaiaDesk::Webhook.verify` / `construct_event` for signed webhook deliveries.
