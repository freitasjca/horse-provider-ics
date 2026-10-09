# horse-provider-ics

OverbyteICS transport provider for the [Horse](https://github.com/HashLoad/horse) web framework.

Drop-in alternative to the default Indy transport, selected by a single compiler define:

```pascal
{$DEFINE HORSE_PROVIDER_ICS}
```

Without the define, Horse compiles exactly as before — every other provider (Indy, Console, VCL, CrossSocket, mORMot, Apache, CGI, ISAPI, Daemon) is unaffected.

## Why ICS?

OverbyteICS ships an independent async socket engine with a deeply tested HTTP server stack and **modern OpenSSL 3.x / 4.x TLS** — TLS 1.3, SNI, mTLS, security-level controls. That OpenSSL surface is the provider's distinctive value.

The two existing providers cover different niches:

| Provider | Engine | Notable strength |
|---|---|---|
| `horse-provider-crosssocket` | Delphi-Cross-Socket | IOCP/epoll/kqueue async I/O |
| `horse-provider-mormot` | mORMot2 | three backends (thread-pool, async, http.sys) |
| **`horse-provider-ics`** | OverbyteICS | OpenSSL 3.x / 4.x — TLS 1.3, mTLS |

## Platform scope

- **Delphi only** — Windows (Win32/Win64) **and POSIX (Linux64, macOS)**.
- **Linux/macOS support rides ICS's own POSIX layer** (`Ics.Posix.WinTypes` + `Ics.Posix.PXMessages`): the cross-platform `TIcsWndControl` message loop is a Win32 message queue on Windows and a POSIX message pump on Linux/macOS. The provider's worker-pool marshal-back (`PostMessage` / `TMessage` / `WM_USER` / `AllocateHWnd`) resolves to the POSIX shim with no code change. TLS uses the same OpenSSL 3.x/4.x libraries (`.so` on Linux).
- **Not FPC/Lazarus.** ICS's POSIX support is built on the *Delphi* POSIX RTL (`Posix.*`), and ICS compiles out OpenSSL under FPC entirely — a Lazarus/FPC port remains **not viable with stock ICS** (see *Out of scope / follow-ups* and `plans/ics-lazarus-fpc.md`). The FPC seams (`{$IF DEFINED(FPC)}`) are preserved so the build stays cleanly blocked there.

Selecting `HORSE_PROVIDER_ICS` under FPC triggers a compile-time `FATAL` from `Horse.pas`; on Delphi it is accepted on Windows and POSIX targets.

### Linux daemon

For a Linux service binary, use `HORSE_APPTYPE_DAEMON` and the POSIX runner in `Horse.Provider.ICS.Daemon` (it installs SIGTERM/SIGINT handlers, ignores SIGPIPE, and calls the blocking `THorse.Listen`):

```pascal
uses Horse, Horse.Provider.ICS.Daemon;
procedure SetupRoutes;
begin
  THorse.Get('/ping', GetPing);
end;
begin
  THorseICSLinuxDaemonApp.Run(SetupRoutes, 9000);
end.
```

The same unit exposes a `Vcl.SvcMgr.TService` base class (`THorseICSService`) on Windows — one unit, two shapes, selected by the build target.

## Quick start

```pascal
program HorseICS;

{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_ICS}

uses
  Horse,
  System.JSON;

begin
  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send<TJSONObject>(TJSONObject.Create(TJSONPair.Create('ok', TJSONBool.Create(True))));
    end);
  THorse.Listen(9000);
end.
```

### With TLS

```pascal
var
  Cfg: THorseICSConfig;
begin
  Cfg := THorseICSConfig.Default;
  Cfg.SSLEnabled       := True;
  Cfg.SSLCertFile      := 'server.pem';
  Cfg.SSLPrivKeyFile   := 'server.key';
  Cfg.SSLVersionMethod := icsSslTLS13;     // TLS 1.3 minimum = TLS 1.3 only
  Cfg.SSLCipherSuitesTLS13 :=              // optional; empty = ICS default
    'TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256';

  // Mutual TLS — require + verify client certificates
  Cfg.SSLCAFile        := 'ca.pem';
  Cfg.SSLVerifyPeer    := True;

  THorseProviderICS.ListenWithConfig(9443, Cfg);
end.
```

`SSLVersionMethod` is a **minimum**: `icsSslTLS12` still allows TLS 1.3, and `icsSslTLS13` refuses TLS 1.2 clients. It is enforced, and read back from the OpenSSL context at `Listen`, **since v1.0.9 (FIX-ICS-MINVER-1)**. Before that it was written to an ICS property that ICS ignores, so **no value had any effect**: `icsSslTLS13` served TLS 1.2 clients. Since v1.0.9 the TLS context is also built at `Listen`, so a bad certificate or key fails there, not at the first handshake.

OpenSSL configures cipher choice in **two separate places**, and so does this provider:

| Field | OpenSSL call | Applies to | Syntax |
|---|---|---|---|
| `SSLCipherList` | `SSL_CTX_set_cipher_list` | TLS 1.2 and below **only** | rule string: `ECDHE+AESGCM:!aNULL` |
| `SSLCipherSuitesTLS13` (v1.0.10) | `SSL_CTX_set_ciphersuites` | TLS 1.3 | exact, case-sensitive names: `TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256` |

`SSLCipherList` never restricts TLS 1.3, the protocol most OpenSSL 3.x clients negotiate. Empty leaves ICS's default for either field. OpenSSL **silently drops** a misspelled TLS 1.3 name that sits beside a valid one, so `Listen` reads the effective list back and raises, naming every suite that was dropped, rather than serving on fewer suites than configured.

## Architecture

```
HTTP/HTTPS Request
      ↓
[ICS message-loop thread]
THttpServer.OnGetDocument / OnPostedData
      ↓  Flags := hgWillSendMySelf
TICSRequestBridge.Snapshot  (copy method/path/headers/body into a plain record)
      ↓
THorseICSWorkerPool.Submit
      ↓
[worker thread]
THorseContextPool.Acquire → TICSRequestBridge.Populate → THorse.Execute
      ↓
TICSResponseBridge.Flush  (build status/CT/headers/body)
      ↓  PostMessage(loop, WM_RESPONSE_READY, token)
[ICS message-loop thread]
TICSMarshalReceiver.WndProc
      ↓  liveness check (peer might have dropped)
THttpConnection.AnswerString  (always called on the loop thread)
      ↓
THorseContextPool.Release   (in worker; pool ctx never crosses threads)
```

ICS sockets are single-thread-affine — the entire transport runs on one
window message loop. The provider:

1. **Snapshots** every request on the loop thread (a `TICSRequestSnapshot`
   record). The live `THttpConnection` is never touched off-loop.
2. **Dispatches** the snapshot to an off-loop worker pool (`THorseICSWorkerPool`).
3. **Marshals** the worker's response back to the loop thread via
   `PostMessage` to a hidden window (`TICSMarshalReceiver` — a
   `TIcsWndControl` descendant), where `THttpConnection.AnswerString` runs.

Connection liveness is tracked via `OnClientConnect` / `OnClientDisconnect`
so the marshal-back handler can skip `AnswerString` if the peer dropped
mid-pipeline.

Two ICS-specific bits of server setup matter: `Server.Options` enables
`hoAllowPut`/`hoAllowDelete`/`hoAllowPatch`/`hoAllowOptions` (ICS otherwise won't
dispatch those methods), and a custom connection class (`THorseICSConnection`,
via `THttpServer.ClientClass`) lets body-less PUT/PATCH through ICS's
Content-Length gate and forces `Connection: close` per response. See
`doc/implementation-notes.md` → *ICS server quirks* for the why.

## Hardening

Every check from the mORMot / CrossSocket providers is preserved:

- `[SEC-29]` validate-before-pool
- `[SEC-30]` active-request drain on Stop
- `[SEC-31]` structured JSON 500 (no stack traces leaked)
- `[SEC-32]` double-start guard

## Feature parity (Delphi / Windows)

On its supported target the ICS provider matches the CrossSocket and mORMot
providers feature-for-feature:

| Feature | ICS mechanism |
|---|---|
| Path / query params, headers, body | `TICSRequestBridge.Populate` shadow fields (PATCH-REQ-3/8/9) |
| **RFC 6265 cookies** (`Res.Cookie(...)`, multiple `Set-Cookie`) | `TICSResponseBridge.BuildHeaders` emits one `Set-Cookie` line per cookie (PATCH-COOKIE-1) |
| **`Res.SendFile` / `Download`** (incl. wildcard `Get('/*')` + `FreeAndNil`) | shared `Horse.Response` owns a copy; `WriteBody` drains it synchronously (PATCH-SENDFILE-1) |
| **multipart/form-data** → `Req.ContentFields` (`.AsString` / `.AsStream`) | `PopulateMultipartFields` via ICS's `TFormDataAnalyser` (PATCH-PARAM-1) |
| `application/x-www-form-urlencoded` → `Req.ContentFields` | parsed inline in `Populate` |
| `Req.RawWebRequest` / `Res.RawWebResponse` (Horse.CORS etc.) | hybrid adapters (PATCH-REQ-8 / PATCH-RES-6) |
| **TLS 1.3 + mTLS** | `TSslContext` + `TSslHttpServer` (`THorseICSConfig` SSL fields) |
| **Graceful shutdown drain** (all three steps) | counts-based drain + `MultiClose` to stop accepting (FIX-ICS-GRACEFUL-1/2) — see [Graceful shutdown](#graceful-shutdown) |

Verified by the `tests/` A–K suite (`HorseICSParamTestServer` + `Client`, Delphi,
port 9110) — the same matrix the CrossSocket / mORMot suites run, including
Section I (multipart), Section J (wildcard SendFile) and Section K (cookies).

TLS itself — ICS's distinctive value — has a dedicated test:
`tests/HorseICSTLSTestServer.dpr` + `HorseICSTLSTestClient.dpr` (port 9111) cover
one-way HTTPS and mutual TLS against a self-signed fixture PKI in `tests/certs/`.
Pass `mtls` to both to exercise client-certificate verification. Runbook:
[`tests/TLS-TESTS.md`](tests/TLS-TESTS.md).

## Graceful shutdown

`StopListenGraceful(ATimeoutMS)` stops accepting new connections, waits for requests
already in flight to finish, and **delivers their responses** before tearing the server
down. It is not the same call as `StopListen`, which is abrupt and unchanged.

```pascal
THorse.StopListenGraceful(5000);   // wait up to 5 s for in-flight work
```

Implemented in **provider v1.0.8** (FIX-ICS-GRACEFUL-1 and -2). Measured: 703-720 ms for
700 ms of remaining work.

**This is the only external Horse provider that performs all three steps the framework
asks for** — stop accepting, drain, tear down — and its drain is the most precise of the
three, for a reason specific to ICS.

### The drain waits on counts, not a clock

Three things sit between a finished handler and the socket:

| | |
|---|---|
| `FActiveRequests` | worker tasks still inside the pipeline |
| `FPendingMap` | responses `PostMessage`'d to the receiver, pump has not run yet |
| `FPostBuffers` | responses mid-write, partial sends tracked |

A finished ICS worker has only *posted* its response — the socket write happens on the
**main thread**, when the message pump processes that message. So `FActiveRequests = 0`
does **not** mean the reply is out.

Other transports cover that window with a fixed sleep. Here it is countable, and
`FPendingLock` already guards both dictionaries, so the drain waits on the actual counts
under one shared deadline — your timeout bounds the total rather than being spent twice.
**No settle delay at all.** `HORSE_ICS_SETTLE_MS` exists for characterisation and is not
needed.

### Stopping accepts without dropping live clients

`THttpServer.Stop` is two separable calls: `FWSocketServer.MultiClose` closes the
**listeners**, `DisconnectAll` drops the **clients**. Using `MultiClose` alone halts new
connections while established clients keep their sockets.

This is ICS's own idiom, not an invention — `THttpServer.SetPortValue` does exactly this
to rebind a port, under the comment *"Do not disconnect already connected clients."* It
was measured rather than assumed, because the equivalent step on Delphi-Cross-Socket
destroys the in-flight response body. Elapsed did not move, so it costs nothing.

### What was wrong before v1.0.8

The provider had no override, so it inherited Horse's abstract base, which **discards the
timeout**. `Stop` also had the ordering inverted — `FServer.Stop` and
`Terminated := True` first, drain wait after — which on ICS is doubly costly, because
`Terminated` ends `FServer.MessageLoop` and that loop is how ICS writes anything at all.
Teardown already waited for the handler, but the client lost its reply the instant
shutdown began.

`Stop`'s teardown tail is now factored into a shared `StopTeardown`, so the graceful and
abrupt paths cannot drift apart.

> **Requires Horse >= 3.3.10.** On earlier releases `THorseInstance.StopListenGraceful`
> called its own `StopListen` and bypassed every provider override, so this works only
> when called directly on `THorseProviderICS` — through `THorse` it is silently inert,
> with no error. Fixed upstream in
> [HashLoad/horse#590](https://github.com/HashLoad/horse/pull/590), released in 3.3.10.

---

## Known limitations

ICS's HTTP server enforces some rules strictly; the provider works around what it
can, but a few user-visible constraints remain (full detail in
`doc/implementation-notes.md` → *ICS server quirks*):

- **Streaming is not supported: `Res.SendStream` answers `501 Not Implemented`**
  with a JSON error (since v1.0.11). The provider has no streaming engine: its
  PostMessage marshal-back cannot hold an ICS reply open while a producer runs.
  Send the whole body with `Res.Send`, or use a provider that streams (CrossSocket,
  nghttp2). Before v1.0.11, `Res.SendStream` fell back to Horse's WebBroker stream
  writer, which cannot reach the socket through this provider: the client got `200`
  with an **empty body** and no error, while the route believed it had streamed.
  Integration test 47 gates the refusal (ICS-SENDSTREAM-REFUSE-1).
- **Uploads must send `Content-Length`.** ICS rejects any POST/PUT/PATCH with no
  `Content-Length` (i.e. a *chunked* request body) with `400`, before the handler
  runs. Browsers and most clients send `Content-Length` on uploads, so this is
  rarely hit — but true chunked request bodies are unsupported in v1.
- **Keep-alive is disabled** — one request per connection. The async deferred-
  response design would otherwise desync request/response pairing on a reused
  connection. A throughput trade-off, not a correctness one; a future
  per-connection-serialisation refactor can restore keep-alive.
> **Resolved in v1.0.7 (SSLCONN-1):** body-less PUT/PATCH over TLS used to `400`,
> because `ClientClass` was assigned only on the plain branch. `FServer.ClientClass`
> is now set unconditionally — `TSslHttpServer` inherits it like any other
> `THttpServer` — so body-less PUT/PATCH and the keep-alive desync guard both work
> over HTTPS. The comment that deferred this named `TSslHttpConnection`, **a type ICS
> does not have**, which is why it read as blocked on work that did not exist.

## Repo layout

```
src/
  Horse.Provider.ICS.RawRequest.pas       — snapshot-backed IHorseRawRequest
  Horse.Provider.ICS.RawResponse.pas      — IHorseRawResponse stub
  Horse.Provider.ICS.WebRequestAdapter.pas
  Horse.Provider.ICS.WebResponseAdapter.pas
  Horse.Provider.ICS.Request.pas          — Validate / Snapshot / Populate
  Horse.Provider.ICS.Response.pas         — TICSResponseBridge.Flush
  Horse.Provider.ICS.Config.pas           — THorseICSConfig + TLS fields
  Horse.Provider.ICS.Pool.pas             — THorseContext pool
  Horse.Provider.ICS.WorkerPool.pas       — bounded worker pool
  Horse.Provider.ICS.pas                  — Console-shape provider (default)
  Horse.Provider.ICS.VCL.pas              — VCL host form
  Horse.Provider.ICS.Daemon.pas           — Windows TService

doc/
  architecture-diagrams.md
  building-an-ics-provider.md
  implementation-notes.md

tests/
  HorseICSParamTestServer.dpr   — A–K route server (port 9110)
  HorseICSParamTestClient.dpr   — A–K assertions; exit code = failures
```

## Dependencies

- [`HashLoad/horse`](https://github.com/HashLoad/horse) >= 3.3.10 — 3.3.0 was the first official release with `IHorseRawRequest` / `IHorseRawResponse`, `HORSE_PROVIDER_*` define normalization, and `Res.Cookie(...)` (RFC 6265 typed-cookie API in `Horse.Core.Cookie`). The floor is **3.3.10 from provider v1.0.8**, because `StopListenGraceful` is silently inert through `THorse` on anything earlier — see [Graceful shutdown](#graceful-shutdown). The `freitasjca/horse` fork is retired.
- [OverbyteICS v9.7](https://wiki.overbyte.eu/wiki/index.php/ICS_Download) (`icsv97/Source` added to the project search path; multipart decoding uses ICS's own `OverbyteIcsFormDataDecoder`)

  Tested on 2026-10-08 with Horse 3.3.12 and Delphi 12. Each result covers the
  integration suite, the graceful-shutdown drain and the TLS suite:

  | ICS | Result |
  |---|---|
  | **V9.7** (release, May 2026) | all green |
  | **V9.8 Beta** (SVN `icsv9`, Oct 2026) | all green, no provider change needed |
  | **V10.0 Beta** (SVN `icsv10`) | **not supported**: does not compile |

  V10 replaces `TIcsWndControl`'s window-message plumbing (`WndProc`,
  `AllocateHWnd`, `AllocateMsgHandler`) with a new cross-platform messaging system
  (`ICS_NewMessaging`, on by default). The provider uses that plumbing to hand each
  worker-thread response back to the ICS thread.

  The test build scripts take the ICS tree from `ICS_ROOT` (default
  `<repo parent>\icsv97`), e.g. `set ICS_ROOT=C:\lang\Repo\icsv98`.

ICS is not Boss-installable — same situation as mORMot. Add `icsv97/Source` to the project's library path manually.

### Runtime files to ship

| File | Windows | Linux / macOS | When |
|---|---|---|---|
| OpenSSL | **none with ICS's default settings**: linked into the `.exe` (see below) | `libcrypto.so.N` + `libssl.so.N`, N = the major version ICS was built for (4 by default) | TLS / mTLS only |

Nothing else: the ICS engine compiles into your binary, so a plain-HTTP build ships
as a single `.exe`.

#### Which OpenSSL your server loads

**ICS decides this when it is compiled, not at run time.** The switches are in ICS's
`Source/Include/OverbyteIcsDefs.inc`; this provider does not override them. With ICS
V9.7's defaults on Windows:

- `OpenSSL_Resource_Files` is on, and `OpenSSL_40` with it. The OpenSSL **4.0** DLLs
  are linked into the `.exe` as resources. On first use ICS extracts them to
  `C:\ProgramData\ICS-OpenSSL\<version>\` (for example `...\4000\`) and loads them
  from there.
- **DLLs placed beside the `.exe` are ignored**, and so is `GSSL_DLL_DIR` if your code
  sets it: ICS overwrites it with the extraction folder (`OverbyteIcsLIBEAY.pas`,
  `IcsOpenSslResource`). `OpenSSL_ProgramData`, also on by default, overwrites it too.
- The process needs write access to `C:\ProgramData\ICS-OpenSSL\` the first time it
  runs. Services running as LocalSystem have it; a locked-down account may not.

To run another OpenSSL, change `OverbyteIcsDefs.inc` and rebuild:

| Goal | Change |
|---|---|
| Link OpenSSL 3.5 (LTS) instead of 4.0 | `OpenSSL_35` instead of `OpenSSL_40`, and `OpenSSL_Major_3` instead of `OpenSSL_Major_4` |
| Load DLLs that you ship yourself | undefine `OpenSSL_Resource_Files` and `OpenSSL_ProgramData`; ICS then loads `libcrypto-N-x64.dll` / `libssl-N-x64.dll` from `GSSL_DLL_DIR`, or from the standard DLL search when it is empty (the `.exe` folder first) |

On **Linux / macOS** nothing is linked: ICS loads `libcrypto.so.N` / `libssl.so.N`
(`.N.dylib` on macOS) through the normal library search, and **does not fall back** to
another N if that file is missing: `Listen` fails with `libcrypto.so.4 - Handle 0`.

**With ICS V9.7's defaults N is 4, and most Linux systems have only OpenSSL 3**
(Ubuntu 22.04 and 24.04 ship `libcrypto.so.3` and no OpenSSL 4 package). To use
OpenSSL 3, change **both** defines in `OverbyteIcsDefs.inc` and rebuild:

- `{$DEFINE OpenSSL_40}` → `{.$DEFINE OpenSSL_40}` and enable `OpenSSL_35` or `OpenSSL_36`;
- `{$DEFINE OpenSSL_Major_4}` → `{.$DEFINE OpenSSL_Major_4}` and enable `OpenSSL_Major_3`.

Changing only `OpenSSL_Major_*` is not enough: a later block in the same file turns
`OpenSSL_40` back into `OpenSSL_Major_4` on every platform.

Without rebuilding ICS, set both of these before the first `Listen`:
```delphi
GSSL_DLL_DIR          := '/usr/lib/x86_64-linux-gnu/';  // trailing slash required
GSSLEAY_DLL_IgnoreNew := True;                          // load OpenSSL 3 instead of 4
```
`GSSLEAY_DLL_IgnoreNew` on its own silently does nothing: ICS switches to 3 only if
`GSSL_DLL_DIR + 'libcrypto.so.3'` exists, and with an empty `GSSL_DLL_DIR` that check
looks in the current directory. Both variables are in `OverbyteIcsTypes`.

ICS V10 (beta at the time of writing) forces OpenSSL 3 on POSIX. Not yet verified on
Linux with this provider; see *Out of scope / follow-ups*.

**Check what you deployed.** `THorseProviderICS.OpenSslRuntime` returns the version and
the full path of the `libcrypto` that `Listen` loaded, for example
`OpenSSL 4.0.0 14 Apr 2026 from C:\ProgramData\ICS-OpenSSL\4000\libcrypto-4-x64.dll`.
Log it at startup. The test suite's `run-tls-tests.bat` prints it on every pass.

> **Correction (v1.0.12).** Earlier versions of this README said to copy
> `libssl-3-x64.dll` / `libcrypto-3-x64.dll` next to the `.exe`. With ICS's default
> settings those copies are never loaded, and every TLS result recorded for this
> provider so far was measured on the linked OpenSSL 4.0.0.

For a **Windows Service** that ships its own DLLs (the second row above), put them in
the service's folder: the Service Control Manager does not inherit the interactive
user's `PATH`.

## Out of scope / follow-ups

- **Delphi POSIX (Linux64 / macOS)** — **supported** via ICS's own POSIX layer (see *Platform scope*). The message-loop marshaling, multipart decoding, and OpenSSL TLS all carry over with no provider code change; the Linux daemon shape ships in `Horse.Provider.ICS.Daemon`.
- **FPC / Lazarus** — still **not viable with stock ICS**: ICS's POSIX support rides the *Delphi* POSIX RTL (`Posix.*`, not FPC's `BaseUnix`), and ICS additionally undefines `USE_SSL` under FPC (`icsv97/Source/Include/OverbyteIcsDefs.inc:2429`), so `TSslHttpServer` does not compile and an ICS-on-Lazarus build would be plain-HTTP only — no advantage over the CrossSocket provider, which already runs on Lazarus *with* TLS. The `{$IF DEFINED(FPC)}` FATAL stays; full analysis in `plans/ics-lazarus-fpc.md`.
- **TLS on Linux is not yet verified with this provider.** By source reading, ICS V9.7's
  defaults request `libcrypto.so.4`, so on an OpenSSL-3-only system `Listen` fails until
  ICS is reconfigured (see *Which OpenSSL your server loads*). Run the TLS suite on
  Linux64 with both the default and the OpenSSL 3 configuration, and record
  `OpenSslRuntime`.
- **FMX cross-platform host** (`Ics.Fmx.OverbyteIcsHttpSrv`) — optional later.
- **Bench server** — functional parity is reached; a throughput bench is the natural next step.

## License

MIT.
