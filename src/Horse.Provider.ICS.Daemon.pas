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
                         a listener thread that calls THorse.Listen and then
                         PUMPS MESSAGES for ICS (SVC-PUMP-1); ServiceStop asks
                         that thread to run THorse.StopListen itself, then
                         joins it. Implements GetServiceController
                         (SVC-CTRL-2) and has its own .dfm (SVC-DFM-1): list
                         this unit in the app's .dpr as
                         {HorseICSService: TService}.

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
  System.SyncObjs,
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

    SVC-PUMP-1: ICS is thread-affine. Every ICS component binds its hidden
    window to the thread that creates it (OverbyteIcsWndControl.pas,
    AllocateHWnd: FThreadId := GetCurrentThreadId), and nothing happens on an
    ICS socket unless that thread pumps messages. In a service IsConsole is
    False, so THorse.Listen returns as soon as the server is up instead of
    running ICS's MessageLoop. The listener thread therefore pumps messages
    itself after Listen returns: it is the thread that owns the listening
    socket, the clients and the provider's marshal-back receiver. Before
    SVC-PUMP-1 the thread ended right after Listen, and Windows destroys a
    thread's windows when the thread exits, so ICS lost the window every
    socket event is delivered to (found by reading the code; this base had
    no recorded service run).

    Stop is marshalled onto the same thread (a thread message the pump
    answers with THorse.StopListen), because ICS objects can only be closed
    and freed by their owning thread. StopListen drains through [SEC-30] the
    way the VCL host's FormClose does; the drain waits for the worker pool on
    the pump thread, so a reply still queued for the pump at that moment is
    dropped, exactly as on the VCL host.

    A failed Listen (port in use, bad certificate) is reported to the SCM:
    DoServiceStart waits for Listen's outcome, logs the exception to the
    Application event log and answers Started := False, so sc start fails
    instead of reporting RUNNING.

    SVC-CTRL-2: TService.GetServiceController is abstract and TService.Main
    calls it on the SCM's thread before OnStart, so a descendant without the
    override died at every start (SCM error 1067) with nothing logged. This
    class implements it. One service per process - the same limit THorse
    has, as it hosts one listener per process.

    Build the service as a GUI-subsystem application (the IDE's Service
    Application default). With APPTYPE CONSOLE, IsConsole is True and Listen
    runs ICS's own MessageLoop, which does not answer the stop message. }
  THorseICSService = class(TService)
  private
    FPort:             Integer;
    FListenerThread:   TThread;
    FListenerThreadId: Cardinal;
    FQueueReady:       TEvent;   // the listener thread has a message queue
    FListenDone:       TEvent;   // THorse.Listen returned or raised
    FListenError:      string;   // set by the listener thread before FListenDone
    procedure StopListenerThread;
  protected
    procedure DoServiceStart(Sender: TService; var Started: Boolean);
    procedure DoServiceStop(Sender: TService;  var Stopped: Boolean);
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;
    function GetServiceController: TServiceController; override;
    { Set this BEFORE the service starts (in the constructor or ServiceCreate,
      typically) so the listener thread binds the intended port. }
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
{$IFDEF MSWINDOWS}
  Winapi.Windows,
  Winapi.Messages,
{$ENDIF}
  Horse;

{$IFDEF MSWINDOWS}

// SVC-DFM-1: the base class's own .dfm (Horse.Provider.ICS.Daemon.dfm, no
// DisplayName). The IDE designs a class(THorseICSService) descendant as a
// SERVICE only when this unit is listed in the .dpr as
// {HorseICSService: TService} and the descendant's .dfm starts with
// 'inherited'; otherwise it falls back to the form designer ("Property
// DisplayName does not exist"). At run time this resource is streamed first.
{$R *.dfm}

const
  // SVC-PUMP-1: posted to the listener THREAD (hwnd = 0), so it can never
  // collide with the WM_USER-based messages ICS posts to its own windows.
  WM_HORSE_ICS_SERVICE_STOP = WM_APP + $1C5;

  // How long DoServiceStart waits for THorse.Listen. Binding and building the
  // TLS context take milliseconds; the SCM's own start timeout is 30 s.
  LISTEN_WAIT_MS = 20000;

var
  // SVC-CTRL-2: the service this process hosts. Written on the main thread
  // (Application.CreateForm, before StartServiceCtrlDispatcher), read on the
  // SCM's control thread afterwards.
  GActiveService: THorseICSService;

procedure HorseICSServiceController(CtrlCode: DWORD); stdcall;
begin
  if GActiveService <> nil then
    GActiveService.Controller(CtrlCode);
end;

{ THorseICSService }

constructor THorseICSService.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FPort       := 9000;
  FQueueReady := TEvent.Create(nil, True, False, '');
  FListenDone := TEvent.Create(nil, True, False, '');
  OnStart     := DoServiceStart;
  OnStop      := DoServiceStop;
  GActiveService := Self;
end;

destructor THorseICSService.Destroy;
begin
  if GActiveService = Self then
    GActiveService := nil;
  StopListenerThread;
  FreeAndNil(FListenDone);
  FreeAndNil(FQueueReady);
  inherited;
end;

function THorseICSService.GetServiceController: TServiceController;
begin
  Result := HorseICSServiceController;
end;

procedure THorseICSService.DoServiceStart(Sender: TService;
  var Started: Boolean);
var
  LPort: Integer;
begin
  LPort := FPort;
  FListenError := '';
  FListenerThreadId := 0;
  FQueueReady.ResetEvent;
  FListenDone.ResetEvent;

  FListenerThread := TThread.CreateAnonymousThread(
    procedure
    var
      LMsg: TMsg;
    begin
      // Create this thread's message queue BEFORE announcing the thread id,
      // so a stop posted at any later moment is queued, never lost.
      PeekMessage(LMsg, 0, WM_USER, WM_USER, PM_NOREMOVE);
      FListenerThreadId := GetCurrentThreadId;
      FQueueReady.SetEvent;

      try
        // Not a console app, so this returns once the server is up. Every
        // ICS window it allocates belongs to THIS thread.
        THorse.Listen(LPort);
      except
        on E: Exception do
        begin
          FListenError := E.ClassName + ': ' + E.Message;
          // Tear down whatever Listen built, on the thread that owns it.
          try
            THorse.StopListen;
          except
            // Startup already failed; the original error is the one to report.
          end;
          FListenDone.SetEvent;
          Exit;
        end;
      end;
      FListenDone.SetEvent;

      // The ICS message pump (SVC-PUMP-1). GetMessage returns False on
      // WM_QUIT, which ends the loop as ICS's own MessageLoop does.
      while GetMessage(LMsg, 0, 0, 0) do
      begin
        if (LMsg.hwnd = 0) and (LMsg.message = WM_HORSE_ICS_SERVICE_STOP) then
        begin
          THorse.StopListen;   // [SEC-30] drain + teardown, on the owning thread
          Break;
        end;
        TranslateMessage(LMsg);
        DispatchMessage(LMsg);
      end;
    end);
  FListenerThread.FreeOnTerminate := False;
  FListenerThread.Start;

  if FListenDone.WaitFor(LISTEN_WAIT_MS) <> wrSignaled then
  begin
    // Listen has not come back yet. Leave the thread running; the pump starts
    // as soon as Listen returns, and a stop is queued until then.
    LogMessage(Format('Horse ICS: THorse.Listen(%d) did not return within %d ms',
      [LPort, LISTEN_WAIT_MS]), EVENTLOG_WARNING_TYPE);
    Started := True;
    Exit;
  end;

  if FListenError <> '' then
  begin
    LogMessage(Format('Horse ICS: THorse.Listen(%d) failed: %s',
      [LPort, FListenError]), EVENTLOG_ERROR_TYPE);
    FListenerThread.WaitFor;
    FreeAndNil(FListenerThread);
    Started := False;
    Exit;
  end;

  Started := True;
end;

procedure THorseICSService.StopListenerThread;
begin
  if not Assigned(FListenerThread) then
    Exit;
  // If the thread already ended (Listen failed), PostThreadMessage fails and
  // WaitFor returns at once.
  if FQueueReady.WaitFor(LISTEN_WAIT_MS) = wrSignaled then
    PostThreadMessage(FListenerThreadId, WM_HORSE_ICS_SERVICE_STOP, 0, 0);
  FListenerThread.WaitFor;
  FreeAndNil(FListenerThread);
end;

procedure THorseICSService.DoServiceStop(Sender: TService;
  var Stopped: Boolean);
begin
  StopListenerThread;   // the listener thread runs THorse.StopListen
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
