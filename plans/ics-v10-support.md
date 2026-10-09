# ICS V10 support for horse-provider-ics

Status: **PLAN, no code yet.** Written 2026-10-09 from the ICS V10 sources at
`https://svn.overbyte.be/svn/icsv10/` (SVN revision 14, `ReadMe10.txt` "Revised:
Sept 2, 2026, Release: V10.0 Beta"). Provider baseline: v1.0.12 on ICS V9.7.

V10 is a beta. Its own readme says: *"V10 is a work in progress, partially
functional!!!! This readme file is not yet updated."* Every fact below is from
source reading at that revision and must be re-checked against a later
revision before code is written (step 0).

---

## 1. What V10 changes that matters to this provider

| # | V10 change | Where (V10 source) | Effect on the provider |
|---|---|---|---|
| F1 | **`ICS_NewMessaging` is on by default, Windows included.** It replaces Windows message queues with a cross-platform message manager. Forced on POSIX. Delphi 10.4+ only. | `Include/OverbyteIcsDefs.inc` ~320-327, history entry May 22, 2026 | The provider's marshal-back no longer compiles (F2). |
| F2 | Under `ICS_NewMessaging`, `TIcsWndControl` has **no `AllocateHWnd`, `Handle`, `WndHandler`/`AllocateMsgHandler` or `WndProc`**. In their place: `IcsPostMessage(Sender, Msg, WParam, LParam): Boolean` and a virtual `IcsDispatchMessage(const Value: TIcsSocketMsgRec)`. | `OverbyteIcsWndControl.pas` ~325-368, impl ~730-790 | `TICSMarshalReceiver` (`AllocateHWnd` + `AllocateMsgHandler` + `WndProc` override) and `MarshalBack` (Win32 `PostMessage` to `FReceiver.Handle`) must be rewritten for V10. This is the E2137 `WndProc` error seen when building against V10 on 2026-10-08. |
| F3 | **Every posted message is delivered on the Delphi main thread.** With `RTL_MESSAGING`, a helper thread waits on a pipe and calls `Synchronize` into the main thread. Without it (the default), NX.Horizon's `Send(..., MainAsync)` queues to the main thread. The listener then calls `TIcsWndControl(Value.Instance).IcsDispatchMessage(Value)`. | `OverbyteIcsMessMan.pas` `PostMessage` ~298, `TIcsMessagingHelperThread.Execute` ~399; `OverbyteIcsWndControl.pas` `IcsMessageListener` ~730 | ICS socket events and our marshalled replies both run on the main thread. The main thread must keep processing queued work (`CheckSynchronize` or an application loop), or nothing is ever delivered. |
| F4 | **`TIcsWndControl.MessageLoop` is a stub.** It sets `Terminated := True` and returns; the old `GetMessage` loop is commented out with "V10 pending handle process messages". `ProcessMessage` is a stub too. | `OverbyteIcsWndControl.pas` ~793-835 | The provider's console mode blocks on `FServer.MessageLoop`. On V10 that call returns at once: `Listen` returns and a console server exits. |
| F5 | **Default message transport is a third-party library**, NX.Horizon (`github.com/dalijap/nx-horizon`), unless `RTL_MESSAGING` is defined. | `OverbyteIcsDefs.inc` ~329-331 | A V10 user either installs NX.Horizon or defines `RTL_MESSAGING`. The README must say so; the test matrix must cover both. |
| F6 | **ICS's old POSIX units are gone**, including `Ics.Posix.WinTypes` and `Ics.Posix.PXMessages`. The V10 `Source/` listing has no `Ics.Posix.*` file; only history notes mention them. | `Source/` listing at r14 | The provider's `{$ELSE}` (non-Windows) `uses` branch imports both, so a V10 Linux build fails at `uses`. Those units only supplied the window-message types for F2's old path. |
| F7 | MacOS is not supported by V10 at this revision ("currently only a Linux target is supported, not MacOS"). | `OverbyteIcsDefs.inc` history May 22, 2026 | README platform table: V10 = Windows + Linux64. |
| F8 | `ReadMe10.txt` says the default is OpenSSL 4.0.2 (ships 3.5.8 / 3.6.4 / 4.0.2), **but `OverbyteIcsDefs.inc` at r14 links `OpenSSL_36`** while `OpenSSL_Major_4` stays defined. On Windows `GSSL_MAJOR_VER` then picks 4, which disagrees with the linked 3.6 resources. Beta inconsistency, re-check in step 0. | `ReadMe10.txt`; `OverbyteIcsDefs.inc` ~360-370, ~2451-2479; `OverbyteIcsTypes` `GSSL_MAJOR_VER` | `OpenSslRuntime` (v1.0.12) shows what actually loads; the step 3 gate records it. |
| F9 | **POSIX forced to OpenSSL 3** (`{$IFDEF POSIX} DEFINE OpenSSL_Major_3, UNDEF OpenSSL_Major_4`). With r14's default `OpenSSL_36` nothing re-enables `Major_4`, so Linux loads `libcrypto.so.3`. In V9.7 the same file has no such block, and the default `OpenSSL_40` makes Linux request `libcrypto.so.4` (README v1.0.12+ documents the workaround). | `OverbyteIcsDefs.inc` ~2451; V9.7 ~2498-2527 | Step 4 must confirm `OpenSslRuntime` on Linux shows 3.x. If a later V10 revision defaults to `OpenSSL_40` again, the sanity block re-enables `Major_4` after the POSIX block and Linux is back to `.so.4`. |

**Unchanged, checked at r14.** No identifier the provider uses on `THttpServer`,
`THttpConnection`, `TSslHttpServer`, `TSslContext` or `TWSocketServer` has
disappeared:
- the `On*Document` events, `OnPostedData`, `ClientClass`;
- `AnswerBodyTB`, `RequestContentLength`, `RequestHeader`, `Receive`;
- `SslMinVersion`, `SslVerifyPeerModes`, `SslCipherList`, `InitContext`, `SslCtxPtr`.

`THttpConnection.ProcessPostPutPat` is still virtual and still ends with
`else if FKeepAlive = FALSE then CloseDelayed`, so FIX-ICS-CONNCLOSE-1's override
applies as is.

---

## 2. Design

One provider source for V9.x and V10, split on ICS's own define. **V9.x behaviour
must not change**: its window-message path is validated (integration 119, TLS
7+2+5+6, drain 5/5).

### 2.1 Telling V9 from V10 at compile time

`ICS_NewMessaging` is defined inside ICS's `OverbyteIcsDefs.inc`, which the
provider does not include today, and no type in a unit shared by both versions
is conditional on it: `TIcsSocketMsgRec` is declared unconditionally in
`OverbyteIcsTypes`.

**Decision:** `Horse.Provider.ICS.pas` includes ICS's file,
`{$I OverbyteIcsDefs.inc}`, after its own mode directives, and tests
`{$IFDEF ICS_NewMessaging}`. Both V9.7 and V10 ship that file, and V9.7 never
defines the symbol.
- The build scripts (`build-tests-dcc.bat`, `build-tls-dcc.bat`,
  `build-drain-dcc.bat`) gain `-I!ICS_ROOT!\Source\Include`.
- Users of the provider must add the same include path. The README states this.
- **Check in step 1:** the include file also sets ICS's own compiler switches
  (`{$B-}`, `{$T-}`, ...). Confirm they don't change how the provider unit
  compiles. If they do, read the define from a one-line wrapper include instead.

### 2.2 Marshal-back (F2, F3)

**V10 path, recommended option A:** keep a receiver, but on V10's mechanism.
`TICSMarshalReceiver` stays a `TIcsWndControl` descendant and overrides
`IcsDispatchMessage`. `MarshalBack` calls
`FReceiver.IcsPostMessage(FReceiver, WM_HORSE_RESPONSE_READY, Token, 0)`.
`IcsDispatchMessage` takes the pending request out of `FPendingMap` and calls
`DispatchOnLoop`, as `WndProc` does today. The message ID is a provider
constant above ICS's range, because nothing allocates IDs under V10.
- Why: the reply travels the same delivery path as ICS's own socket events, so
  it lands on the same thread with the same ordering guarantees.
- Risk: `IcsMessageListener` casts `Value.Instance` without checking that it
  still exists ("queued messages ... refering to an already destroyed socket" is
  ICS's own comment). Free the receiver only after the post queue is drained
  for it. `TIcsMessageManager.CleanPostQueue(Instance)` exists on the
  `RTL_MESSAGING` path; whether it exists on the NX.Horizon path is to be
  checked (open question Q4).

**Option B, fallback:** `TThread.Queue(nil, procedure begin DispatchOnLoop(...) end)`.
It is RTL-only and doesn't depend on ICS's messaging internals. It also lands on
the main thread, the same thread as ICS's events. Weaker on ordering, and a
queued closure can't easily be removed on Stop. Use it only if A hits Q4.

**V9.x path:** unchanged. `AllocateHWnd`, `AllocateMsgHandler`, `WndProc` and
Win32 `PostMessage` stay inside `{$IFNDEF ICS_NewMessaging}`.

### 2.3 Console blocking (F4)

Under `ICS_NewMessaging`, `InternalListen`'s console branch stops calling
`FServer.MessageLoop` and runs its own loop on the main thread:
```pascal
while FRunning do
  CheckSynchronize(50);   // delivers ICS events and our replies (F3)
```
`Stop` sets `FRunning := False`. A queued no-op wakes the loop at once
(`TThread.Queue(nil, procedure begin end)`), so no new event is needed. VCL and
service shapes keep returning immediately, as now: VCL's `Application` loop
already services `CheckSynchronize`. **The Windows service shape needs
verifying, Q3.**

### 2.4 Graceful drain (F3)

`StopListenGraceful` waits for in-flight requests. Under V10 those requests can
only finish if the main thread delivers their replies. If the drain is called
**on the main thread** and simply sleeps, it deadlocks until the timeout and
every in-flight reply is lost. Under `ICS_NewMessaging` the wait loop must
call `CheckSynchronize` while it waits. The drain gate (`tests/HorseICSDrainTest`)
must include the main-thread-caller case, and run once with the drain on the main
thread and once from a worker.

### 2.5 POSIX (F6, F7)

The `{$ELSE}` `uses` branch gets an inner split: V9.x keeps `Ics.Posix.WinTypes`
and `Ics.Posix.PXMessages`; V10 imports neither. The window-message types are
only used by the V9 receiver. `Horse.Provider.ICS.Daemon` needs the same audit:
under V10 it must run the 2.3 loop, not a message pump. MacOS: V10 = not
supported. Write that in the README; don't guard it in code.

---

## 3. Steps and gates

Each step ends with a gate. Nothing ships until V10 leaves beta. The code can
live on a branch before that.

| Step | Work | Gate |
|---|---|---|
| **0. Re-check** | Fetch the newest V10 revision. Re-run this file's checks: F2 API, F3 delivery thread, F4 `MessageLoop` still a stub?, F6 POSIX units. Record the revision. | This table updated with the revision; any changed row re-planned before code |
| **1. Compile** | 2.1 detection + 2.2 option A + 2.3 + 2.5 `uses`, behind `{$IFDEF ICS_NewMessaging}` | Builds on V9.7, V9.8 **and** V10 (Win64, both `RTL_MESSAGING` and NX.Horizon). V9.7 binary behaviour unchanged |
| **2. V9 regression** | none: run only | V9.7: integration 119/119, TLS 7+2+5+6, drain 5/5 (same as v1.0.12) |
| **3. V10 Windows** | fix what step 3 finds | V10 + `RTL_MESSAGING` **and** V10 + NX.Horizon: integration 119/119, TLS 7+2+5+6 (`OpenSslRuntime` shows 4.0.2), drain with the drain called on the main thread AND from a worker |
| **4. V10 Linux64** | `Horse.Provider.ICS.Daemon` per 2.5 | Linux64 build via PAServer; integration + TLS on Linux. This also settles the open `libcrypto.so.4` question from v1.0.12 |
| **5. Performance** | none: measure | V9.7 vs V10 throughput and p99 on the same machine, **with a null control** (V9.7 vs V9.7) first. V10 funnels all socket events through one main thread, so a drop is plausible. Report it, don't gate on it |
| **6. Shapes + docs** | VCL and Windows-service samples on V10; README ICS version table, `-I` include path, NX.Horizon / `RTL_MESSAGING` note, MacOS not supported on V10 | VCL + service smoke test on V10 |

The new message path is code that can't be compiled from this environment, so
every step runs on the Windows machine. The `delphi-pitfalls` and `delphi-threading` skills apply.

---

## 4. Open questions for the ICS maintainers (Angus Robertson / François Piette)

- **Q1.** `MessageLoop`/`ProcessMessage` are stubs at r14. Will V10 ship a
  blocking loop for console servers, or should console applications run
  `CheckSynchronize` themselves (2.3)?
- **Q2.** Is main-thread delivery (F3) final for servers, or will a server be
  able to run its events on a worker thread, as `MultiThreaded` allowed in V9?
- **Q3.** Windows service: the main thread sits in the service control
  dispatcher. How are `MainAsync` / `Synchronize` deliveries meant to reach it?
- **Q4.** Freeing a `TIcsWndControl` with messages still queued for it: the
  listener casts `Value.Instance` unchecked. Is `CleanPostQueue` the intended
  answer, and does it exist on the NX.Horizon path?

Ask them on the ICS forum
(`https://en.delphipraxis.net/forum/37-ics-internet-component-suite/`) once
step 0 confirms they still apply. Their answers can remove whole steps: Q1
removes 2.3, and Q2 changes 2.2 and 2.4.

---

## 5. Not in scope

- FPC/Lazarus: still not viable. ICS's POSIX support targets the Delphi RTL,
  and V10's `ICS_NewMessaging` requires Delphi 10.4+.
- Streaming (`Res.SendStream`): still refused with 501, unchanged by V10.
- MacOS: not supported by V10 at r14.
