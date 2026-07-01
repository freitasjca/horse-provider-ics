unit Horse.Provider.ICS.RawResponse;

(*
  OverbyteICS IHorseRawResponse implementation
  ============================================
  Single-method interface — SetCustomHeader is a no-op here because all
  response headers are written by TICSResponseBridge.Flush, which reads them
  back through THorseResponse.CustomHeaders (PATCH-RES-1/3) and the inherited
  TInterfacedWebResponse.CustomHeaders TStrings (COMPAT-1).

  ICS's AnswerString accepts the complete header block as a single string,
  so deferring all header assembly to Flush keeps the code paths consistent
  with the mORMot provider.

  Dual-compilation: Delphi (FPC seam reserved for ICS_Lazarus).
*)

{$IF DEFINED(FPC)}
{$MODE DELPHI}{$H+}
{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  Horse.Provider.RawInterfaces;

type
  TICSRawResponse = class(TInterfacedObject, IHorseRawResponse)
  public
    { IHorseRawResponse }
    procedure SetCustomHeader(const AName, AValue: string);
  end;

implementation

procedure TICSRawResponse.SetCustomHeader(const AName, AValue: string);
begin
  { No-op — see unit comment. Headers are picked up by TICSResponseBridge.Flush
    from THorseResponse.CustomHeaders and from the inherited TStrings on
    TInterfacedWebResponse. }
end;

end.
