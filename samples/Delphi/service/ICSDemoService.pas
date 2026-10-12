unit ICSDemoService;

// ============================================================================
//  Windows Service class for HorseICSServiceDemo.
//
//  Inherits from THorseICSService (Horse.Provider.ICS.Daemon.pas), a TService
//  (Vcl.SvcMgr) that:
//    ServiceStart -> listener thread: THorse.Listen(Port), then pumps
//                    messages for ICS (SVC-PUMP-1)
//    ServiceStop  -> asks that thread to run THorse.StopListen, joins it
//
//  This unit declares no OnStart/OnStop and no GetServiceController, so the
//  sample exercises the base exactly as an application would. The .dfm
//  starts with 'inherited' and the .dpr lists the base unit as
//  {HorseICSService: TService} (SVC-DFM-1).
// ============================================================================

interface

uses
  Winapi.Windows,   // GetCurrentProcessId
  System.SysUtils,
  System.Classes,   // TComponent in the constructor signature
  Vcl.SvcMgr,
  Horse,
  Horse.Provider.ICS.Daemon;

type
  THorseICSDemoSvc = class(THorseICSService)
  public
    // Routes are registered here, not in a unit initialization: CreateForm
    // runs after Application.Initialize, so THorse is ready. A constructor
    // cannot be unwired by the designer the way an OnCreate binding can.
    constructor Create(AOwner: TComponent); override;
  end;

var
  HorseICSDemoSvc: THorseICSDemoSvc;

implementation

{%CLASSGROUP 'System.Classes.TPersistent'}

{$R *.dfm}

const
  DEMO_PORT = 9010;   // same port as the ICS integration test server

// --- Route handlers ---------------------------------------------------------

procedure GetPing(Req: THorseRequest; Res: THorseResponse);
begin
  Res.Send('pong');
end;

procedure GetStatus(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send(Format('{"shape":"windows-service","provider":"ics","port":%d,"pid":%d}',
                  [DEMO_PORT, GetCurrentProcessId]));
end;

// A request body goes through ICS's OnPostedData, the worker pool and the
// marshal back to the listener thread's pump: the whole SVC-PUMP-1 path.
procedure PostEcho(Req: THorseRequest; Res: THorseResponse);
begin
  Res.Send(Req.Body);
end;

// [FIX-ICS-NOCONSOLE probe] GET /diag/raise raises from an onRequest hook, so
// the exception reaches the provider's pipeline catch (a route-level raise is
// answered by Horse itself). Expected: 500 {"error":"Internal Server Error"}.
// Before the fix a service answered "I/O error 105".
procedure DiagRaiseHook(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  if SameText(AReq.PathInfo, '/diag/raise') then
    raise Exception.Create('DIAG-RAISE-DELIBERATE');
  ANext();
end;

procedure GetDiagProvider(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send(Format('{"provider":"%s"}', [THorse.ClassParent.ClassName]));
end;

// --- Service ----------------------------------------------------------------

constructor THorseICSDemoSvc.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);   // base: OnStart/OnStop, GetServiceController
  Port := DEMO_PORT;
  THorse.Get('/ping',   GetPing);
  THorse.Get('/status', GetStatus);
  THorse.Post('/echo',  PostEcho);
  THorse.AddOnRequest(DiagRaiseHook);
  THorse.Get('/diag/provider', GetDiagProvider);
end;

end.
