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
(found under `icsv97\ICS-OpenSSL\`) beside them. Override the ICS location with
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

Both passes, unattended. Exit **0** = all passed, **N** = N failed assertions,
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
| one-way | T5 `PUT /nobody` with **no** `Content-Length` → 200 | the lenient `THorseICSConnection` is installed on the **TLS** server (FIX-ICS-SSLCONN-1) |
| mTLS | T3 `GET /ping` **with** client cert → 200 | `SslVerifyPeer` accepts a CA-signed client cert |
| mTLS | T4 `GET /ping` **without** client cert → rejected | `SSL_VERIFY_PEER \| FAIL_IF_NO_PEER_CERT` enforced — **true only since FIX-ICS-MTLS-1** |

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
`SSLVerifyPeer`, `SSLVersionMethod` — passed via
`THorseProviderICS.ListenWithConfig(9111, Config)`, wired onto ICS's
`TSslContext` (`SslCertFile` / `SslPrivKeyFile` / `SslCAFile` / `SslVerifyPeer`
/ `SslVerifyPeerModes`).

> The `POST /echo` body is sent with `Content-Length` (not chunked) because ICS
> rejects a request body without `Content-Length` before the handler runs.
