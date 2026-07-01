unit Horse.Provider.ICS.WebResponseAdapter;

(*
  Horse ICS Provider - TWebResponse / TResponse adapter
  -----------------------------------------------------
  Thin subclass of TInterfacedWebResponse. There is nothing per-request to
  hold onto — TICSResponseBridge.Flush reads the populated THorseResponse
  directly when it builds the AnswerString arguments — so the constructor
  takes no parameters beyond creating a TICSRawResponse stub.

  TICSWebResponse is the type stored in THorseResponse.FCSRawWebResponse
  via PATCH-RES-6. Middleware that writes to Res.RawWebResponse.Content or
  calls SetCustomHeader (e.g. Horse.CORS, horse-jhonson) lands in the
  inherited TInterfacedWebResponse buffers; the response bridge harvests
  them at flush time (COMPAT-1).

  Dual-compilation: Delphi (FPC seam retained for ICS_Lazarus).
*)

{$IF DEFINED(FPC)}
{$MODE DELPHI}{$H+}
{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
  Classes,
  fpHTTP,
  HTTPDefs,
{$ELSE}
  System.SysUtils,
  System.Classes,
  Web.HTTPApp,
{$ENDIF}
  Horse.Provider.RawInterfaces,
  Horse.Provider.RawAdapters,
  Horse.Provider.ICS.RawResponse;

type
  TICSWebResponse = class(TInterfacedWebResponse)
  public
    constructor Create; reintroduce;
  end;

implementation

constructor TICSWebResponse.Create;
begin
  inherited Create(TICSRawResponse.Create);
end;

end.
