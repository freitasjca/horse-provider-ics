# Windows service sample (ICS)

A Horse server that runs as a Windows service on `THorseICSService`, the base class
in `src/Horse.Provider.ICS.Daemon.pas`. The service class declares no
`OnStart`, `OnStop` or `GetServiceController`, so this sample tests the base exactly
as your application would use it.

| File | Role |
|---|---|
| `HorseICSServiceDemo.dpr` | program; lists the base **and** the service as `{Name: TService}` |
| `ICSDemoService.pas` / `.dfm` | `THorseICSDemoSvc = class(THorseICSService)`; `.dfm` starts with `inherited` |

Routes, on port 9010:

| Route | Answer |
|---|---|
| `GET /ping` | `pong` |
| `GET /status` | JSON with the port and the service's process id |
| `POST /echo` | the request body. It travels through ICS's body handling, the worker pool and the hand-off back to the listener thread's message pump |

## Creating the project in the IDE

The repository ships no `.dproj`; the IDE creates it.

1. **File > Open Project**, choose `HorseICSServiceDemo.dpr`. The IDE creates
   `HorseICSServiceDemo.dproj` next to it.
2. **Project > Options > Building > Delphi Compiler** (All configurations):
   - *Conditional defines*: `HORSE_PROVIDER_ICS;HORSE_APPTYPE_DAEMON`
   - *Search path*: `..\..\..\src;..\..\..\..\horse\src;..\..\..\..\icsv97\Source`
     (adjust if Horse or ICS live elsewhere)
3. Save, close the IDE, and check that both units carry the service entries:

   ```
   findstr /n "DCCReference Form DesignClass" HorseICSServiceDemo.dproj
   ```

   Both `DCCReference` entries need `<Form>` and `<DesignClass>TService</DesignClass>`.
   If one is missing, add it by hand with the IDE closed:

   ```xml
   <DCCReference Include="..\..\..\src\Horse.Provider.ICS.Daemon.pas">
       <Form>HorseICSService</Form>
       <FormType>dfm</FormType>
       <DesignClass>TService</DesignClass>
   </DCCReference>
   <DCCReference Include="ICSDemoService.pas">
       <Form>HorseICSDemoSvc</Form>
       <FormType>dfm</FormType>
       <DesignClass>TService</DesignClass>
   </DCCReference>
   ```

4. Reopen, open `ICSDemoService.pas`, and switch to the designer. It must show a
   **service** (`DisplayName`, `ServiceType`, `StartType`), not a form. If the IDE
   reports `Property DisplayName does not exist`, press **Cancel**, never Ignore,
   and recheck step 3.
5. **Project > Build**. Close the IDE, then check that the `.dfm` still starts with
   `inherited` and that the `.dpr`'s `begin..end` block is unchanged.

## Install, run, stop (elevated prompt)

```
HorseICSServiceDemo.exe /install
sc start HorseICSDemoSvc
sc query HorseICSDemoSvc
netstat -ano | findstr :9010
curl http://127.0.0.1:9010/ping
curl http://127.0.0.1:9010/status
curl -d "hello-ics" http://127.0.0.1:9010/echo
sc stop HorseICSDemoSvc
netstat -ano | findstr :9010
HorseICSServiceDemo.exe /uninstall
```

Expected:
- `sc query` shows `RUNNING`, and netstat shows the port owned by the service's PID;
- `/status` reports that same PID;
- `/echo` returns `hello-ics`;
- after `sc stop`, nothing listens on 9010.

The service name is the `.dfm` root component's `Name` (`HorseICSDemoSvc`); the
Services console shows its `DisplayName`, "Horse ICS Demo".

## Troubleshooting

The service writes its errors to the Application event log with itself as the
source. It registers no message file, so plain-text views show the stock text for
event ID 0, "The operation completed successfully". Read the actual message in the
event's data:

```
wevtutil qe Application /q:"*[System[Provider[@Name='HorseICSDemoSvc']]]" /c:1 /rd:true /f:xml
```

It's in the `<Data>` element (Event Viewer: the *Details* tab).

| Symptom | Cause |
|---|---|
| `sc start` fails, Application event log: `Horse ICS: THorse.Listen(9010) failed: ...` | `Listen` raised. Port 9010 already taken (another server, or the ICS test server), or a TLS file missing |
| SCM error 1067, event 1000 with `0x0EEDFADE` | an exception before `OnStart`, e.g. routes registered in a unit `initialization` |
| `EReadError ... Margins.Left` at start | the `.dfm` was saved as a form. Restore it from git and recheck the `.dproj` entries |
| `sc start` takes 20 s, event log warns `did not return within 20000 ms`, `sc stop` hangs | the service was built with `{$APPTYPE CONSOLE}`, so `Listen` runs ICS's own blocking loop. Build it as a GUI-subsystem application |
| OpenSSL missing (TLS only) | the SCM does not use your interactive `PATH`. Put the DLLs next to the exe (see the main README, *Runtime files to ship*) |
