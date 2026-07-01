unit Horse.Provider.ICS.VCL;

(*
  Horse ICS Provider — Delphi VCL composition
  ===========================================
  Selects the ICS transport for a VCL Forms application.

  In a VCL app IsConsole = False, so InternalListen returns as soon as the
  listener is up — ICS's hidden message window plugs into the existing VCL
  message loop, so no separate pump is needed.

  TfrmHorseICSVCLHost is an optional convenience base class that pre-wires
  FormCreate / FormClose to THorse.Listen / THorse.StopListen with a
  configurable Port property. Inherit from it or wire the events manually.
*)

interface

uses
  System.SysUtils,
  System.Classes,
  Vcl.Forms,
  Horse.Provider.ICS;

type
  THorseProviderICSVCL = class(THorseProviderICS);

  TfrmHorseICSVCLHost = class(TForm)
  private
    FPort:          Integer;
    FAutoStart:     Boolean;
    FOnHorseListen: TNotifyEvent;
    FListening:     Boolean;
    procedure DoFormCreate(Sender: TObject);
    procedure DoFormClose(Sender: TObject; var Action: TCloseAction);
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;
    property Port:          Integer      read FPort          write FPort          default 9000;
    property AutoStart:     Boolean      read FAutoStart     write FAutoStart     default True;
    property OnHorseListen: TNotifyEvent read FOnHorseListen write FOnHorseListen;
  end;

implementation

uses
  Horse;

constructor TfrmHorseICSVCLHost.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FPort      := 9000;
  FAutoStart := True;
  OnCreate   := DoFormCreate;
  OnClose    := DoFormClose;
end;

destructor TfrmHorseICSVCLHost.Destroy;
begin
  if FListening then
    THorse.StopListen;
  inherited;
end;

procedure TfrmHorseICSVCLHost.DoFormCreate(Sender: TObject);
begin
  if not FAutoStart then Exit;
  if Assigned(FOnHorseListen) then
    FOnHorseListen(Self);
  THorse.Listen(FPort);
  FListening := True;
end;

procedure TfrmHorseICSVCLHost.DoFormClose(Sender: TObject;
  var Action: TCloseAction);
begin
  if FListening then
  begin
    THorse.StopListen;
    FListening := False;
  end;
end;

end.
