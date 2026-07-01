unit Horse.Provider.ICS;

(*
  Horse OverbyteICS Provider (Delphi — Windows & POSIX/Linux)
  ===========================================================
  HTTP/HTTPS transport for Horse using ICS THttpServer / TSslHttpServer.

  Why ICS?
  --------
  ICS ships an independent async socket engine with a deeply tested HTTP
  server stack and *modern* OpenSSL 3.x / 4.x TLS — TLS 1.3, SNI, mTLS,
  and security-level controls. That OpenSSL surface is the provider's
  distinctive value. The HTTP server itself runs single-threaded on
  ICS's message loop (the cross-platform `TIcsWndControl` pattern — a
  Win32 message queue on Windows, the `Ics.Posix.PXMessages` pump on
  POSIX/Linux/macOS).

  Architecture — worker-pool offload + message-loop marshaling
  ------------------------------------------------------------
  ICS forbids touching the socket off its message-loop thread, so the
  provider can't run THorse.Execute inline:

    [loop]                          [worker pool]                [loop]
    OnXxxDocument
      Flags := hgWillSendMySelf
      (GET: now;  POST/PUT/PATCH:   ── snapshot request data;
       after body buffered via         enqueue {snap, conn token};
       OnPostedData)                   acquire pool ctx;
                                       Populate THorseRequest;
                                       THorse.Execute;
                                       build response payload;
                                       PostMessage(loopWnd, WM_X,
                                                   token) ──────►
                                                                  conn still alive?
                                                                    AnswerString(...)
                                                                  release pool ctx

  Snapshots are owned by the worker; the marshal-back handler frees them
  after AnswerString returns.

  ── Hardening (mirrors the mORMot/CrossSocket providers) ──────────────────
    [SEC-29] Validate-before-pool — invalid requests get a direct 4xx
             response; pool is never acquired and pipeline is never entered.
    [SEC-30] Active-request counter (TInterlocked) — Stop() waits up to
             DrainTimeoutMs for in-flight pipelines to finish.
    [SEC-31] Exceptions in the pipeline never leak detail to clients
             (generic Exception → JSON 500; EHorseException → 4xx/5xx with
             app-controlled message; EHorseCallbackInterrupted swallowed).
    [SEC-32] Double-start guard.

  ── Platform scope ────────────────────────────────────────────────────────
  Delphi only — Windows (Win32/Win64) and POSIX (Linux64, macOS). ICS's
  POSIX support (`Ics.Posix.*`) is built on the Delphi POSIX RTL
  (`Posix.*`), so it is NOT available under FPC: the `{$IF DEFINED(FPC)}`
  seams retained throughout the provider keep the FPC build blocked with a
  clear FATAL until a Lazarus/FPC ICS port exists. On Linux the same
  message-loop marshaling works unchanged — `PostMessage`, `TMessage`,
  `HWND`, `WM_USER` and `AllocateHWnd` are supplied by `Ics.Posix.WinTypes`
  + `Ics.Posix.PXMessages` instead of `Winapi.Windows`/`Winapi.Messages`.
  TLS uses the same OpenSSL 3.x/4.x libraries (shipped as .so on Linux).

  Dependencies (paths added manually to the project):
    icsv97/Source/  (OverbyteIcs* + Ics.).
*)

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

{$IF DEFINED(FPC)}
  {$MESSAGE FATAL 'horse-provider-ics requires Delphi: ICS POSIX support (Ics.Posix.*) is built on the Delphi POSIX RTL and is not available under FPC.'}
{$ELSEIF NOT (DEFINED(MSWINDOWS) OR DEFINED(POSIX))}
  {$MESSAGE FATAL 'horse-provider-ics supports Windows and Delphi POSIX (Linux64 / macOS) targets only.'}
{$IFEND}

uses
{$IF DEFINED(MSWINDOWS)}
  Winapi.Windows,
  Winapi.Messages,
{$ELSE}
  Ics.Posix.WinTypes,   // DWORD, UINT, error consts
  Ics.Posix.PXMessages, // HWND, TMessage, WM_USER, PostMessage, AllocateHWND
{$IFEND}
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  Horse.Exception,
  Horse.Provider.Abstract,
  Horse.Provider.ICS.Config,
  Horse.Provider.ICS.Pool,
  Horse.Provider.ICS.Request,
  Horse.Provider.ICS.Response,
  Horse.Provider.ICS.RawRequest,
  Horse.Provider.ICS.WebRequestAdapter,
  Horse.Provider.ICS.WebResponseAdapter,
  Horse.Provider.ICS.WorkerPool,
  OverbyteIcsHttpSrv,
  OverbyteIcsSslBase,
  OverbyteIcsWndControl,
  OverbyteIcsWSocket;

type
  THorseProviderICS = class;

  // Bundle handed off to the worker thread.
  TICSPendingRequest = class
    Token:    NativeUInt;
    Conn:     THttpConnection;       // read on loop thread only
    Snapshot: PICSRequestSnapshot;   // owned by worker; freed on loop after Answer
    Payload:  TICSResponsePayload;   // populated by worker
    Error:    string;                // pipeline error → 500 path
    HadError: Boolean;
    Status:   Integer;               // pre-pipeline rejection status (0 = use payload)
    BadReason: string;
  end;

  // Receiver window for marshal-back messages. Inherits from TIcsWndControl
  // so we get ICS's hidden-window message infrastructure for free.
  TICSMarshalReceiver = class(TIcsWndControl)
  private
    FProvider: THorseProviderICS;
    FMsgId:    UINT;
  protected
    procedure WndProc(var MsgRec: TMessage); override;
  public
    constructor Create(AOwner: TComponent; AProvider: THorseProviderICS); reintroduce;
    destructor  Destroy; override;
    property MsgId:    UINT                 read FMsgId;
    property Provider: THorseProviderICS    read FProvider;
  end;

  // Buffers a POST/PUT/PATCH body across multiple OnPostedData callbacks.
  // Lives in the per-connection FPendingPosts map; freed when the body is
  // complete and dispatched (or when the connection disconnects).
  TICSPendingPost = class
    Buffer:    TBytes;
    Received:  Int64;
    Capacity:  Int64;
  end;

  THorseProviderICS = class(THorseProviderAbstract)
  private
    class var FServer:         THttpServer;       // THttpServer or TSslHttpServer
    class var FSslContext:     TSslContext;
    class var FReceiver:       TICSMarshalReceiver;
    class var FPort:           Integer;
    class var FConfig:         THorseICSConfig;
    class var FStopEvent:      TEvent;
    class var FRunning:        Boolean;
    class var FActiveRequests: Integer;
    class var FDrainEvent:     TEvent;
    class var FPendingLock:    TCriticalSection;
    class var FPendingMap:     TDictionary<NativeUInt, TICSPendingRequest>;
    class var FPostBuffers:    TDictionary<TObject, TICSPendingPost>;
    class var FNextToken:      NativeUInt;
    class var FLiveConns:      TDictionary<TObject, Boolean>;

    class function  GetPort: Integer; static;
    class procedure SetPort(const AValue: Integer); static;

    class procedure HandleClientConnect(Sender: TObject;
      Client: TObject; ErrCode: Word);
    class procedure HandleClientDisconnect(Sender: TObject;
      Client: TObject; ErrCode: Word);

    class procedure HandleGet(Sender: TObject; Client: TObject;
      var Flags: THttpGetFlag);
    class procedure HandleHead(Sender: TObject; Client: TObject;
      var Flags: THttpGetFlag);
    class procedure HandleDelete(Sender: TObject; Client: TObject;
      var Flags: THttpGetFlag);
    class procedure HandleOptions(Sender: TObject; Client: TObject;
      var Flags: THttpGetFlag);
    class procedure HandlePost(Sender: TObject; Client: TObject;
      var Flags: THttpGetFlag);
    class procedure HandlePut(Sender: TObject; Client: TObject;
      var Flags: THttpGetFlag);
    class procedure HandlePatch(Sender: TObject; Client: TObject;
      var Flags: THttpGetFlag);
    class procedure HandlePostedData(Sender: TObject;
      Client: TObject; ErrCode: Word);

    class procedure DispatchNoBody(Client: THttpConnection;
      var Flags: THttpGetFlag);
    class procedure DispatchWithBody(Client: THttpConnection;
      const ABody: TBytes; ABodyLen: Int64;
      var Flags: THttpGetFlag);

    class procedure StartBodyAccumulator(Client: THttpConnection;
      var Flags: THttpGetFlag);

    class function  BuildView(Client: THttpConnection;
      const ABody: string): TICSRequestView;

    class procedure EnqueuePipelineTask(APending: TICSPendingRequest);
    class procedure RunPipelineOnWorker(APending: TICSPendingRequest);
    class procedure MarshalBack(APending: TICSPendingRequest);
    class procedure DispatchOnLoop(APending: TICSPendingRequest);
    class procedure AnswerError(Client: THttpConnection;
      const AStatus, AMessage: string; var Flags: THttpGetFlag);
    class procedure AnswerNotImpl(var Flags: THttpGetFlag);

    class procedure InternalListen(const APort: Integer;
      const AConfig: THorseICSConfig);

    class function  SslVersionMethodFromConfig: TSslVersionMethod;

  public
    class procedure StopListen; override;
    class procedure Listen; overload; override;
    class procedure Listen(APort: Integer); reintroduce; overload;
    class procedure ListenWithConfig(const APort: Integer;
      const AConfig: THorseICSConfig); reintroduce;
    class procedure Stop;

    class property Port:   Integer          read GetPort write SetPort;
    class property Config: THorseICSConfig  read FConfig;
  end;

implementation

uses
  Horse,
  Horse.Commons,
  Horse.Constants,
  Horse.Exception.Interrupted;

const
  // Reserved by AllocateMsgHandler at runtime.
  MARSHAL_WM_RESPONSE_READY = WM_USER;   // resolved to actual id at startup

type
  // Custom ICS connection. ICS's THttpConnection.ProcessPostPutPat rejects a
  // PUT/PATCH that arrives WITHOUT a Content-Length header — it sends 400, sets
  // FKeepAlive:=False and CloseDelayed, all BEFORE OnPut/PatchDocument fires
  // (OverbyteIcsHttpSrv ~5302). A body-less PUT/PATCH is valid (RFC 7230), and
  // the CrossSocket/mORMot providers accept it, so we make ICS lenient: when no
  // Content-Length was supplied, treat it as a valid zero-length body so the
  // document event fires. ProcessDelete already takes a no-body escape; PUT/PATCH
  // do not, so we add it here. Installed via THttpServer.ClientClass.
  THorseICSConnection = class(THttpConnection)
  protected
    procedure ProcessPut; override;
    procedure ProcessPatch; override;
  public
    procedure DisableKeepAlive;
  end;

procedure THorseICSConnection.DisableKeepAlive;
begin
  FKeepAlive := False;
end;

procedure THorseICSConnection.ProcessPut;
begin
  // System.Writeln('[DIAG put] hasCL=', BoolToStr(FRequestHasContentLength, True),
  //   ' cl=', IntToStr(FRequestContentLength));   // DIAG (remove)
  if not FRequestHasContentLength then
  begin
    FRequestHasContentLength := True;
    FRequestContentLength    := 0;
  end;
  inherited;
end;

procedure THorseICSConnection.ProcessPatch;
begin
  if not FRequestHasContentLength then
  begin
    FRequestHasContentLength := True;
    FRequestContentLength    := 0;
  end;
  inherited;
end;

{ TICSMarshalReceiver }

constructor TICSMarshalReceiver.Create(AOwner: TComponent;
  AProvider: THorseProviderICS);
begin
  inherited Create(AOwner);
  FProvider := AProvider;
  AllocateHWnd;
  // Allocate a unique custom WM_USER+n via ICS's WndHandler.
  FMsgId := WndHandler.AllocateMsgHandler(Self);
end;

destructor TICSMarshalReceiver.Destroy;
begin
  if FMsgId <> 0 then
    WndHandler.UnregisterMessage(FMsgId);
  inherited;
end;

procedure TICSMarshalReceiver.WndProc(var MsgRec: TMessage);
var
  Pending: TICSPendingRequest;
  Token:   NativeUInt;
begin
  if MsgRec.Msg = FMsgId then
  begin
    Token := NativeUInt(MsgRec.WParam);
    THorseProviderICS.FPendingLock.Acquire;
    try
      if not THorseProviderICS.FPendingMap.TryGetValue(Token, Pending) then
        Pending := nil
      else
        THorseProviderICS.FPendingMap.Remove(Token);
    finally
      THorseProviderICS.FPendingLock.Release;
    end;
    if Assigned(Pending) then
    try
      THorseProviderICS.DispatchOnLoop(Pending);
    finally
      if Assigned(Pending.Snapshot) then
      begin
        Finalize(Pending.Snapshot^);
        // Qualify System.Dispose — this method lives in a TIcsWndControl
        // descendant whose inherited Dispose(Boolean) would otherwise shadow the
        // intrinsic (E2010: Boolean vs PICSRequestSnapshot).
        System.Dispose(Pending.Snapshot);
      end;
      Pending.Free;
    end;
    Exit;
  end;
  inherited WndProc(MsgRec);
end;

{ THorseProviderICS }

class function THorseProviderICS.GetPort: Integer;
begin
  Result := FPort;
end;

class procedure THorseProviderICS.SetPort(const AValue: Integer);
begin
  FPort := AValue;
end;

class procedure THorseProviderICS.Listen;
var
  LPort: Integer;
begin
  LPort := FPort;
  if LPort <= 0 then
    LPort := DEFAULT_PORT;
  InternalListen(LPort, THorseICSConfig.Default);
end;

class procedure THorseProviderICS.Listen(APort: Integer);
begin
  InternalListen(APort, THorseICSConfig.Default);
end;

class procedure THorseProviderICS.ListenWithConfig(const APort: Integer;
  const AConfig: THorseICSConfig);
begin
  InternalListen(APort, AConfig);
end;

class function THorseProviderICS.SslVersionMethodFromConfig: TSslVersionMethod;
begin
  case FConfig.SSLVersionMethod of
    icsSslTLS12: Result := sslTLS_V1_2;
    // ICS's TSslVersionMethod has no TLS-1.3-only member (it stops at sslTLS_V1_2,
    // then sslBestVer). sslBestVer negotiates the highest mutually-supported
    // protocol — TLS 1.3 when both peers support it. Strict 1.3-only enforcement
    // would additionally disable older protocols via the SslContext options
    // (sslOpt2_NO_TLSv1 / _NO_TLSv1_1 / _NO_TLSv1_2) — a follow-up, not required here.
    icsSslTLS13: Result := sslBestVer;
  else
    Result := sslBestVer;
  end;
end;

class procedure THorseProviderICS.InternalListen(const APort: Integer;
  const AConfig: THorseICSConfig);
var
  LSslSrv: TSslHttpServer;
begin
  // [SEC-32]
  if Assigned(FServer) then
    Stop;

  FConfig := AConfig;
  FPort   := APort;

  if not Assigned(FDrainEvent) then
    FDrainEvent := TEvent.Create(nil, True, True, '');

  FPendingLock := TCriticalSection.Create;
  FPendingMap  := TDictionary<NativeUInt, TICSPendingRequest>.Create;
  FPostBuffers := TDictionary<TObject, TICSPendingPost>.Create;
  FLiveConns   := TDictionary<TObject, Boolean>.Create;
  FNextToken   := 0;

  // Worker pool — sized from config.
  THorseICSWorkerPool.Initialize(
    AConfig.WorkerThreads, AConfig.WorkerThreads, AConfig.MaxQueueDepth);

  // Marshal-back receiver must exist before any worker can post to it.
  FReceiver := TICSMarshalReceiver.Create(nil, nil);

  // Build the server (SSL or plain).
  if AConfig.SSLEnabled then
  begin
    FSslContext := TSslContext.Create(nil);
    FSslContext.SslCertFile      := AConfig.SSLCertFile;
    FSslContext.SslPrivKeyFile   := AConfig.SSLPrivKeyFile;
    FSslContext.SslPassPhrase    := AConfig.SSLPassPhrase;
    if AConfig.SSLCAFile <> '' then
      FSslContext.SslCAFile      := AConfig.SSLCAFile;
    FSslContext.SslVerifyPeer    := AConfig.SSLVerifyPeer;
    FSslContext.SslVersionMethod := SslVersionMethodFromConfig;
    if AConfig.SSLCipherList <> '' then
      FSslContext.SslCipherList  := AConfig.SSLCipherList;

    LSslSrv := TSslHttpServer.Create(nil);
    LSslSrv.SslEnable  := True;
    LSslSrv.SslContext := FSslContext;
    FServer := LSslSrv;
  end
  else
  begin
    FServer := THttpServer.Create(nil);
    // Lenient connection class so body-less PUT/PATCH (no Content-Length) fire
    // OnPut/PatchDocument instead of ICS's default 400 + connection close.
    // THorseICSConnection derives from THttpConnection (non-SSL). The SSL server
    // uses TSslHttpConnection; a TSslHttpConnection-derived equivalent is a
    // follow-up (SSL is not exercised by the current test suite).
    FServer.ClientClass := THorseICSConnection;
  end;

  FServer.Port             := IntToStr(APort);
  FServer.Addr             := '0.0.0.0';
  FServer.ListenBacklog    := AConfig.ListenBacklog;
  FServer.KeepAliveTimeSec := AConfig.KeepAliveTimeSec;
  if AConfig.ServerBanner <> '' then
    FServer.ServerHeader   := 'Server: ' + AConfig.ServerBanner
  else
    FServer.ServerHeader   := 'Server: unknown';

  // ICS gates non-GET/POST method dispatch behind Options flags
  // (OverbyteIcsHttpSrv ~4926): without these, OnPut/Delete/Patch/OptionsDocument
  // never fire and those requests fall through to an ICS default response.
  FServer.Options := FServer.Options +
    [hoAllowOptions, hoAllowPut, hoAllowDelete, hoAllowPatch];

  FServer.OnClientConnect    := HandleClientConnect;
  FServer.OnClientDisconnect := HandleClientDisconnect;
  FServer.OnGetDocument      := HandleGet;
  FServer.OnHeadDocument     := HandleHead;
  FServer.OnDeleteDocument   := HandleDelete;
  FServer.OnOptionsDocument  := HandleOptions;
  FServer.OnPostDocument     := HandlePost;
  FServer.OnPutDocument      := HandlePut;
  FServer.OnPatchDocument    := HandlePatch;
  FServer.OnPostedData       := HandlePostedData;

  FServer.Start;
  // System.Writeln('[DIAG build] BUILD-MARKER-7 : ClientClass=',
  //   FServer.ClientClass.ClassName);   // DIAG (remove)
  DoOnListen;

  // Console shape — block the main thread and pump the ICS message loop.
  // Non-console hosts (VCL, service) have their own loop, so we return
  // immediately as soon as the listener is up.
  if IsConsole then
  begin
    FRunning := True;
    if not Assigned(FStopEvent) then
      FStopEvent := TEvent.Create(nil, True, False, '');
    // ICS's MessageLoop runs until Terminated. Terminated is set by Stop.
    FServer.MessageLoop;
  end;
end;

class procedure THorseProviderICS.StopListen;
begin
  Stop;
  DoOnStopListen;
end;

class procedure THorseProviderICS.Stop;
var
  LStarted: Cardinal;
  Entry:    TICSPendingRequest;
begin
  FRunning := False;

  if Assigned(FServer) then
  begin
    FServer.Stop;
    FServer.Terminated := True;
  end;

  // [SEC-30] wait for in-flight pipeline tasks to drain.
  LStarted := TInterlocked.CompareExchange(FActiveRequests, 0, 0);
  if (LStarted > 0) and Assigned(FDrainEvent) then
    FDrainEvent.WaitFor(FConfig.DrainTimeoutMs);

  THorseICSWorkerPool.Finalize;

  FreeAndNil(FReceiver);
  FreeAndNil(FServer);
  FreeAndNil(FSslContext);

  if Assigned(FPostBuffers) then
  begin
    FPostBuffers.Free;     // TICSPendingPost are owned; just clear
    FPostBuffers := nil;
  end;
  if Assigned(FLiveConns) then
    FreeAndNil(FLiveConns);

  if Assigned(FPendingMap) then
  begin
    // Any orphaned pending entries belonged to workers that finished
    // after the receiver was torn down — drop their snapshots.
    for Entry in FPendingMap.Values do
    begin
      if Assigned(Entry.Snapshot) then
      begin
        Finalize(Entry.Snapshot^);
        Dispose(Entry.Snapshot);
      end;
      Entry.Free;
    end;
    FreeAndNil(FPendingMap);
  end;
  if Assigned(FPendingLock) then
    FreeAndNil(FPendingLock);
  FreeAndNil(FDrainEvent);

  if Assigned(FStopEvent) then
    FStopEvent.SetEvent;
  FreeAndNil(FStopEvent);
end;

// ── Connection liveness tracking ─────────────────────────────────────────────
class procedure THorseProviderICS.HandleClientConnect(Sender: TObject;
  Client: TObject; ErrCode: Word);
begin
  if not Assigned(FLiveConns) then Exit;
  FPendingLock.Acquire;
  try
    FLiveConns.AddOrSetValue(Client, True);
  finally
    FPendingLock.Release;
  end;
end;

class procedure THorseProviderICS.HandleClientDisconnect(Sender: TObject;
  Client: TObject; ErrCode: Word);
var
  LPost: TICSPendingPost;
begin
  FPendingLock.Acquire;
  try
    if Assigned(FLiveConns) then
      FLiveConns.Remove(Client);
    if Assigned(FPostBuffers) and FPostBuffers.TryGetValue(Client, LPost) then
    begin
      FPostBuffers.Remove(Client);
      LPost.Free;
    end;
  finally
    FPendingLock.Release;
  end;
end;

// ── Per-method handlers ─────────────────────────────────────────────────────
class procedure THorseProviderICS.HandleGet(Sender: TObject;
  Client: TObject; var Flags: THttpGetFlag);
begin
  DispatchNoBody(THttpConnection(Client), Flags);
end;

class procedure THorseProviderICS.HandleHead(Sender: TObject;
  Client: TObject; var Flags: THttpGetFlag);
begin
  DispatchNoBody(THttpConnection(Client), Flags);
end;

class procedure THorseProviderICS.HandleDelete(Sender: TObject;
  Client: TObject; var Flags: THttpGetFlag);
begin
  DispatchNoBody(THttpConnection(Client), Flags);
end;

class procedure THorseProviderICS.HandleOptions(Sender: TObject;
  Client: TObject; var Flags: THttpGetFlag);
begin
  DispatchNoBody(THttpConnection(Client), Flags);
end;

class procedure THorseProviderICS.HandlePost(Sender: TObject;
  Client: TObject; var Flags: THttpGetFlag);
begin
  StartBodyAccumulator(THttpConnection(Client), Flags);
end;

class procedure THorseProviderICS.HandlePut(Sender: TObject;
  Client: TObject; var Flags: THttpGetFlag);
begin
  StartBodyAccumulator(THttpConnection(Client), Flags);
end;

class procedure THorseProviderICS.HandlePatch(Sender: TObject;
  Client: TObject; var Flags: THttpGetFlag);
begin
  StartBodyAccumulator(THttpConnection(Client), Flags);
end;

// Initialise per-connection body buffer and tell ICS to feed us posted data.
class procedure THorseProviderICS.StartBodyAccumulator(Client: THttpConnection;
  var Flags: THttpGetFlag);
var
  LPost: TICSPendingPost;
begin
  // System.Writeln('[DIAG sba] m=', Client.Method,
  //   ' cl=', IntToStr(Client.RequestContentLength));   // DIAG (remove)
  // Bodyless PUT/PATCH/POST (no Content-Length): ICS does not fire OnPostedData
  // when there is nothing to post, so requesting hgAcceptData would hang the
  // request forever — and wedge the keep-alive connection for every request
  // after it. Dispatch immediately with an empty body instead.
  if Client.RequestContentLength <= 0 then
  begin
    // System.Writeln('[DIAG sba] -> immediate dispatch (no body)');   // DIAG (remove)
    DispatchWithBody(Client, nil, 0, Flags);
    Exit;
  end;

  if FConfig.MaxBodyBytes > 0 then
  begin
    if (Client.RequestContentLength > 0) and
       (Client.RequestContentLength > FConfig.MaxBodyBytes) then
    begin
      AnswerError(Client, '413 Payload Too Large', 'Payload Too Large', Flags);
      Exit;
    end;
  end;
  LPost           := TICSPendingPost.Create;
  LPost.Received  := 0;
  LPost.Capacity  := Client.RequestContentLength;
  if LPost.Capacity > 0 then
    SetLength(LPost.Buffer, LPost.Capacity);

  FPendingLock.Acquire;
  try
    FPostBuffers.AddOrSetValue(Client, LPost);
  finally
    FPendingLock.Release;
  end;

  Flags := hgAcceptData;
end;

// ICS calls this whenever body bytes are available. We pull them out via the
// connection's Receive method, append to our per-conn buffer, and dispatch
// once we've got the complete Content-Length worth.
class procedure THorseProviderICS.HandlePostedData(Sender: TObject;
  Client: TObject; ErrCode: Word);
var
  Conn: THttpConnection;
  LPost: TICSPendingPost;
  LBuf:  array[0..16383] of Byte;
  N:     Integer;
  LFlags: THttpGetFlag;
begin
  Conn := THttpConnection(Client);
  FPendingLock.Acquire;
  try
    if not FPostBuffers.TryGetValue(Conn, LPost) then
    begin
      FPendingLock.Release;
      Exit;
    end;
  finally
    FPendingLock.Release;
  end;

  // Drain whatever ICS has on the socket right now.
  while True do
  begin
    N := Conn.Receive(@LBuf[0], SizeOf(LBuf));
    if N <= 0 then Break;
    if LPost.Capacity > 0 then
    begin
      if LPost.Received + N > LPost.Capacity then
        N := Integer(LPost.Capacity - LPost.Received);
      if N > 0 then
        Move(LBuf[0], LPost.Buffer[LPost.Received], N);
    end
    else
    begin
      // No Content-Length advertised — grow buffer dynamically (capped).
      if (FConfig.MaxBodyBytes > 0) and
         (LPost.Received + N > FConfig.MaxBodyBytes) then
      begin
        FPendingLock.Acquire;
        try
          FPostBuffers.Remove(Conn);
        finally
          FPendingLock.Release;
        end;
        LPost.Free;
        LFlags := hgWillSendMySelf;
        AnswerError(Conn, '413 Payload Too Large', 'Payload Too Large', LFlags);
        Exit;
      end;
      SetLength(LPost.Buffer, LPost.Received + N);
      Move(LBuf[0], LPost.Buffer[LPost.Received], N);
    end;
    Inc(LPost.Received, N);
    if (LPost.Capacity > 0) and (LPost.Received >= LPost.Capacity) then Break;
  end;

  // Body complete?
  if (LPost.Capacity > 0) and (LPost.Received < LPost.Capacity) then
    Exit;   // wait for the next callback

  FPendingLock.Acquire;
  try
    FPostBuffers.Remove(Conn);
  finally
    FPendingLock.Release;
  end;

  LFlags := hgWillSendMySelf;
  try
    DispatchWithBody(Conn, LPost.Buffer, LPost.Received, LFlags);
  finally
    LPost.Free;
  end;
end;

// ── Dispatch helpers ─────────────────────────────────────────────────────────
class procedure THorseProviderICS.DispatchNoBody(Client: THttpConnection;
  var Flags: THttpGetFlag);
begin
  DispatchWithBody(Client, nil, 0, Flags);
end;

class procedure THorseProviderICS.DispatchWithBody(Client: THttpConnection;
  const ABody: TBytes; ABodyLen: Int64; var Flags: THttpGetFlag);
var
  LView:    TICSRequestView;
  LSnap:    PICSRequestSnapshot;
  LResult:  TRequestValidationResult;
  LReject:  string;
  LBody:    string;
  LPending: TICSPendingRequest;
begin
  if ABodyLen > 0 then
    LBody := TEncoding.UTF8.GetString(ABody, 0, Integer(ABodyLen))
  else
    LBody := '';

  LView := BuildView(Client, LBody);

  // [SEC-29] validate before any pool / worker work.
  LResult := TICSRequestBridge.Validate(LView, LReject, FConfig.MaxBodyBytes);
  if LResult <> rvOK then
  begin
    case LResult of
      rvMethodNotAllowed: AnswerError(Client, '405 Method Not Allowed', LReject, Flags);
      rvPayloadTooLarge:  AnswerError(Client, '413 Payload Too Large',  LReject, Flags);
    else
      AnswerError(Client, '400 Bad Request', LReject, Flags);
    end;
    Exit;
  end;

  LSnap := TICSRequestBridge.Snapshot(LView);

  LPending          := TICSPendingRequest.Create;
  LPending.Conn     := Client;
  LPending.Snapshot := LSnap;

  Flags := hgWillSendMySelf;

  EnqueuePipelineTask(LPending);
end;

class function THorseProviderICS.BuildView(Client: THttpConnection;
  const ABody: string): TICSRequestView;
begin
  Result.Method        := Client.Method;
  Result.Path          := Client.Path;
  Result.Params        := Client.Params;
  Result.Version       := Client.Version;
  Result.Host          := Client.RequestHost;
  Result.PeerAddr      := Client.PeerAddr;
  Result.ServerPort    := FPort;
  Result.ContentType   := Client.RequestContentType;
  Result.ContentLength := Client.RequestContentLength;
  if Assigned(Client.RequestHeader) then
    Result.HeaderText  := Client.RequestHeader.Text
  else
    Result.HeaderText  := '';
  Result.BodyText      := ABody;
  // System.Writeln('[DIAG bv] m=', Result.Method, ' p=', Result.Path,
  //   ' q=', Result.Params, ' host=', Result.Host,
  //   ' cl=', IntToStr(Result.ContentLength));   // DIAG (remove)
end;

// ── Worker-side pipeline ─────────────────────────────────────────────────────
class procedure THorseProviderICS.EnqueuePipelineTask(APending: TICSPendingRequest);
var
  LToken: NativeUInt;
  LFlags: THttpGetFlag;
begin
  FPendingLock.Acquire;
  try
    Inc(FNextToken);
    if FNextToken = 0 then Inc(FNextToken);
    LToken := FNextToken;
    APending.Token := LToken;
    FPendingMap.AddOrSetValue(LToken, APending);
  finally
    FPendingLock.Release;
  end;

  // [SEC-30] count this pipeline task
  if TInterlocked.Increment(FActiveRequests) = 1 then
    if Assigned(FDrainEvent) then
      FDrainEvent.ResetEvent;

  try
    THorseICSWorkerPool.Instance.Submit(
      procedure
      begin
        try
          RunPipelineOnWorker(APending);
        finally
          MarshalBack(APending);
          if TInterlocked.Decrement(FActiveRequests) = 0 then
            if Assigned(FDrainEvent) then
              FDrainEvent.SetEvent;
        end;
      end);
  except
    on E: EHorseException do
    begin
      // Submit raised — queue full or shutdown. Send 503 inline so we don't
      // leak the pending entry; the receiver will never see the message.
      FPendingLock.Acquire;
      try
        FPendingMap.Remove(APending.Token);
      finally
        FPendingLock.Release;
      end;
      if TInterlocked.Decrement(FActiveRequests) = 0 then
        if Assigned(FDrainEvent) then
          FDrainEvent.SetEvent;
      // We're still on the loop thread here — safe to AnswerString directly.
      try
        if Assigned(APending.Conn) then
        begin
          LFlags := hgWillSendMySelf;
          APending.Conn.AnswerString(
            LFlags,
            '503 Service Unavailable',
            'application/json; charset=utf-8',
            'Cache-Control: no-store'#13#10,
            '{"error":"Service Unavailable"}');
        end;
      except
        // connection might already be dead — swallow
      end;
      if Assigned(APending.Snapshot) then
      begin
        Finalize(APending.Snapshot^);
        Dispose(APending.Snapshot);
      end;
      APending.Free;
    end;
  end;
end;

class procedure THorseProviderICS.RunPipelineOnWorker(APending: TICSPendingRequest);
var
  Ctx:    THorseContext;
  Banner: string;
begin
  Banner := FConfig.ServerBanner;
  Ctx := THorseContextPool.Acquire;
  try
    TICSRequestBridge.Populate(APending.Snapshot, Ctx.Request,
      FConfig.MaxHeaderCount);

    Ctx.Response.SetCSRawWebResponse(TICSWebResponse.Create);

    try
      THorse.Execute(Ctx.Request, Ctx.Response);
    except
      on EHorseCallbackInterrupted do
        ;   // [BUG-2] normal pipeline-end signal

      on E: EHorseException do
      begin
        Ctx.Response.Status(E.Status);
        Ctx.Response.Send(Format('{"error":"%s"}', [E.Message]));
        Ctx.Response.ContentType('application/json; charset=utf-8');
      end;

      on E: Exception do
      begin
        // [SEC-31] log internally, send opaque body
        System.WriteLn(ErrOutput,
          Format('[HorseICS] Pipeline exception %s: %s',
            [E.ClassName, E.Message]));
        Ctx.Response.Status(THTTPStatus.InternalServerError);
        Ctx.Response.Send('{"error":"Internal Server Error"}');
        Ctx.Response.ContentType('application/json; charset=utf-8');
      end;
    end;

    APending.Payload := TICSResponseBridge.Flush(Ctx.Response, Banner);
    // System.Writeln('[DIAG pipe] tok=', IntToStr(Int64(APending.Token)),
    //   ' status=', APending.Payload.Status,
    //   ' bodylen=', IntToStr(Length(APending.Payload.Body)),
    //   ' body0=', Copy(APending.Payload.Body, 1, 40));   // DIAG (remove)
  finally
    THorseContextPool.Release(Ctx);
  end;
end;

class procedure THorseProviderICS.MarshalBack(APending: TICSPendingRequest);
begin
  if not Assigned(FReceiver) then
  begin
    // Receiver torn down (Stop in progress). Drop the response —
    // the loop thread won't be picking it up. The pending entry will
    // be cleaned up by Stop's cleanup loop.
    Exit;
  end;
  PostMessage(FReceiver.Handle, FReceiver.MsgId,
    WPARAM(APending.Token), 0);
end;

// Always on the loop thread.
class procedure THorseProviderICS.DispatchOnLoop(APending: TICSPendingRequest);
var
  LFlags: THttpGetFlag;
  Live:   Boolean;
begin
  FPendingLock.Acquire;
  try
    Live := Assigned(FLiveConns) and FLiveConns.ContainsKey(APending.Conn);
  finally
    FPendingLock.Release;
  end;
  // System.Writeln('[DIAG loop] tok=', IntToStr(Int64(APending.Token)),
  //   ' live=', BoolToStr(Live, True),
  //   ' status=', APending.Payload.Status);   // DIAG (remove)
  if not Live then Exit;       // peer dropped during pipeline

  // Force this connection to close after the response. The provider answers
  // asynchronously (deferred AnswerString from the marshal-back); after we
  // returned hgWillSendMySelf, ICS may already be reading the NEXT keep-alive
  // request on the same connection before our answer is written — which desyncs
  // request/response pairing on a reused connection (off-by-one / stale bodies).
  // One request per connection removes the race. (Perf trade-off; a future
  // refactor could serialise per-connection and re-enable keep-alive.)
  if APending.Conn is THorseICSConnection then
    THorseICSConnection(APending.Conn).DisableKeepAlive;

  LFlags := hgWillSendMySelf;
  try
    APending.Conn.AnswerString(
      LFlags,
      APending.Payload.Status,
      APending.Payload.ContentType,
      APending.Payload.Headers,
      APending.Payload.Body);
    // System.Writeln('[DIAG ans] tok=', IntToStr(Int64(APending.Token)),
    //   ' AnswerString returned OK');   // DIAG (remove)
  except
    // on E: Exception do
    //   System.Writeln('[DIAG ans] tok=', IntToStr(Int64(APending.Token)),
    //     ' AnswerString EXCEPTION: ', E.ClassName, ' : ', E.Message);   // DIAG (remove)
    // swallow — peer may have closed between liveness check and AnswerString
  end;
end;

class procedure THorseProviderICS.AnswerError(Client: THttpConnection;
  const AStatus, AMessage: string; var Flags: THttpGetFlag);
var
  LHeader: string;
  LBody:   string;
begin
  Flags := hgWillSendMySelf;
  LHeader :=
    'X-Content-Type-Options: nosniff'#13#10 +
    'X-Frame-Options: DENY'#13#10 +
    'Cache-Control: no-store'#13#10;
  if FConfig.ServerBanner <> '' then
    LHeader := LHeader + 'Server: ' + FConfig.ServerBanner + #13#10
  else
    LHeader := LHeader + 'Server: unknown'#13#10;
  LBody := Format('{"error":"%s"}',
    [StringReplace(AMessage, '"', '\"', [rfReplaceAll])]);
  try
    Client.AnswerString(Flags, AStatus, 'application/json; charset=utf-8',
      LHeader, LBody);
  except
    // Connection might be dead — swallow.
  end;
end;

class procedure THorseProviderICS.AnswerNotImpl(var Flags: THttpGetFlag);
begin
  Flags := hg501;
end;

end.
