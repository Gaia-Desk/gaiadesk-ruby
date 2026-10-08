# Changelog

All notable changes to the `gaiadesk` gem. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [0.1.1] - 2026-10-08

Never hang on a dropped or stalled connection.

### Added

- `response_timeout:` (default 16 minutes, above the API's 15-minute call limit)
  bounds the wait for an answer to begin, sending the request included; exceeded,
  an `UnreachableError`, kind `timeout`, never retried. `idle_timeout:` (default
  90 s; streams and held waits keep alive every 15 s) bounds every read of a body:
  JSON, error bodies, downloads (plain and sealed) and event streams; exceeded, a
  `ConnectionLostError`, kind `timeout` (a stream ends with exit 255, error kind
  `connection_lost`, reason `timeout`). Both on every transport (`:api`, `:local`,
  `:lan`, the Windows named pipe included); `nil` is no limit.

### Fixed

- A server or proxy that stopped answering (a half-open socket, a stall mid-body,
  mid-JSON or mid-stream, or no answer at all) hung the call forever: reads had no
  limit by default.
- Net::HTTP silently sent a GET, PUT or DELETE a second time after a network error
  (its own `max_retries`, default 1): an upload could reach the desk twice, a
  streamed upload's second try sent no body and hung, and a timeout took twice as
  long. It is now off; only the SDK's documented retries apply.
- A stream ended by a transport error reports one of the six error kinds
  (`connection_lost`, `unreachable`, ...).
- `download` to a path writes a temporary file beside it and renames it once
  whole: a failed download leaves no partial file.
- `download_stream` no longer yields an empty first piece on Ruby 3.1.

### Changed

- One retry policy, the same in every GaiaDesk SDK (the README's "Retries"):
  - A 503 to a GET is now retried without needing `Retry-After`, unless its
    reason is permanent (`api_disabled`, `desk_ops_disabled`, `local_api_off`).
  - Every 429 is now retried for any method (before: only with `Retry-After` or
    a `rate_limited` / `desk_busy` reason). Only 429 and 503 wait for
    `Retry-After`; a 502 or 504 now backs off whatever it says.
  - A connect that times out (`open_timeout`) is now an `UnreachableError`, kind
    `timeout`, and no longer retried (before: kind `network`, retried); a TLS
    certificate that fails verification is not retried either.
  - Backoff: `retry_base:` now defaults to 0.25 s (was 0.5 s), doubling up to the
    new `retry_max_delay:` (8 s, was fixed), times a random 0.5–1.0.
    `max_retry_wait:` stays 60 s, `retries:` 2 (3 attempts).
  - `retry_base:`, `retry_max_delay:` and `max_retry_wait:` are validated (a
    negative, NaN or infinite value is a `UsageError`).

### Removed

- The client's `timeout:` option (0.1.0's one per-read limit, no limit by
  default): `response_timeout:` and `idle_timeout:` replace it. The per-call
  `timeout:` of `exec`, `exec_stream` and `wait_job` is unchanged.

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
