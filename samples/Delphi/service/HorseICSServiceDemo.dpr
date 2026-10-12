program HorseICSServiceDemo;

// ============================================================================
//  Windows Service demo for horse-provider-ics.
//
//  HORSE_PROVIDER_ICS + HORSE_APPTYPE_DAEMON on Delphi/Windows route to
//  Horse.Provider.ICS.Daemon -> THorseICSService (Vcl.SvcMgr.TService base:
//  a listener thread runs THorse.Listen and pumps ICS's messages).
//
//  Set both defines at PROJECT level as well (Project > Options > Building >
//  Delphi Compiler > Conditional defines): a define in the .dpr does not
//  reach units the compiler already has as .dcu files.
//
//  Install / start / stop / uninstall (elevated prompt):
//    HorseICSServiceDemo.exe /install
//    sc start HorseICSDemoSvc
//    sc query HorseICSDemoSvc
//    curl http://127.0.0.1:9010/ping
//    sc stop HorseICSDemoSvc
//    HorseICSServiceDemo.exe /uninstall
//
//  Full docs: README.md next to this file.
// ============================================================================

{$DEFINE HORSE_PROVIDER_ICS}
{$DEFINE HORSE_APPTYPE_DAEMON}

uses
  Vcl.SvcMgr,
  Horse.Provider.ICS.Daemon in '..\..\..\src\Horse.Provider.ICS.Daemon.pas' {HorseICSService: TService},
  ICSDemoService in 'ICSDemoService.pas' {HorseICSDemoSvc: TService};

{$R *.res}

begin
  if not Vcl.SvcMgr.Application.DelayInitialize or Vcl.SvcMgr.Application.Installing then
    Vcl.SvcMgr.Application.Initialize;
  Vcl.SvcMgr.Application.CreateForm(THorseICSDemoSvc, HorseICSDemoSvc);
  Vcl.SvcMgr.Application.Run;
end.
