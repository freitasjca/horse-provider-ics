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
  Cfg.SSLVersionMethod := icsSslTLS13;     // TLS 1.3 only

  // Mutual TLS — require + verify client certificates
  Cfg.SSLCAFile        := 'ca.pem';
  Cfg.SSLVerifyPeer    := True;

  THorseProviderICS.ListenWithConfig(9443, Cfg);
end.
```

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

ICS is not Boss-installable — same situation as mORMot. Add `icsv97/Source` to the project's library path manually.

### Runtime files to ship

| File | Windows | Linux / macOS | When |
|---|---|---|---|
| OpenSSL | `libssl-3-x64.dll`<br>`libcrypto-3-x64.dll` | `libssl.so.3`<br>`libcrypto.so.3` | TLS / mTLS only |

Nothing else — the ICS engine itself compiles into your binary, so a plain-HTTP
build ships as a single `.exe`.

**The OpenSSL libraries come with ICS.** They are in the ICS distribution
(`icsv97/`), already matched to the ICS version you compiled against, so there
is no version hunt and no mismatch against a system-wide OpenSSL. This is a real
advantage over the CrossSocket, mORMot and nghttp2 providers, all of which
expect you to source OpenSSL yourself and keep its version in step. Copy the
pair next to your `.exe` rather than into `System32`.

For a **Windows Service**, the DLLs must sit in the same folder as the service
`.exe` — the Service Control Manager does not inherit the interactive user's
`PATH`, so a copy that works when you double-click will fail when the service
starts.

ICS 4.x-era builds may name the pair `libssl-1_1-x64.dll` / `libcrypto-1_1-x64.dll`.
Pick one version family and use it throughout: 1.1.x and 3.x cannot coexist in a
single process.

## Out of scope / follow-ups

- **Delphi POSIX (Linux64 / macOS)** — **supported** via ICS's own POSIX layer (see *Platform scope*). The message-loop marshaling, multipart decoding, and OpenSSL TLS all carry over with no provider code change; the Linux daemon shape ships in `Horse.Provider.ICS.Daemon`.
- **FPC / Lazarus** — still **not viable with stock ICS**: ICS's POSIX support rides the *Delphi* POSIX RTL (`Posix.*`, not FPC's `BaseUnix`), and ICS additionally undefines `USE_SSL` under FPC (`icsv97/Source/Include/OverbyteIcsDefs.inc:2429`), so `TSslHttpServer` does not compile and an ICS-on-Lazarus build would be plain-HTTP only — no advantage over the CrossSocket provider, which already runs on Lazarus *with* TLS. The `{$IF DEFINED(FPC)}` FATAL stays; full analysis in `plans/ics-lazarus-fpc.md`.
- **FMX cross-platform host** (`Ics.Fmx.OverbyteIcsHttpSrv`) — optional later.
- **Bench server** — functional parity is reached; a throughput bench is the natural next step.

## License

MIT.
