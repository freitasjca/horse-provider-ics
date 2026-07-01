unit Horse.Provider.ICS.Daemon;

(*
  Horse ICS Provider — Delphi cross-platform Daemon composition
  =============================================================
  Selects the ICS transport for a Delphi binary running as a long-running
  OS-supervised process. THorseProviderICSDaemon is the THorseProvider alias
  resolved by Horse.pas when HORSE_PROVIDER_ICS + HORSE_APPTYPE_DAEMON are both
  defined on the Delphi compiler — REGARDLESS of target platform.

  Two OS-specific paths live in this one unit (mirroring the cross-platform
  Horse.Provider.CrossSocket.Daemon.pas and the Indy Horse.Provider.Daemon.pas):

    {$IFDEF MSWINDOWS}   THorseICSService
                         A Vcl.SvcMgr.TService base class. ServiceStart spawns
                         a worker thread for THorse.Listen (the SCM has a start
                         timeout while ICS's message loop blocks), ServiceStop
                         calls THorse.StopListen which drains in-flight pipelines
                         via [SEC-30] and unblocks the listener thread.

      type TMyHorseService = class(THorseICSService)
        procedure ServiceCreate(Sender: TObject);  // register routes here
      end;

    {$ELSE}              THorseICSLinuxDaemonApp
                         A static helper. Run() installs POSIX SIGTERM/SIGINT
                         handlers that call THorse.StopListen, ignores SIGPIPE
                         (so peer drops don't kill the daemon), runs the user
                         setup proc, then calls the blocking THorse.Listen which
                         pumps ICS's Ics.Posix.PXMessages loop until a signal
                         arrives.

      uses Horse, Horse.Provider.ICS.Daemon;
      procedure SetupRoutes;
      begin
        THorse.Get('/ping', GetPing);
      end;
      begin
        THorseICSLinuxDaemonApp.Run(SetupRoutes, 9000);
      end.

  Mental model: HORSE_APPTYPE_DAEMON means "OS-supervised long-running process".
  Whether that process is a Windows Service or a Linux daemon is a function of the
  build target, not the define. ICS's POSIX support is Delphi-only (it rides the
  Delphi POSIX RTL), so the FPC seam stays a hard FATAL.
*)

{$IF DEFINED(FPC)}
  {$MESSAGE FATAL 'Horse.Provider.ICS.Daemon requires Delphi: ICS POSIX support is not available under FPC.'}
{$IFEND}

interface

uses
{$IFDEF MSWINDOWS}
  Vcl.SvcMgr,
{$ENDIF}
{$IFDEF LINUX}
  Posix.Signal,
{$ENDIF}
{$IFDEF POSIX}
  Posix.Stdlib,
{$ENDIF}
  System.SysUtils,
  System.Classes,
  Horse.Provider.ICS;

type
  { Marker subclass — Horse.pas's THorseProvider alias resolves here when
    HORSE_PROVIDER_ICS + HORSE_APPTYPE_DAEMON are defined on Delphi (any
    target). Inherits all transport behaviour from THorseProviderICS; only
    the lifecycle wrappers below differ by platform. }
  THorseProviderICSDaemon = class(THorseProviderICS);

{$IFDEF MSWINDOWS}
  { Optional convenience TService base class for Windows-service binaries.
    Spawns a worker thread for THorse.Listen so the SCM ack is not blocked by
    ICS's blocking message loop. }
  THorseICSService = class(TService)
  private
    FPort:           Integer;
    FListenerThread: TThread;
  protected
    procedure DoServiceStart(Sender: TService; var Started: Boolean);
    procedure DoServiceStop(Sender: TService;  var Stopped: Boolean);
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;
    property Port: Integer read FPort write FPort default 9000;
  end;
{$ENDIF MSWINDOWS}

{$IFNDEF MSWINDOWS}
  { User-provided setup procedure: register routes, middleware, config. }
  THorseICSDaemonSetupProc = procedure;

  { Optional convenience runner for Delphi binaries cross-compiled to Linux
    (or other POSIX targets). Installs SIGTERM + SIGINT handlers that call
    THorse.StopListen, ignores SIGPIPE, invokes ASetup to register routes,
    then calls THorse.Listen(APort) which blocks (pumping ICS's POSIX message
    loop) until a signal arrives. }
  THorseICSLinuxDaemonApp = class
  public
    class procedure Run(ASetup: THorseICSDaemonSetupProc; APort: Integer); static;
  end;
{$ENDIF MSWINDOWS}

implementation

uses
  Horse;

{$IFDEF MSWINDOWS}

{ THorseICSService }

constructor THorseICSService.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FPort   := 9000;
  OnStart := DoServiceStart;
  OnStop  := DoServiceStop;
end;

destructor THorseICSService.Destroy;
begin
  if Assigned(FListenerThread) then
  begin
    THorse.StopListen;
    FListenerThread.WaitFor;
    FreeAndNil(FListenerThread);
  end;
  inherited;
end;

procedure THorseICSService.DoServiceStart(Sender: TService;
  var Started: Boolean);
var
  LPort: Integer;
begin
  LPort := FPort;
  { Run Listen on a dedicated worker thread so ServiceStart returns promptly to
    the SCM — ICS's message loop blocks the calling thread until StopListen. }
  FListenerThread := TThread.CreateAnonymousThread(
    procedure begin THorse.Listen(LPort); end);
  FListenerThread.FreeOnTerminate := False;
  FListenerThread.Start;
  Started := True;
end;

procedure THorseICSService.DoServiceStop(Sender: TService;
  var Stopped: Boolean);
begin
  THorse.StopListen;                   // graceful drain via SEC-30
  if Assigned(FListenerThread) then
  begin
    FListenerThread.WaitFor;           // wait for Listen to actually return
    FreeAndNil(FListenerThread);
  end;
  Stopped := True;
end;

{$ENDIF MSWINDOWS}

{$IFNDEF MSWINDOWS}

procedure HandleStopSignal(ASignal: Integer); cdecl;
begin
  { POSIX signal handler — minimal reentrant-safe work only.
    THorse.StopListen posts a quit to ICS's message loop and stops the server,
    which unblocks the THorse.Listen call below. }
  THorse.StopListen;
end;

{ THorseICSLinuxDaemonApp }

class procedure THorseICSLinuxDaemonApp.Run(
  ASetup: THorseICSDaemonSetupProc; APort: Integer);
begin
  {$IFDEF LINUX}
  signal(SIGTERM, @HandleStopSignal);
  signal(SIGINT,  @HandleStopSignal);
  { SIGPIPE: ignore — ICS handles client-side resets internally; the default
    action (terminate) would crash the daemon on a peer drop. }
  signal(SIGPIPE, TSignalHandler(SIG_IGN));
  {$ENDIF}

  if Assigned(ASetup) then
    ASetup();

  THorse.Listen(APort);                { blocks until StopListen unblocks it }
end;

{$ENDIF MSWINDOWS}

end.
