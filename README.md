# GaiaDesk SDK for Ruby

Drive your GaiaDesk machines ("desks") from Ruby through the GaiaDesk API:
list them and check that they are reachable, wake them, run commands and get
exit codes back, stream output, copy files, run and follow background jobs,
read stats, mint and revoke scoped agent tokens, read the audit trail, and
manage webhooks and support sessions.

- Gem: `gaiadesk` (Ruby 3.1+), module `GaiaDesk`
- Runtime dependencies: **none**. HTTP is `Net::HTTP`; the
  [end-to-end encryption](#end-to-end-encryption) is Ruby's own OpenSSL.
- Three transports, one API: the hosted API (`https://api.gaiadesk.net/v1`),
  a desk's own **local** API (its Unix socket or Windows named pipe), and its
  **LAN** gateway (TLS with a pinned certificate). See [Transports](#transports).

Results are the objects `gaiadesk-cli --json` prints and the API's contract
describes (`api/openapi.yaml`, which references the CLI's JSON schema), as
Ruby Hashes with String keys: `r["exit"]`, `r["stdout"]`, `job["state"]`.
Failures are one family of typed errors with the API's `kind` and `reason`.

Other GaiaDesk developer tools: the
[TypeScript SDK](https://github.com/Gaia-Desk/gaiadesk-typescript) (`@gaiadesk/sdk`),
the [Python SDK](https://github.com/Gaia-Desk/gaiadesk-python) (`gaiadesk`), and the
[MCP server](https://github.com/Gaia-Desk/gaiadesk-mcp) for AI assistants.

MIT-licensed. GaiaDesk itself is proprietary and not covered by this license.

---

## Contents

- [Install](#install)
- [Quick start](#quick-start)
- [Credentials](#credentials)
- [Desks](#desks)
- [Commands](#commands)
- [Streaming output](#streaming-output)
- [Running as administrator](#running-as-administrator)
- [Background jobs](#background-jobs)
- [Files](#files)
- [Agent tokens](#agent-tokens)
- [Audit](#audit)
- [Webhooks](#webhooks)
- [Support sessions](#support-sessions)
- [End-to-end encryption](#end-to-end-encryption)
- [Transports](#transports)
- [Errors](#errors)
- [Retries, timeouts and idempotency](#retries-timeouts-and-idempotency)
- [API reference](#api-reference)
- [Examples](#examples)
- [Not covered](#not-covered)
- [Development](#development)

---

## Install

```sh
gem install gaiadesk
```

or in a Gemfile:

```ruby
gem "gaiadesk", "~> 0.1"
```

## Quick start

```ruby
require "gaiadesk"

gd = GaiaDesk.new(
  api_key: ENV["GAIADESK_API_KEY"],         # an API key (ak_…), or a signed-in person's session token
  desk_token: ENV["GAIADESK_DESK_TOKEN"],   # a scoped agent token (gdagt_…), verified by the desk
)

gd.devices["devices"].each { |d| puts "#{d["desk_id"]} #{d["name"]} #{d["online"] ? "online" : "offline"}" }

r = gd.exec("123456789", "uname -a")
puts r["exit"], r["stdout"]

gd.exec_stream("123456789", %w[make test], cwd: "src/app") { |chunk| print chunk.text }
```

`GaiaDesk.new(...)` is `GaiaDesk::Client.new(...)`. Without arguments it
reads `$GAIADESK_API_KEY` and `$GAIADESK_DESK_TOKEN`.

## Credentials

Every request carries `Authorization: Bearer <api_key>` and, when set,
`X-GaiaDesk-Desk-Token: <desk_token>`.

- **API key** (`ak_…`, minted on gaiadesk.net/account → API keys) with exactly
  the scopes it needs: `desks:read`, `desks:write` (wake), `exec`, `files`,
  `jobs`, `tokens`, `audit:read`, `webhooks`, `support`.
- **Desk operations** (exec, jobs, files, stats, tokens) are verified by the
  desk itself. From an API key they need a scoped **agent token** (`gdagt_…`)
  in `desk_token`; its scopes, `cwd` confinement and low-privilege user apply.
  A signed-in person's own session works on their own desks without one.
- **Token administration** (`create_token`, `list_tokens`, `revoke_token`) is
  the desk owner's: a signed-in person's session on their own desk. An agent
  token is refused (`agent_cannot_admin`).

Every desk operation also takes, per call:

| Keyword | Effect |
|---|---|
| `desk_token:` | the agent token for this call instead of the client's |
| `wake:` | if the desk is asleep, ring it and wait up to this many seconds (0-120; the client's `wake:` is the default) |
| `idempotency_key:` | on POSTs (`exec`, `run_job`, `create_token`, `wake`, `create_webhook`, `create_support_session`): a retry with the same key gets the first answer again |

## Desks

```ruby
gd.devices                          # {"devices", "sources", "notes", "identity"}, online desks first
gd.devices(desk_id: "123456789")    # just that one
gd.desk("123456789")                # one desk: online, offline_reason, features, e2e_pub, wake hints
gd.reach("123456789", since: Time.now - 86_400, limit: 50)   # its online/offline history, newest first
gd.wake("123456789", wait: 30)      # ring its doorbell and LAN siblings; {"woke", "online", "rang", ...}
```

An offline desk carries `offline_since`, `offline_reason` (`closed`,
`silent`, `updating`, ...) and `offline_reason_text`. A desk operation on an
offline desk raises `UnreachableError` with that reason.

## Commands

```ruby
r = gd.exec("123456789", "df -h")                             # one command line for the desk's shell
r = gd.exec("123456789", ["git", "log", "-1", "--oneline"])   # an argument vector, quoted for the desk
r = gd.exec("123456789", "Get-ChildItem Env:DEPLOY_ENV",
            shell: :pwsh, env: { "DEPLOY_ENV" => "staging" }, cwd: "C:/app", timeout: "5m")
r = gd.exec("123456789", "wc -l", stdin: File.open("data.csv"))   # stdin: a String or an IO, sent up front

r["exit"]         # what gaiadesk-cli exec exits with: the program's code, 124 timed out, 254 refused, ...
r["remote_code"]  # the program's own code (nil: it never ran)
r["stdout"]; r["stderr"]; r["timed_out"]; r["truncated"]; r["duration_ms"]
```

A non-zero exit is a result; `check: true` raises `GaiaDesk::CommandError`
(its `result` is the whole ExecResult). A command that never ran (refused,
unreachable, ...) raises its typed error. `shell` is `default`, `none`, `sh`,
`bash`, `zsh`, `cmd`, `pwsh` or `powershell` (sent as `pwsh`). `env` values
reach the command only; the desk logs at most the names. One call is capped at
15 minutes and 8 MB of buffered output: stream larger output, and start a job
for longer work.

## Streaming output

```ruby
# Block form: each chunk as it arrives; returns the finished stream.
s = gd.exec_stream("123456789", "make test") { |chunk| print chunk.text }
s.result        # the last event: {"event" => "exit", "exit" => 0, ...} or {"event" => "error", ...}
s.exit_code

# As an object: Enumerable over GaiaDesk::Chunk (stream "stdout"/"stderr", data bytes).
s = gd.exec_stream("123456789", "tail -f /var/log/system.log")
s.each_with_index do |chunk, i|
  print chunk.text
  s.kill if i > 100        # cancel: the request is closed and the desk stops the command
end
s.wait                     # GaiaDesk::Exit(exit_code, message); 130 after kill
s.text.each { |stream, text| ... }   # [stream, text] pairs
s.read_all                 # {"stdout" => "...", "stderr" => "..."}
```

The stream is read on a background thread from Server-Sent Events, so
`kill` (alias `cancel`) works from any thread and `wait(timeout)` takes a
limit. A character split across chunks is whole before it is decoded. A
failure after the stream started (the desk lost) is its last event, `error`,
never an exception from `each`. stdin is given up front (`stdin:`); a stream
cannot be written to.

## Running as administrator

```ruby
r = gd.exec("123456789", "launchctl list", admin: true, desk_token: ENV["GAIADESK_ADMIN_TOKEN"])
```

`admin: true` runs the command as root (macOS, Linux) or SYSTEM (Windows) in
the desk's privileged GaiaDesk process. It needs an agent token whose scopes
include `admin` (never implied) **and** the desk owner's Admin access switch,
which is turned on only at the desk with the computer's administrator
password; by default the person at the desk is asked each time. A refusal
raises `GaiaDesk::RefusedError` (exit 254) whose `admin_refusal?` is true and
whose `reason` is one of `GaiaDesk::ADMIN_REASONS`:

| `reason` | meaning |
|---|---|
| `admin_scope_missing` | the token has no `admin` scope (or it is a person's call) |
| `admin_not_enabled` | Admin access is off on the desk |
| `admin_denied` | the person at the desk said no, nobody answered, or the desk's service does not know the token yet |
| `admin_unavailable` | no privileged process (unattended access off), or a desk too old for the field |

```ruby
begin
  gd.exec(desk, "whoami", admin: true)
rescue GaiaDesk::RefusedError => e
  raise unless e.admin_refusal?
  warn "not as administrator: #{e.reason}"
end
```

Windows Smart App Control / WDAC still refuse unsigned new programs for SYSTEM
(`blocked_by_os_policy`). Background jobs never run as administrator.

## Background jobs

```ruby
job = gd.run_job("123456789", "nightly", "./build.sh --release",
                 shell: :bash, env: { "CI" => "1" }, cwd: "repo",
                 priority: :low, cpu: 50, mem: "4G", keep_awake: true)

gd.jobs("123456789")                              # [{"name", "state", "exit_code", ...}]
gd.job_logs("123456789", "nightly", tail: 4096)   # its output so far (a String)
gd.job_log_result("123456789", "nightly")         # {"job", "output"}

gd.follow_job_logs("123456789", "nightly") { |chunk| print chunk.text }   # until it ends

r = gd.wait_job("123456789", "nightly", timeout: "2h")   # {"job", "timed_out"}
gd.kill_job("123456789", "nightly")                       # stop it and everything it started
```

`wait_job` blocks until the job is no longer running, or `timeout` passes
(`timed_out: true`, the job still running). One request holds at most 870
seconds, so a longer (or no) timeout asks again until the job ends. A long
wait is answered with `GaiaDesk-Held: 1` and keep-alive whitespace; should the
desk fail after that 200 went out, the body is the error envelope, which the
SDK raises as its typed error. A job that exited non-zero is a result
(`r["job"]["exit_code"]`). `follow_job_logs`' `kill` stops following, not the job.

## Files

```ruby
gd.upload("report.csv", "123456789", "/tmp/")             # a remote ending in / keeps the name
gd.upload(io, "123456789", "/tmp/data.bin", size: 1024)   # an IO (size: when it cannot be known)
gd.upload_bytes(JSON.generate(config), "123456789", "/etc/app/config.json")

gd.download("123456789", "/var/log/app.log", "logs/")     # a folder keeps the remote name
File.open("app.log", "wb") { |f| gd.download("123456789", "/var/log/app.log", f) }
bytes = gd.download_bytes("123456789", "/tmp/data.bin")
gd.download_stream("123456789", "/tmp/big.iso") { |piece| digest << piece }   # no file system needed
```

Uploads and downloads stream (nothing is held in memory but a chunk). Each
returns the CopyResult (`bytes`, `destination`, `failed`, ...); a file the desk
could not write raises `OperationFailedError` with the result in `json`. The
API moves files up to 256 MB (larger: `gaiadesk-cli cp`); a larger upload is
refused before anything is sent. A download that breaks mid-way raises (it is
never a clean short file). A folder is `UsageError` with reason `is_folder`.

## Agent tokens

```ruby
owner = GaiaDesk.new(api_key: ENV["GAIADESK_SESSION"])   # a signed-in person's session, on their own desks
r = owner.create_token(%w[123456789 987654321], name: "ci", scopes: %w[exec cp jobs], expires: "30d",
                       cwd: "/srv/builds")               # confine its work to a folder
r["tokens"].each { |t| puts "#{t["desk"]}: #{t["secret"]}" }   # each secret is shown once

owner.list_tokens("123456789")              # never their secrets
owner.revoke_token("123456789", "ci")       # by id or name; its sessions and jobs end
```

`scopes` default to `exec cp jobs`; `admin` is never implied and a confined
token (`cwd`, `low_priv`) cannot carry it. Minting on several desks is one
request per desk; if a later desk fails, the error's `json["tokens"]` holds the
tokens already minted.

## Audit

```ruby
gd.audit(desk: "123456789", action: "api.*", since_ms: Time.now - 3600, limit: 100)

# Every matching event, newest first, a page at a time (lazy without a block).
gd.each_audit_event(action: "api.*", page_size: 500) { |e| puts e["action"] }
gd.each_audit_event(desk: "123456789").first(20)
```

Filters: `desk`, `actor`, `action` (exact, or a prefix ending `.*`), `token`,
`since_ms`, `until_ms` (Integers in milliseconds, or Times), `limit`.

## Webhooks

```ruby
hook = gd.create_webhook(url: "https://example.com/hooks/gaiadesk",
                         events: %w[desk.online desk.offline desk.woke job.finished],
                         description: "ops channel")
hook["secret"]           # whsec_…: keep it, it is shown once
gd.webhooks
gd.delete_webhook(hook["id"])
```

Verify each delivery in your endpoint (HMAC-SHA256 of `"<t>.<raw body>"`,
constant-time compare, five-minute tolerance):

```ruby
event = GaiaDesk::Webhook.construct_event(request.raw_post, request.headers["GaiaDesk-Signature"],
                                          ENV["GAIADESK_WEBHOOK_SECRET"])
# raises GaiaDesk::Webhook::SignatureError when it does not verify
GaiaDesk::Webhook.verify(secret, header, raw_body)   # true / false
```

Delivery is at least once: de-duplicate by `event["id"]` (`GaiaDesk-Event-Id`).

## Support sessions

For the embed SDK's "Get help" button: your backend creates a session, the
page gets the embed token, and your support team joins it from the console.

```ruby
s = gd.create_support_session(mode: :cobrowse, customer: { name: "Ada", plan: "pro" },
                              expires_in: "30m", origin: "https://app.example.com")
s["embed_token"]   # gdemb_… for GaiaDeskEmbed.start({ embedToken }); shown once
s["join_code"]; s["join_url"]

gd.support_sessions                  # open ones, newest first
gd.support_sessions(state: :all, limit: 20)
gd.support_session(s["id"])["state"] # waiting, joined, ended, expired
```

## End-to-end encryption

On the hosted API, desk operations are **sealed** so GaiaDesk's servers relay
only ciphertext: the command, its `env` and `stdin`, file paths and bytes,
job and token specs, and all output and results are readable by the caller and
the desk only. The server still sees the credentials, the route (the
operation, the desk, a job name or token id in the path), `stream` / `follow`
/ `wake_s`, sizes, and how the operation ended. `local` and `lan` never leave
the desk or the LAN and are not sealed.

Before an operation the SDK reads the desk's X25519 key (`e2e_pub` from
`GET /desks/{id}`, cached for five minutes) and seals the request to a fresh
ephemeral key: X25519, HKDF-SHA256, XChaCha20-Poly1305, every message bound to
the desk, the operation and its place in the stream. Results, streams,
errors, held waits and file bytes come back exactly as in the clear; a desk's
error carries its own message.

```ruby
gd = GaiaDesk.new(
  api_key: key, desk_token: token,
  e2e: :require,                                        # :auto (default) | :require | :off
  e2e_keys: { "123456789" => "B6N8vBQgk8i3…" },        # optional: pin a desk's e2e_pub
  on_warning: ->(msg) { logger.warn(msg) },             # default: Kernel#warn
)
```

- `:auto` (default): sealed whenever the desk lists a key; otherwise sent in
  the clear with a one-time warning per desk, unless the desk **requires**
  end-to-end encryption: then it is woken and asked again, and sealed or refused.
- `:require`: never in the clear. A desk that lists no key (asleep, offline,
  too old) is woken and asked again; still none is a
  `GaiaDesk::EndToEndError` (`e2e_unavailable`) and nothing is sent.
- `:off`: plaintext.
- `e2e_keys`: a pinned key is sealed to even while the desk lists none; a
  different key from the server is `EndToEndError` (`e2e_key_mismatch`) and
  nothing is sent.
- A plaintext call refused `e2e_required` (409) is sealed and sent once more;
  a sealed one the desk could not open (`e2e_decrypt_failed`: its key rotated)
  is sealed to the key read again, once. An upload is resent only when its
  source can be rewound (a String, a file; not a pipe).
- Answers that do not open (altered, reordered, a plaintext answer to a sealed
  call) raise `EndToEndError` (`e2e_decrypt_failed`, `e2e_malformed`); in a
  stream, they end it with an `error` event of kind `protocol`.
- Reading a desk's key needs `desks:read` (waking it `desks:write`); in
  `:auto`, a key that cannot be read means plaintext with the warning.

**The crypto.** Everything is Ruby's bundled OpenSSL (Apache-2.0): X25519
(`OpenSSL::PKey`), HKDF (`OpenSSL::KDF.hkdf`) and the IETF
ChaCha20-Poly1305 AEAD. OpenSSL has no XChaCha20-Poly1305, so it is composed
the standard way (draft-irtf-cfrg-xchacha-03): HChaCha20 derived from
OpenSSL's own ChaCha20 block (no cipher rounds are written in Ruby), then
ChaCha20-Poly1305 with that subkey. The test suite checks GaiaDesk's shared
vectors (`test/fixtures/e2e_vectors.json`, the same file the TypeScript and
Python SDKs and the desk's Rust code test against) byte for byte, and the
draft's own HChaCha20 and XChaCha20-Poly1305 vectors. No libsodium or RbNaCl
is needed; `GaiaDesk::E2E.available?` reports whether this Ruby's OpenSSL
(1.1.0 or later) has every primitive.

## Transports

```ruby
gd.backend   # "api", "local" or "lan"
```

**Hosted API** (`transport: :api`, the default): `api_key:`, `desk_token:`,
`base_url:` (default `https://api.gaiadesk.net/v1`), `wake:`, `e2e:`,
`e2e_keys:`, `on_warning:`.

**Local API** (`transport: :local`): code running on a desk talks to its own
GaiaDesk, with no server and no internet involved.

```ruby
here = GaiaDesk.new(transport: :local)   # finds the socket or pipe and the admin token
here.exec(here.devices["devices"].first["desk_id"], "uptime")
```

| | macOS, Linux | Windows |
|---|---|---|
| where | the Unix socket `~/.gaiadesk/api.sock` (`$GAIADESK_API_DIR/api.sock`) | the named pipe `\\.\pipe\gaiadesk-api-<user>` (`$GAIADESK_API_PIPE`) |
| admin token | `~/.gaiadesk/api-token` | `%USERPROFILE%\.gaiadesk\api-token` |

Options: `desk_token:` (an agent token, sent as `X-GaiaDesk-Desk-Token`; its
scopes apply), else the desk's local admin token (`token:`, else the
`api-token` file, read on every request) as Bearer; `socket_path:` (another
socket path or pipe name); `env:` (where to look). With the local API off or
the app not running, calls raise `UnreachableError` with reason
`local_api_unavailable`.

**LAN gateway** (`transport: :lan`): a desk's opt-in gateway, for that desk
and the paired desks it reaches on its LAN.

```ruby
lan = GaiaDesk.new(transport: :lan,
                   base_url: "https://gaiadesk-123456789.local:7443/v1",
                   fingerprint: "ab:cd:…",          # the certificate's SHA-256, from the desk's Settings
                   desk_token: ENV["GAIADESK_DESK_TOKEN"])   # agent tokens only
```

The certificate is self-signed: the SDK pins its SHA-256 fingerprint (with or
without colons, any case) and checks it right after the TLS handshake, before
a request byte is sent. Another certificate raises
`GaiaDesk::FingerprintMismatchError` (reason `fingerprint_mismatch`).

Both serve every desk operation with the same results, errors, streams and
held waits as the hosted API. The fleet routes (`desk`, `reach`, `wake`,
`audit`, webhooks, support sessions) are the hosted API's; on these
transports they raise `UsageError` without a request.

## Errors

Every failure of the API is one envelope, `{"error": {"kind", "message",
"reason"?, "desk"?, "request_id"}}`; the SDK raises it as a typed error:

| Class | `kind` | HTTP | Means |
|---|---|---|---|
| `GaiaDesk::UsageError` | `usage` | 400 | fix the request (also the SDK's own argument checks) |
| `GaiaDesk::RefusedError` | `refused` | 401, 403, 429 | `unauthenticated`, `missing_scope`, `agent_cannot_admin`, `desk_opted_out`, `rate_limited`, `desk_busy`, the admin reasons, ... |
| `GaiaDesk::UnreachableError` | `unreachable` | 404, 409, 503, 504 | `unknown_desk`, offline (`silent`, `closed`, ...), `no_wake_path`; `network` when nothing answered |
| `GaiaDesk::ConnectionLostError` | `connection_lost` | 502 | the desk went away mid-operation |
| `GaiaDesk::OperationFailedError` | `failed` | 422, 500 | it ran and did not succeed (no such job, a file not copied) |
| `GaiaDesk::ProtocolError` | `protocol` | 409, 502 | `desk_too_old`, `e2e_unsupported`, or an answer that is not the documented JSON |
| `GaiaDesk::EndToEndError` | `e2e` | | sealing was impossible or an answer did not open |
| `GaiaDesk::CommandError` | `failed` | | `check: true` and a non-zero exit |
| `GaiaDesk::FingerprintMismatchError` | `unreachable` | | the LAN gateway's certificate is not the pinned one |

All inherit `GaiaDesk::Error < StandardError`, with:

```ruby
rescue GaiaDesk::Error => e
  e.kind          # the envelope's kind, or the finer reason when it is a well-known one (offline, network, timeout, ...)
  e.reason        # the finer cause: "missing_scope", "desk_busy", "admin_denied", ...
  e.desk          # the desk it concerned
  e.status        # the HTTP status
  e.request_id    # req_…: quote it to support
  e.retry_after   # seconds, from a 429's Retry-After
  e.exit_code     # what gaiadesk-cli would have exited with (254 refused, 1 failed, 255 its own error)
  e.json          # the parsed envelope (or result)
  e.admin_refusal?
end
```

## Retries, timeouts and idempotency

```ruby
GaiaDesk.new(api_key: key, retries: 2, retry_base: 0.25, retry_max_delay: 8, max_retry_wait: 60,
             response_timeout: 16 * 60, idle_timeout: 90, open_timeout: 30)
```

**Retries.** A request is sent again only when that cannot run anything twice:

- **The connection was never made** (DNS, refused, TLS handshake): any method — nothing was sent.
- **The connection was lost after sending, or the answer was 502, 503 or 504**: GETs only (reads).
  A 503 that says the API or desk operations are switched off is not retried.
- **429** (`rate_limited`, `desk_busy`) and **409** `idempotency_key_in_flight`: any method — the server refused
  it before acting.

Timeouts are never retried, and nothing is retried once its answer has begun. A call that changes something
(POST, PUT, DELETE) is never sent again after it may have reached the server; an `Idempotency-Key` is sent but
does not make a call retryable. 429 and 503 wait for `Retry-After`; one longer than `max_retry_wait:`
(default 60 s) is not waited for — the error carries it. Otherwise the wait is exponential backoff with jitter:
`retry_base:` (default 250 ms) doubling up to `retry_max_delay:` (default 8 s), times a random 0.5–1.0.
`retries:` (default 2, so 3 attempts in all) sets how many times; 0 turns retries off. Each retry of
a sealed operation is sealed afresh.

Net::HTTP itself re-sends nothing: by itself it would send a GET, HEAD, PUT or DELETE again once after most
network errors (`max_retries`, default 1, even on a fresh connection and with a body it cannot read again), and
the SDK sets `max_retries = 0`. The SDK also opens one connection per request, so no request rides a kept-alive
connection the server has since dropped.

`open_timeout:` (default 30): seconds to connect; exceeded, an `UnreachableError`, kind `timeout` (not retried).

**Timeouts** (seconds, on every transport: `:api`, `:local`, `:lan`) make a
server or proxy that stops answering an error, never a hang:

- `response_timeout` (default 16 minutes, above the API's 15-minute limit on a
  call: a buffered `exec` answers when its command ends): the longest wait for
  an answer to begin, sending the request included. Exceeded: an
  `UnreachableError`, kind `timeout`. Never retried (the request may be running).
- `idle_timeout` (default 90; streams and held waits send a keep-alive every 15
  seconds): the longest silence while reading a body (JSON, a download, an event
  stream), per read, so a large download that keeps flowing never times out.
  Exceeded mid-answer: a `ConnectionLostError`, kind `timeout` (a stream ends
  with exit code 255 and that error, kind `connection_lost`, reason `timeout`,
  in its `result`). A download to a path that fails leaves no partial file.
- `nil` is no limit; zero, negative or non-numeric values are a `UsageError`.
- A connection closed or reset before any answer is an `UnreachableError` (kind
  `network`) at once, retried only as above.


`idempotency_key:` on POSTs: a retry of yours with the same key and the same
request within 24 hours gets the first answer (`Idempotent-Replayed: true`).

## API reference

YARD documents every public method (`bundle exec rake doc`). In brief:

| Method | Route |
|---|---|
| `devices(desk_id:)` | `GET /desks` |
| `desk(id)` | `GET /desks/{id}` |
| `reach(id, since:, limit:)` | `GET /desks/{id}/reach` |
| `wake(id, wait:)` | `POST /desks/{id}/wake` |
| `exec(id, command, ...)` | `POST /desks/{id}/exec` |
| `exec_stream(id, command, ...)` | `POST /desks/{id}/exec?stream=1` (SSE) |
| `run_job(id, name, command, ...)` | `POST /desks/{id}/jobs` |
| `jobs(id)` | `GET /desks/{id}/jobs` |
| `kill_job(id, name)` | `DELETE /desks/{id}/jobs/{name}` |
| `job_logs` / `job_log_result(id, name, tail:)` | `GET /desks/{id}/jobs/{name}/logs` |
| `follow_job_logs(id, name, tail:)` | `GET …/logs?follow=1` (SSE) |
| `wait_job(id, name, timeout:)` | `GET /desks/{id}/jobs/{name}/wait` |
| `stats(id)` | `GET /desks/{id}/stats` |
| `upload` / `upload_bytes` | `PUT /desks/{id}/files?path=` |
| `download` / `download_bytes` / `download_stream` | `GET /desks/{id}/files?path=` |
| `create_token(desks, name:, ...)` | `POST /desks/{id}/tokens` |
| `list_tokens(id)` | `GET /desks/{id}/tokens` |
| `revoke_token(id, token_id)` | `DELETE /desks/{id}/tokens/{token_id}` |
| `audit(...)` / `each_audit_event(...)` | `GET /audit` |
| `webhooks` / `create_webhook` / `delete_webhook` | `GET` / `POST /webhooks`, `DELETE /webhooks/{id}` |
| `create_support_session` / `support_sessions` / `support_session` | `POST` / `GET /support/sessions`, `GET /support/sessions/{id}` |

## Examples

In [`examples/`](examples): running a command and streaming another
(`exec_on_a_desk.rb`), a job followed and waited for (`run_a_job.rb`), copying
a file end-to-end encrypted (`copy_a_file.rb`), a webhook endpoint
(`webhook_endpoint.rb`), and the local and LAN transports (`local_and_lan.rb`).

## Not covered

- **The CLI and native transports** of the TypeScript and Python SDKs (driving
  `gaiadesk-cli` or the native library directly: `shell`, `forward`, `measure`,
  `mcp`, ...). This gem speaks GaiaDesk's HTTP API only; for those, run
  `gaiadesk-cli` yourself.
- **Writing stdin as a command runs**: the API takes stdin up front.
- **Folders**: the API copies single files (up to 256 MB).

## Development

```sh
bundle config set --local path vendor/bundle
bundle install
bundle exec rake test       # unit tests, the shared e2e vectors, and every route against a mock API
bundle exec rubocop
bundle exec rake doc        # YARD
gem build gaiadesk.gemspec
```

The tests run a small HTTP/1.1 mock of the API (`test/support`): every route,
SSE streams written in pieces with keep-alive comments, held waits, broken
transfers, rate limits, and a desk that opens sealed operations with its own
key and seals its answers; the local transport over a real Unix socket and
the LAN transport over TLS with a generated certificate.
