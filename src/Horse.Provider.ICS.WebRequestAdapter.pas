unit Horse.Provider.ICS.WebRequestAdapter;

(*
  Horse ICS Provider - TWebRequest / TRequest adapter
  ---------------------------------------------------
  Thin subclass of TInterfacedWebRequest. The constructor takes a pointer
  to a TICSRequestSnapshot (already produced on the loop thread) and wraps
  it in a TICSRawRequest, which the generic adapter delegates to.

  TICSWebRequest is the type stored in THorseRequest.FCSRawWebRequest via
  PATCH-REQ-8 — middleware like Horse.CORS reads Req.RawWebRequest.* without
  needing to know which provider built it.

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
  Horse.Provider.ICS.RawRequest;

type
  TICSWebRequest = class(TInterfacedWebRequest)
  public
    constructor Create(ASnap: PICSRequestSnapshot); reintroduce;
  end;

implementation

constructor TICSWebRequest.Create(ASnap: PICSRequestSnapshot);
begin
  inherited Create(TICSRawRequest.Create(ASnap));
end;

end.
