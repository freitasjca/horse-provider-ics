# ICS TLS / mutual-TLS integration test

Proves the OverbyteICS provider serves **HTTPS** and enforces **mutual TLS**.
ICS's modern OpenSSL 3.x/4.x stack is the provider's distinctive value, so this
is its most important test.

| File | Role |
|---|---|
| `HorseICSTLSTestServer.dpr` | HTTPS server on **port 9111**; `GET /ping`, `POST /echo` |
| `HorseICSTLSTestClient.dpr` | Driver; exit code = number of failed assertions |
| `certs/` | Self-signed fixture PKI (shared with the other providers) |

**Delphi only** (ICS is Delphi-only — Windows + POSIX/Linux64). Needs the ICS
`Source/` path and the OpenSSL libraries that ship with ICS.

## Certificates (`certs/`)

Generated once by `certs/gen-certs.sh` (OpenSSL) and committed:

```
ca.crt / ca.key          test CA
server.crt / server.key  server cert — CN/SAN = localhost, 127.0.0.1, ::1
client.crt / client.key  client cert — for mutual TLS
```

**Test-only throwaway keys.** Copy `certs/` next to the built binaries (or run
from this `tests/` folder); both programs locate it via `FindCertDir`.

## Build

```
build-tls-dcc.bat            # Release (default); or: build-tls-dcc.bat Debug
```

Builds both programs into `bin\`, copies `certs\`, and copies ICS's OpenSSL DLLs
(found under `icsv97\ICS-OpenSSL\`) beside them. **With ICS's default settings those
copies are not what runs:** ICS links OpenSSL 4.0 into the `.exe` and loads it from
`C:\ProgramData\ICS-OpenSSL\<version>\` (see the README, *Which OpenSSL your server
loads*). Every pass prints the OpenSSL actually loaded. Override the ICS location with
`set "ICS_ROOT=<path to icsv97>"`; it defaults to the sibling checkout layout.
Win64 only, run from this `tests\` folder.

This pair has **no `.dproj`**, and msbuild is not a substitute on this toolchain —
MSBuild's DCC task emits the IDE's whole global Library Path four times against a
32000-character ceiling and dies on MSB6002/MSB6003. The script drives `dcc64`
directly. The two programs need different unit paths and are built separately:
the **server** is Horse + the ICS provider + ICS itself, the **client** is the
shared `TCrossHttpClient` HTTPS driver from Delphi-Cross-Socket.

> Until 2026-09-24 there was no build script and no `.dproj`, so this suite had
> never been run since it was written — the provider source said as much
> (*"SSL is not exercised by the current test suite"*). Its first run found
> FIX-ICS-MTLS-1 below.

## Run

```
run-tls-tests.bat
```

All four passes, unattended: one-way TLS, mutual TLS, minimum TLS version, and TLS 1.3 cipher suites. Passes 3 and 4 use `openssl s_client` as the peer and need `openssl.exe` on `PATH`; without it, those passes are VOID, never a pass. Exit **0** = all passed, **N** = N failed assertions,
**2** = VOID (the suite did not run — port already held, or the server never
bound). It refuses to start when port 9111 is occupied, because Windows lets a
second process bind an already-owned port without error and the client would
then be testing someone else's server. Server output goes to `bin\tls-oneway.log`
and `bin\tls-mtls.log`.

**Rebuild before believing a green run.** The sibling CrossSocket suite reported
ALL PASSED from three-week-old binaries; a stale `.exe` passes exactly as
convincingly as a current one. Watch the compiler's byte count change.

### By hand

**One-way TLS:**

```
HorseICSTLSTestServer           # terminal 1
HorseICSTLSTestClient           # terminal 2  → T1, T2 pass
```

**Mutual TLS** — pass `mtls` to **both**:

```
HorseICSTLSTestServer mtls      # terminal 1
HorseICSTLSTestClient mtls       # terminal 2  → T3, T4 pass
```

## What each assertion proves

| Mode | Check | Proves |
|---|---|---|
| one-way | T1 `GET /ping` → 200 "pong" | TLS handshake + HTTPS round-trip (TSslHttpServer) |
| one-way | T2 `POST /echo` → body echoed | request body survives the TLS path |
| one-way | T5a `PUT /nobody`, empty body, `Content-Length: 0` → 200 | an empty PUT over TLS reaches the handler |
| one-way | T5r raw `GET /ping` with `Connection: close` (`openssl s_client`, from `run-tls-tests.bat`) → `pong` | **control**: the raw sender delivers requests at all |
| one-way | T5b raw `PUT /nobody` with **no** `Content-Length` → `put-ok` | the lenient `THorseICSConnection` is installed on the **TLS** server (FIX-ICS-SSLCONN-1) |
| one-way | T5c raw `PUT /nobody`, `Content-Length: 0`, `Connection: close` → `put-ok` | an empty-body request asking to close still gets its reply (FIX-ICS-CONNCLOSE-1) |
| one-way | T6 `GET /openssl` → `OpenSSL <version> from <path>` | `THorseProviderICS.OpenSslRuntime` reports the OpenSSL that `Listen` loaded (ICS-OSSLRUNTIME-1) |
| mTLS | T3 `GET /ping` **with** client cert → 200 | `SslVerifyPeer` accepts a CA-signed client cert |
| mTLS | T4 `GET /ping` **without** client cert → rejected | `SSL_VERIFY_PEER \| FAIL_IF_NO_PEER_CERT` enforced — **true only since FIX-ICS-MTLS-1** |
| min version | M0 default server, `s_client -tls1_2` → served | **control**: the client M2 expects refused can connect at all |
| min version | M1 `minver13`, `s_client -tls1_3` → served | `icsSslTLS13` still serves TLS 1.3 |
| min version | M2 `minver13`, `s_client -tls1_2` → **refused** | `icsSslTLS13` is enforced — **true only since FIX-ICS-MINVER-1** (before it, ICS ignored the setting) |
| min version | M3 `minver12`, `s_client -tls1_2` → served | `icsSslTLS12` serves TLS 1.2 |
| min version | M4 `minver12`, `s_client -tls1_3` → served | `icsSslTLS12` is a **minimum**, not a pin |
| TLS 1.3 suites | C0 default server, `s_client -tls1_3 -ciphersuites TLS_AES_128_GCM_SHA256` → served | **control**: the client C2 expects refused can connect at all |
| TLS 1.3 suites | C1 `suites13` (CHACHA20 only), CHACHA20 client → served, `Cipher is TLS_CHACHA20_POLY1305_SHA256` | the configured suite is negotiated |
| TLS 1.3 suites | C2 `suites13`, AES-128-GCM client → **refused** | `SSLCipherSuitesTLS13` restricts TLS 1.3 (v1.0.10) |
| TLS 1.3 suites | C3 `suites13`, `s_client -tls1_2` → served | the TLS 1.3 setting leaves TLS 1.2 alone |
| TLS 1.3 suites | C4 `suites13typo` (`…SHA348` beside a valid name) → server **does not start**, log names `TLS_AES_256_GCM_SHA348` | the read-back catches OpenSSL's silent drop |
| TLS 1.3 suites | C5 `suites13bad` (no valid name) → server **does not start** | an all-invalid list is refused too |

> **T4 is the assertion that matters, and it failed the first time it ran
> (2026-09-24).** The provider set ICS's `SslVerifyPeer` and nothing else, which
> maps to OpenSSL's `SSL_VERIFY_PEER` alone: the server *requests* a client
> certificate and then serves any client that declines to send one. T4 returned
> **200**. So mutual TLS was configurable, documented — this very row asserted
> `FAIL_IF_NO_PEER_CERT` — and never enforced.
>
> The fix adds `SslVerifyPeerModes := [SslVerifyMode_PEER,
> SslVerifyMode_FAIL_IF_NO_PEER_CERT, SslVerifyMode_CLIENT_ONCE]`, which is
> ICS's own server-side spelling (see `OverbyteIcsWSocketS.pas`).
>
> Note what the other three assertions were worth here: T1, T2 and T3 all passed
> against the broken build. A server that accepts everyone still completes
> handshakes and still honours a valid certificate. **Only the negative case
> could detect this**, which is why it is worth keeping even though "not 200" is
> a weak assertion on its own.

> **T5c - FIX-ICS-CONNCLOSE-1, found by T5b on 2026-10-09.** The raw requests all carry
> `Connection: close`, and both PUTs got **no response at all**, while T5r's GET was
> answered and the client's keep-alive T5a passed. ICS's `ProcessPostPutPat` ends with
> `else if FKeepAlive = FALSE then CloseDelayed`, and the provider's `hgWillSendMySelf`
> (answer later, from a worker) lands in that branch: with `Connection: close` the
> socket was closed before the answer existed. It needs an empty body (with a body the
> provider dispatches later, from `OnPostedData`) and is not TLS-specific: curl against
> the plain-HTTP server gave `000` for an empty PUT with `Connection: close` and `200`
> with keep-alive. Fixed by overriding `ProcessPostPutPat` in `THorseICSConnection`.
>
> **T5 lost its detector on 2026-10-08, and T5b replaces it.** Delphi-Cross-Socket
> 1.0.16 (winddriver #208) makes `TCrossHttpClient` send `Content-Length: 0` for an
> empty POST/PUT/PATCH, so the client's PUT stopped reaching ICS's reject path. It
> still passed, testing nothing, in the 2026-10-08 run. T5b sends the
> no-`Content-Length` request raw through `openssl s_client`, which no client library
> can change. The text below describes the original T5, which is T5b now.
>
> **T5 (FIX-ICS-SSLCONN-1).** `ClientClass := THorseICSConnection` was assigned
> only on the plain-HTTP branch, so over TLS the provider ran ICS's stock
> connection and lost two behaviours at once. `TCrossHttpClient` omits
> `Content-Length` entirely for an empty body, so a body-less PUT reaches ICS's
> reject path and answers 400 before the handler — that is what T5 detects, and
> it was verified by running the test against the unfixed provider (400, ICS's
> own error page) and then against the fixed one (`put-ok`), with nothing else
> changed.
>
> The second lost behaviour has no direct test and is the more serious of the
> two: `ExecutePending` guards the async marshal-back with
> `Conn is THorseICSConnection`, which was **always False over TLS**, leaving
> keep-alive enabled on exactly the path that needs it off — ICS can begin
> reading the next request before the deferred answer is written, desyncing
> request/response pairing on a reused HTTPS connection. A direct test would be
> timing-dependent and would pass intermittently while broken, which is worse
> than none; T5 shares its single root cause and stands as the proxy.
>
> The comment that had justified leaving this alone claimed the SSL server needs
> a `TSslHttpConnection`-derived class. **No such type exists in ICS.**
> `OverbyteIcsHttpSrv` declares `TBaseHttpConnection` conditionally — as
> `TSslWSocketClient` in an SSL build, `TWSocketClient` otherwise — so the one
> `THttpConnection` is already SSL-capable and `TSslHttpServer` inherits
> `ClientClass` like any other `THttpServer`.

## Provider config exercised

`THorseICSConfig`: `SSLEnabled`, `SSLCertFile`, `SSLPrivKeyFile`, `SSLCAFile`,
`SSLVerifyPeer`, `SSLVersionMethod` (→ `SslMinVersion` since v1.0.9; the server's `minver12`/`minver13` arguments), `SSLCipherSuitesTLS13` (→ `SslCipherList13` since v1.0.10; `suites13`/`suites13typo`/`suites13bad`) — passed via
`THorseProviderICS.ListenWithConfig(9111, Config)`, wired onto ICS's
`TSslContext` (`SslCertFile` / `SslPrivKeyFile` / `SslCAFile` / `SslVerifyPeer`
/ `SslVerifyPeerModes`).

> The `POST /echo` body is sent with `Content-Length` (not chunked) because ICS
> rejects a request body without `Content-Length` before the handler runs.
