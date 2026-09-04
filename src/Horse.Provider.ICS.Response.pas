unit Horse.Provider.ICS.Response;

(*
  Horse ICS Provider — Response Bridge
  ------------------------------------
  Converts a fully-populated THorseResponse into the four-tuple ICS needs
  to call THttpConnection.AnswerString:
    Status:  '200 OK' (HTTP status line — code + reason phrase)
    ContType:'application/json; charset=utf-8'
    Header:  'X-Content-Type-Options: nosniff'#13#10... (CRLF-delimited;
              NO trailing CRLF and NO Content-Length — ICS adds those)
    Body:    response body string

  ── Prerequisite: Horse fork patches ───────────────────────────────────────
    PATCH-RES-1/3 CustomHeaders
    PATCH-RES-2   Clear
    PATCH-RES-4   BodyText / ContentStream / CSContentType getters,
                  nil-guarded Status getter
    PATCH-RES-6   RawWebResponse (returns FCSRawWebResponse when FWebResponse nil)

  ── Security ────────────────────────────────────────────────────────────────
    [SEC-19] CRLF stripping on all response header values.
    [SEC-20] Hop-by-hop header filtering.
    [SEC-21] Content-Type from shadow field; falls back to COMPAT-1.
    [SEC-22] X-Content-Type-Options: nosniff.
    [SEC-23] X-Frame-Options, Referrer-Policy, Cache-Control.
    [SEC-5]  Server: banner from config (or 'unknown' when blank).

  Dual-compilation: Delphi only in v1.
*)

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  Classes,
  SysUtils,
  Generics.Collections,
{$ELSE}
  System.Classes,
  System.SysUtils,
  System.Generics.Collections,
{$ENDIF}
  Horse.Response,
  Horse.Core.Cookie
{$IF NOT DEFINED(FPC)}
  , Web.HTTPApp
{$ENDIF}
  ;

type
  // The four pieces a worker thread builds for AnswerString. Filled in by
  // TICSResponseBridge.Flush on the worker; consumed on the loop thread
  // when the marshal-back message fires.
  TICSResponsePayload = record
    Status:      string;   // e.g. '200 OK'
    ContentType: string;
    Headers:     string;   // CRLF-delimited, no trailing CRLF
    Body:        string;
  end;

  TICSResponseBridge = class
  public
    class function Flush(
            AHorseRes:       THorseResponse;
      const AServerBanner:   string
    ): TICSResponsePayload;

  private
    class function SanitiseHeaderValue(const AValue: string): string;
    class function IsHopByHopHeader(const AName: string): Boolean;
    class function StatusLine(AStatus: Integer): string;
    class function TryReadBodyStream(AStream: TStream): string;
    class function BuildHeaders(
                            AHorseRes:     THorseResponse;
                      const AServerBanner: string): string;
    class function WriteBody(
                            AHorseRes: THorseResponse;
                            AStatus:   Integer): string;
  end;

implementation

const
  HOP_BY_HOP: array[0..8] of string = (
    'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
    'te', 'trailers', 'transfer-encoding', 'upgrade', 'server'
  );

class function TICSResponseBridge.Flush(
        AHorseRes:     THorseResponse;
  const AServerBanner: string
): TICSResponsePayload;
var
  LStatus: Integer;
  CT:      string;
  LRaw:    {$IF DEFINED(FPC)}TResponse{$ELSE}TWebResponse{$ENDIF};
  LHdrs:   string;
begin
  LStatus := AHorseRes.Status;
  if LStatus = 0 then
    LStatus := 200;
  Result.Status := StatusLine(LStatus);

  // KEEP the trailing CRLF on the header block. ICS's AnswerStream appends
  // exactly ONE more CRLF after this block to form the blank line that ends the
  // headers (RespHeader + Header + IcsCRLF). Each header line — including the
  // last — must therefore stay CRLF-terminated; stripping ours leaves the
  // response with NO header/body separator, so the client never sees the end of
  // the headers and hangs until timeout. Every line BuildHeaders emits already
  // ends in CRLF, which is exactly what ICS expects here.
  Result.Headers := BuildHeaders(AHorseRes, AServerBanner);

  // [SEC-21] Content-Type from shadow field first, fall back to COMPAT-1.
  CT := AHorseRes.CSContentType;
  if CT = '' then
  begin
    LRaw := AHorseRes.RawWebResponse;
    if Assigned(LRaw) then
      CT := LRaw.ContentType;
  end;
  if CT = '' then
    CT := 'text/plain';
  Result.ContentType := CT;

  Result.Body := WriteBody(AHorseRes, LStatus);
end;

class function TICSResponseBridge.SanitiseHeaderValue(const AValue: string): string;
begin
  Result := StringReplace(AValue, #13, '', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '', [rfReplaceAll]);
  Result := StringReplace(Result, #0,  '', [rfReplaceAll]);
end;

class function TICSResponseBridge.IsHopByHopHeader(const AName: string): Boolean;
var
  Lower: string;
  H:     string;
begin
  Lower := LowerCase(AName);
  for H in HOP_BY_HOP do
    if Lower = H then Exit(True);
  Result := False;
end;

class function TICSResponseBridge.StatusLine(AStatus: Integer): string;
begin
  case AStatus of
    100: Result := '100 Continue';
    101: Result := '101 Switching Protocols';
    200: Result := '200 OK';
    201: Result := '201 Created';
    202: Result := '202 Accepted';
    204: Result := '204 No Content';
    301: Result := '301 Moved Permanently';
    302: Result := '302 Found';
    303: Result := '303 See Other';
    304: Result := '304 Not Modified';
    307: Result := '307 Temporary Redirect';
    308: Result := '308 Permanent Redirect';
    400: Result := '400 Bad Request';
    401: Result := '401 Unauthorized';
    403: Result := '403 Forbidden';
    404: Result := '404 Not Found';
    405: Result := '405 Method Not Allowed';
    409: Result := '409 Conflict';
    410: Result := '410 Gone';
    413: Result := '413 Payload Too Large';
    414: Result := '414 URI Too Long';
    415: Result := '415 Unsupported Media Type';
    422: Result := '422 Unprocessable Entity';
    429: Result := '429 Too Many Requests';
    431: Result := '431 Request Header Fields Too Large';
    500: Result := '500 Internal Server Error';
    501: Result := '501 Not Implemented';
    502: Result := '502 Bad Gateway';
    503: Result := '503 Service Unavailable';
    504: Result := '504 Gateway Timeout';
  else
    Result := IntToStr(AStatus) + ' Status';
  end;
end;

class function TICSResponseBridge.BuildHeaders(
        AHorseRes:     THorseResponse;
  const AServerBanner: string
): string;

  procedure EmitHeader(var AOut: string; const AName, AValue: string);
  var
    SafeVal: string;
  begin
    if IsHopByHopHeader(AName) then Exit;            // [SEC-20]
    if (Pos(#13, AName) > 0) or (Pos(#10, AName) > 0) then Exit; // [SEC-19]
    SafeVal := SanitiseHeaderValue(AValue);          // [SEC-19]
    AOut := AOut + AName + ': ' + SafeVal + #13#10;
  end;

var
  LHeaders:   string;
  LRaw:       {$IF DEFINED(FPC)}TResponse{$ELSE}TWebResponse{$ENDIF};
  I:          Integer;
  LName, LVal: string;
  LCookie:    THorseCookie;
  {$IFNDEF FPC}
  LPair:      TPair<string, string>;
  {$ENDIF}
begin
  LHeaders :=
    'X-Content-Type-Options: nosniff'#13#10 +
    'X-Frame-Options: DENY'#13#10 +
    'Referrer-Policy: strict-origin-when-cross-origin'#13#10 +
    'Cache-Control: no-store'#13#10;
  if AServerBanner <> '' then
    LHeaders := LHeaders + 'Server: ' + AServerBanner + #13#10
  else
    LHeaders := LHeaders + 'Server: unknown'#13#10;

  // App-set headers — MERGE-COMPAT (2026-07-18): merged HashLoad/horse types
  // CustomHeaders as TStringList on FPC but TDictionary<string,string> on Delphi;
  // Names[I]/ValueFromIndex[I] only exist on FPC. Split per compiler (was E2003
  // 'Names' building the ICS provider against merged horse).
  if Assigned(AHorseRes.CustomHeaders) then
  begin
    {$IF DEFINED(FPC)}
    for I := 0 to AHorseRes.CustomHeaders.Count - 1 do
    begin
      LName := AHorseRes.CustomHeaders.Names[I];
      LVal  := AHorseRes.CustomHeaders.ValueFromIndex[I];
      { REPEATHDR-1 — skip Set-Cookie here; this shadow store collapses repeats.
        Every occurrence is emitted from RepeatHeaders below instead. }
      if (LName <> '') and not SameText(LName, 'Set-Cookie') then
        EmitHeader(LHeaders, LName, LVal);
    end;
    {$ELSE}
    for LPair in AHorseRes.CustomHeaders do
      if (LPair.Key <> '') and not SameText(LPair.Key, 'Set-Cookie') then
        EmitHeader(LHeaders, LPair.Key, LPair.Value);
    {$ENDIF}
  end;

  // [REPEATHDR-1] Set-Cookie added via Res.AddHeader collapses in CustomHeaders
  // — a TDictionary on Delphi, so only the LAST value survives. Two calls to
  // Res.AddHeader('Set-Cookie', ...) kept the second and silently dropped the
  // first, returning 200 with nothing logged.
  //
  // Horse core (REPEATHDR-1) appends every Set-Cookie verbatim to the ordered
  // RepeatHeaders side-store so adapter providers can emit them all, and
  // deliberately KEEPS the deduped entry above so bridges that have not adopted
  // RepeatHeaders keep working unchanged. That is why the loop above must SKIP
  // Set-Cookie once this loop exists — otherwise the last cookie goes out twice.
  //
  // Independent of the Cookies loop below: that serves the typed Res.Cookie(...)
  // API, this one the raw Res.AddHeader path. Section K exercised only the
  // former, which is why this gap survived undetected.
  if Assigned(AHorseRes.RepeatHeaders) then
    for I := 0 to AHorseRes.RepeatHeaders.Count - 1 do
    begin
      LName := AHorseRes.RepeatHeaders.Names[I];
      LVal  := AHorseRes.RepeatHeaders.ValueFromIndex[I];
      if LName <> '' then
        EmitHeader(LHeaders, LName, LVal);
    end;

  // [COMPAT-1] middleware-set headers via RawWebResponse.SetCustomHeader
  LRaw := AHorseRes.RawWebResponse;
  if Assigned(LRaw) and Assigned(LRaw.CustomHeaders) then
  begin
    for I := 0 to LRaw.CustomHeaders.Count - 1 do
    begin
      LName := LRaw.CustomHeaders.Names[I];
      LVal  := LRaw.CustomHeaders.ValueFromIndex[I];
      if LName <> '' then
        EmitHeader(LHeaders, LName, LVal);
    end;
  end;

  // PATCH-COOKIE-1 — emit one Set-Cookie line per typed cookie (RFC 6265 §3).
  // ICS sends this header block verbatim through AnswerString, so calling
  // EmitHeader('Set-Cookie', ...) once per cookie naturally yields multiple
  // distinct Set-Cookie: lines (no single-value-map folding problem like the
  // CrossSocket/mORMot bridges had). The Set-Cookie value is built and validated
  // by THorseCookie.ToHeaderValue; EmitHeader's SanitiseHeaderValue keeps CRLF
  // stripping as defence-in-depth. Set-Cookie is not hop-by-hop, so it passes.
  if Assigned(AHorseRes.Cookies) then
    for LCookie in AHorseRes.Cookies do
      EmitHeader(LHeaders, 'Set-Cookie', LCookie.ToHeaderValue);

  Result := LHeaders;
end;

class function TICSResponseBridge.TryReadBodyStream(AStream: TStream): string;
var
  LBytes: TBytes;
begin
  Result := '';
  if (not Assigned(AStream)) or (AStream.Size = 0) then Exit;
  AStream.Position := 0;
  SetLength(LBytes, AStream.Size);
  AStream.Read(LBytes[0], AStream.Size);
  // [FIX-BINBODY-1] Response-side mirror of the request-side guard. A handler
  // that calls Res.SendFile/Download with a binary stream (a PDF, an image, a
  // TFDMemTable sfBinary export) lands here, and TEncoding.GetString raises
  // EEncodingError on bytes that are not valid UTF-8 — turning a valid binary
  // response into a 500.
  //
  // As on the request side this only converts a crash into an empty body: ICS
  // v1 carries the response body as a string, so binary content cannot survive
  // this function regardless. Serving binary from ICS needs a bytes path.
  try
    Result := TEncoding.UTF8.GetString(LBytes);
  except
    Result := '';
  end;
end;

class function TICSResponseBridge.WriteBody(
        AHorseRes: THorseResponse;
        AStatus:   Integer): string;
var
  Stream:   TStream;
  LRaw:     {$IF DEFINED(FPC)}TResponse{$ELSE}TWebResponse{$ENDIF};
begin
  // PATCH-SENDFILE-1 (structural parity): the Horse fork now materialises a
  // response-OWNED copy of the source stream inside Res.SendFile/Download, and
  // Horse.Response frees it in Clear/Destroy. ICS builds the entire body string
  // synchronously here on the worker thread, so there is no async window and no
  // use-after-free risk — unlike the CrossSocket bridge (whose Send(TStream) is
  // async), ICS needs no byte-send change, only this synchronous drain.
  Stream := AHorseRes.ContentStream;
  if Assigned(Stream) and (Stream.Size > 0) then
    Exit(TryReadBodyStream(Stream));

  // [FIX-BODYBYTES-1] BodyBytes — the shadow slot written by Res.Send(TBytes).
  //
  // Horse core's Send(const AContent: TBytes) stores into FCSBodyBytes on the
  // shadow path (FWebResponse = nil — every non-WebBroker provider) and exposes
  // it as the public BodyBytes property. This bridge never read that slot, so
  // Res.Send(SomeBytes) fell through BodyText (still empty) to the empty tail:
  // the client received 200 with no payload and nothing logged anywhere.
  //
  // The decode is guarded for the same reason as the request side: WriteBody
  // returns a *string*, so bytes that are not valid UTF-8 would raise
  // EEncodingError here and turn the response into a 500. See FIX-BINBODY-1.
  //
  // Scope, stated plainly: this repairs Send(TBytes) for TEXT payloads only.
  // ICS carries the response body as a string end-to-end, so a genuinely binary
  // TBytes still cannot survive this function — it degrades to an empty body
  // rather than crashing. Real binary responses need the byte-preserving path
  // this provider does not yet have; the same limitation applies to SendFile
  // and Download here.
  if Length(AHorseRes.BodyBytes) > 0 then
  begin
    try
      Exit(TEncoding.UTF8.GetString(AHorseRes.BodyBytes));
    except
      Exit('');
    end;
  end;

  if AHorseRes.BodyText <> '' then
    Exit(AHorseRes.BodyText);

  LRaw := AHorseRes.RawWebResponse;
  if Assigned(LRaw) then
  begin
    // Forward hook: a middleware that set RawWebResponse.ContentStream would be
    // drained here. Dormant today (TInterfacedWebResponse.GetContentStream is a
    // stub returning nil); mirrors the CrossSocket/mORMot bridges so the day the
    // stub forwards, ICS already reads it.
    Stream := LRaw.ContentStream;
    if Assigned(Stream) and (Stream.Size > 0) then
      Exit(TryReadBodyStream(Stream));
    if LRaw.Content <> '' then
      Exit(LRaw.Content);
  end;

  if AStatus >= 400 then
    Exit(IntToStr(AStatus));

  Result := '';
end;

end.
