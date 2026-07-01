unit Horse.Provider.ICS.Request;

(*
  Horse ICS Provider — Request Bridge
  -----------------------------------
  Three responsibilities, split across thread boundaries:

  1. Validate (loop thread)  — verb allowlist, Host, URL length, smuggling,
                                header count, body size. Returns
                                TRequestValidationResult. Bad requests get
                                a 4xx response straight from the provider —
                                the pool is never acquired.

  2. Snapshot (loop thread)  — copy every field we need out of THttpConnection
                                into a TICSRequestSnapshot. ICS forbids touching
                                the live connection off the loop thread, so this
                                is the only point at which we read from it.

  3. Populate (worker thread)— write the snapshot into THorseRequest shadow
                                fields via the PATCH-REQ-3/8/9 surface.

  ── Prerequisite: Horse fork patches ───────────────────────────────────────
    PATCH-REQ-3  Populate(...) shadow-field setter
    PATCH-REQ-8  SetCSRawWebRequest(TWebRequest)
    PATCH-REQ-9  SetBodyString(string) + Body:string nil-guard

  ── Security checks (mirror mORMot/CrossSocket providers) ──────────────────
    [SEC-12] HTTP smuggling — reject CL + TE both present.
    [SEC-13] Header count + name/value size limits.
    [SEC-14] URL length limit (8 KB).
    [SEC-15] Method allowlist (GET POST PUT DELETE PATCH HEAD OPTIONS).
    [SEC-16] Body size — checked against config.MaxBodyBytes.
    [SEC-17] Host present + printable ASCII.
    [SEC-18] Query key/value size limits.

  Dual-compilation: Delphi only in v1 (FPC seams retained).
*)

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  Classes,
  SysUtils,
{$ELSE}
  System.Classes,
  System.SysUtils,
{$ENDIF}
  Horse.Request,
  Horse.Commons,
  Horse.Core.Param,
  Horse.Provider.ICS.RawRequest,
  Horse.Provider.ICS.WebRequestAdapter
{$IF NOT DEFINED(FPC)}
  , Web.HTTPApp
  , OverbyteIcsFormDataDecoder   // TFormDataAnalyser — multipart/form-data (Delphi: Windows & POSIX)
{$ENDIF}
  ;

const
  MAX_HEADER_COUNT     = 100;
  MAX_HEADER_NAME_LEN  = 256;
  MAX_HEADER_VALUE_LEN = 8192;
  MAX_URL_LEN          = 8192;
  MAX_QUERY_KEY_LEN    = 2048;
  MAX_QUERY_VALUE_LEN  = 2048;

type
  TRequestValidationResult = (
    rvOK,
    rvBadRequest,
    rvMethodNotAllowed,
    rvPayloadTooLarge
  );

  // Minimal view of a THttpConnection. Declared here so Validate/Snapshot
  // can be unit-tested without dragging the full ICS unit in, and so a
  // future drapid/ICS_Lazarus port can supply its own shim.
  TICSRequestView = record
    Method:           string;
    Path:             string;
    Params:           string;
    Version:          string;
    Host:             string;
    PeerAddr:         string;
    ServerPort:       Integer;
    ContentType:      string;
    ContentLength:    Int64;
    HeaderText:       string;   // full request header block as ICS exposes it
    BodyText:         string;   // body buffer after OnPostedData has finished
  end;

  TICSRequestBridge = class
  public
    class function Validate(
      const AView:         TICSRequestView;
      out   ARejectReason: string;
            AMaxBodyBytes: Int64
    ): TRequestValidationResult;

    // Build a heap-allocated snapshot owned by the caller (typically the
    // worker pool task). Free with Dispose(...).
    class function Snapshot(const AView: TICSRequestView): PICSRequestSnapshot;

    // Run on a worker thread — never touches the live THttpConnection.
    class procedure Populate(
      const ASnap:           PICSRequestSnapshot;
      const AHorseReq:       THorseRequest;
            AMaxHeaderCount: Integer
    );

  private
    class function MapMethodType(const AMethod: string): TMethodType;
    class procedure SplitHeaderLines(const AText: string; out ALines: TArray<string>);
{$IF NOT DEFINED(FPC)}
    // Decodes a multipart/form-data body into AHorseReq.ContentFields via ICS's
    // TFormDataAnalyser. Delphi only (Windows & POSIX) — the decoder unit is
    // cross-platform; FPC is excluded because ICS POSIX support is Delphi-only.
    class procedure PopulateMultipartFields(const ABody: string;
      const AHorseReq: THorseRequest);
{$ENDIF}
  end;

implementation

const
  ALLOWED_METHODS: array[0..6] of string = (
    'GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS'
  );

class function TICSRequestBridge.Validate(
  const AView:         TICSRequestView;
  out   ARejectReason: string;
        AMaxBodyBytes: Int64
): TRequestValidationResult;
var
  LMethod, LUrl, LHost, LHeaders, LTeValue: string;
  HasCL, HasTE: Boolean;
  LTePos, LTeEnd, I: Integer;
  C: Char;
begin
  ARejectReason := '';

  // [SEC-15]
  LMethod := AView.Method;
  Result  := rvMethodNotAllowed;
  for I := 0 to High(ALLOWED_METHODS) do
    if SameText(LMethod, ALLOWED_METHODS[I]) then
    begin
      Result := rvOK;
      Break;
    end;
  if Result <> rvOK then
  begin
    ARejectReason := 'Method Not Allowed: ' + LMethod;
    Exit;
  end;

  // [SEC-14]
  LUrl := AView.Path;
  if AView.Params <> '' then
    LUrl := LUrl + '?' + AView.Params;
  if Length(LUrl) > MAX_URL_LEN then
  begin
    ARejectReason := 'URI Too Long';
    Exit(rvBadRequest);
  end;

  // [SEC-17]
  LHost := AView.Host;
  if LHost = '' then
  begin
    ARejectReason := 'Missing Host header';
    Exit(rvBadRequest);
  end;
  for I := 1 to Length(LHost) do
  begin
    C := LHost[I];
    if (Ord(C) < 32) or (Ord(C) > 126) then
    begin
      ARejectReason := 'Invalid Host header';
      Exit(rvBadRequest);
    end;
  end;

  // [SEC-12]
  LHeaders := AView.HeaderText;
  HasCL := Pos('content-length:', LowerCase(LHeaders)) > 0;

  LTePos := Pos('transfer-encoding:', LowerCase(LHeaders));
  HasTE  := LTePos > 0;
  if HasTE then
  begin
    LTePos := LTePos + Length('transfer-encoding:');
    while (LTePos <= Length(LHeaders)) and (LHeaders[LTePos] = ' ') do
      Inc(LTePos);
    LTeEnd := Pos(#13, Copy(LHeaders, LTePos, MaxInt));
    if LTeEnd = 0 then
      LTeEnd := Length(LHeaders) - LTePos + 2;
    LTeValue := Trim(LowerCase(Copy(LHeaders, LTePos, LTeEnd - 1)));
  end
  else
    LTeValue := '';

  if HasCL and HasTE then
  begin
    ARejectReason := 'Ambiguous framing: both Content-Length and Transfer-Encoding present';
    Exit(rvBadRequest);
  end;
  if HasTE and (LTeValue <> 'chunked') and (LTeValue <> 'identity') then
  begin
    ARejectReason := 'Unsupported Transfer-Encoding: ' + LTeValue;
    Exit(rvBadRequest);
  end;

  // [SEC-16] — ICS has already buffered the body before Validate is called
  // on the POST/PUT/PATCH paths (we call it from OnPostedData), so we can
  // size-check the live buffer.
  if (AMaxBodyBytes > 0) and (Int64(Length(AView.BodyText)) > AMaxBodyBytes) then
  begin
    ARejectReason := 'Payload Too Large';
    Exit(rvPayloadTooLarge);
  end;

  Result := rvOK;
end;

class function TICSRequestBridge.Snapshot(
  const AView: TICSRequestView): PICSRequestSnapshot;
var
  LUrl: string;
begin
  New(Result);
  Initialize(Result^);

  Result.Method          := AView.Method;
  Result.PathInfo        := AView.Path;
  Result.QueryString     := AView.Params;
  if (Result.PathInfo = '') or (Result.PathInfo[1] <> '/') then
    Result.PathInfo := '/' + Result.PathInfo;
  LUrl := Result.PathInfo;
  if Result.QueryString <> '' then
    LUrl := LUrl + '?' + Result.QueryString;
  Result.URL             := LUrl;
  Result.ProtocolVersion := AView.Version;
  Result.Host            := AView.Host;
  Result.RemoteAddr      := AView.PeerAddr;
  Result.ServerPort      := AView.ServerPort;
  Result.ContentType     := AView.ContentType;
  Result.ContentLength   := AView.ContentLength;
  Result.Body            := AView.BodyText;
  Result.HeaderText      := AView.HeaderText;
  SplitHeaderLines(AView.HeaderText, Result.HeaderLines);
end;

class procedure TICSRequestBridge.SplitHeaderLines(const AText: string;
  out ALines: TArray<string>);
var
  LPtr, LEnd, LCount, LCap: Integer;
  LLine: string;
begin
  ALines := nil;
  LCap   := 32;
  SetLength(ALines, LCap);
  LCount := 0;
  LPtr   := 1;
  while LPtr <= Length(AText) do
  begin
    LEnd := Pos(#13, Copy(AText, LPtr, MaxInt));
    if LEnd = 0 then
      LEnd := Length(AText) - LPtr + 2;
    LLine := Copy(AText, LPtr, LEnd - 1);
    LPtr  := LPtr + LEnd;
    if (LPtr <= Length(AText)) and (AText[LPtr] = #10) then
      Inc(LPtr);
    if LLine = '' then Continue;
    if LCount >= LCap then
    begin
      LCap := LCap * 2;
      SetLength(ALines, LCap);
    end;
    ALines[LCount] := LLine;
    Inc(LCount);
  end;
  SetLength(ALines, LCount);
end;

class procedure TICSRequestBridge.Populate(
  const ASnap:           PICSRequestSnapshot;
  const AHorseReq:       THorseRequest;
        AMaxHeaderCount: Integer
);
var
  I, LCount, LColonPos, LEqPos, LPos, LNextAmp: Integer;
  LLine, LName, LValue, LQuery, LPair, LKey, LVal: string;
  LCookieRaw, LCookiePair, LCookieKey, LCookieVal: string;
  LSemiPos: Integer;
begin
  if (ASnap = nil) or (not Assigned(AHorseReq)) then Exit;

  // PATCH-REQ-3 — write shadow fields.
  AHorseReq.Populate(
    ASnap.Method,
    MapMethodType(ASnap.Method),
    ASnap.PathInfo,
    ASnap.ContentType,
    ASnap.RemoteAddr
  );

  // [SEC-13] headers
  LCount := 0;
  for I := 0 to High(ASnap.HeaderLines) do
  begin
    LLine := ASnap.HeaderLines[I];
    Inc(LCount);
    if LCount > AMaxHeaderCount then Break;

    LColonPos := Pos(':', LLine);
    if LColonPos = 0 then Continue;
    LName  := Trim(Copy(LLine, 1, LColonPos - 1));
    LValue := Trim(Copy(LLine, LColonPos + 1, MaxInt));
    if LName = '' then Continue;
    if Length(LName)  > MAX_HEADER_NAME_LEN  then Continue;
    if Length(LValue) > MAX_HEADER_VALUE_LEN then Continue;
    if (Pos(#13, LName) > 0) or (Pos(#10, LName) > 0) then Continue;

    AHorseReq.Headers.Dictionary.AddOrSetValue(LName, LValue);
  end;

  // Query params
  LQuery := ASnap.QueryString;
  LPos   := 1;
  while LPos <= Length(LQuery) do
  begin
    LNextAmp := Pos('&', Copy(LQuery, LPos, MaxInt));
    if LNextAmp = 0 then
      LNextAmp := Length(LQuery) - LPos + 2;
    LPair := Copy(LQuery, LPos, LNextAmp - 1);
    LPos  := LPos + LNextAmp;
    LEqPos := Pos('=', LPair);
    if LEqPos > 0 then
    begin
      LKey := Copy(LPair, 1, LEqPos - 1);
      LVal := Copy(LPair, LEqPos + 1, MaxInt);
    end
    else
    begin
      LKey := LPair;
      LVal := '';
    end;
    if LKey = '' then Continue;
    if (Length(LKey) > MAX_QUERY_KEY_LEN) or
       (Length(LVal) > MAX_QUERY_VALUE_LEN) then Continue;
    AHorseReq.Query.Dictionary.AddOrSetValue(LKey, LVal);
  end;

  // Cookies — look up in already-split header lines.
  for I := 0 to High(ASnap.HeaderLines) do
  begin
    LLine := ASnap.HeaderLines[I];
    LColonPos := Pos(':', LLine);
    if LColonPos = 0 then Continue;
    if not SameText(Trim(Copy(LLine, 1, LColonPos - 1)), 'Cookie') then Continue;
    LCookieRaw := Trim(Copy(LLine, LColonPos + 1, MaxInt));
    LPos := 1;
    while LPos <= Length(LCookieRaw) do
    begin
      LSemiPos := Pos(';', Copy(LCookieRaw, LPos, MaxInt));
      if LSemiPos = 0 then
        LSemiPos := Length(LCookieRaw) - LPos + 2;
      LCookiePair := Trim(Copy(LCookieRaw, LPos, LSemiPos - 1));
      LPos := LPos + LSemiPos;
      if LCookiePair = '' then Continue;
      LEqPos := Pos('=', LCookiePair);
      if LEqPos > 0 then
      begin
        LCookieKey := Trim(Copy(LCookiePair, 1, LEqPos - 1));
        LCookieVal := Trim(Copy(LCookiePair, LEqPos + 1, MaxInt));
      end
      else
      begin
        LCookieKey := LCookiePair;
        LCookieVal := '';
      end;
      if LCookieKey <> '' then
        AHorseReq.Cookie.Dictionary.AddOrSetValue(LCookieKey, LCookieVal);
    end;
    Break;
  end;

  // application/x-www-form-urlencoded content fields
  if Pos('application/x-www-form-urlencoded', LowerCase(ASnap.ContentType)) > 0 then
  begin
    LQuery := ASnap.Body;
    LPos   := 1;
    while LPos <= Length(LQuery) do
    begin
      LNextAmp := Pos('&', Copy(LQuery, LPos, MaxInt));
      if LNextAmp = 0 then
        LNextAmp := Length(LQuery) - LPos + 2;
      LPair := Copy(LQuery, LPos, LNextAmp - 1);
      LPos  := LPos + LNextAmp;
      if LPair <> '' then
        AHorseReq.ContentFields.Dictionary.AddOrSetValue(LPair, '');
    end;
  end;
{$IF NOT DEFINED(FPC)}
  // multipart/form-data — decoded via ICS's TFormDataAnalyser
  // (OverbyteIcsFormDataDecoder). Populates Req.ContentFields exactly like the
  // CrossSocket / mORMot providers, so Req.ContentFields['field'] and
  // Req.ContentFields.Field('file').AsStream resolve identically across providers.
  // Delphi only (Windows & POSIX) — OverbyteIcsFormDataDecoder is cross-platform.
  if (ASnap.Body <> '') and
     (Pos('multipart/form-data', LowerCase(ASnap.ContentType)) > 0) then
    PopulateMultipartFields(ASnap.Body, AHorseReq);
{$ENDIF}

  // PATCH-REQ-9 — cache decoded body as a string.
  if ASnap.Body <> '' then
    AHorseReq.SetBodyString(ASnap.Body);

  // PATCH-REQ-8 — RawWebRequest adapter (Horse.CORS etc.).
  AHorseReq.SetCSRawWebRequest(TICSWebRequest.Create(ASnap));
end;

{$IF NOT DEFINED(FPC)}
// ── PopulateMultipartFields ──────────────────────────────────────────────────
// Decodes a multipart/form-data body via ICS's TFormDataAnalyser and populates
// AHorseReq.ContentFields with one entry per part — mirroring the CrossSocket /
// mORMot providers:
//   ContentFields[Name]                  → text content (or raw bytes for files)
//   ContentFields[Name + '_filename']    → original filename, when present
//   ContentFields[Name + '_contenttype'] → declared Content-Type, when present
//
// File parts are handed to Horse as a TStream via AddStream(..., AOwnsStream=True):
// TFormDataItem owns its own data, so we synthesise an owned TBytesStream and
// transfer ownership to THorseCoreParam (freed on pool Clear / Destroy), exactly
// the mORMot pattern (PATCH-PARAM-1). The string-dictionary path would route file
// bytes through a UTF-8 decode and corrupt binary uploads.
//
// Caveat: ASnap.Body is captured as a string by the ICS snapshot (v1), so a
// truly binary upload's byte fidelity is bounded by that capture — fine for
// text/UTF-8 parts; documented in doc/implementation-notes.md.
class procedure TICSRequestBridge.PopulateMultipartFields(
  const ABody:     string;
  const AHorseReq: THorseRequest);
var
  LAnalyser: TFormDataAnalyser;
  LItem:     TFormDataItem;
  I:         Integer;
  LName:     string;
  LFileName: string;
  LCType:    string;
  LStream:   TBytesStream;
begin
  LAnalyser := TFormDataAnalyser.Create(nil);
  try
    // ICS's decoder wants the raw octets as a RawByteString.
    LAnalyser.DecodeString(RawByteString(AnsiString(ABody)));

    for I := 0 to LAnalyser.PartCount - 1 do
    begin
      LItem := LAnalyser.Part(I);
      if LItem = nil then Continue;

      LName := LItem.ContentName;
      if LName = '' then Continue;
      LFileName := LItem.ContentFileName;   // '' for ordinary form fields
      LCType    := LItem.ContentType;

      if LFileName <> '' then
      begin
        // File part — preserve raw bytes via an owned TStream so
        // Req.ContentFields.Field(LName).AsStream returns them intact.
        LStream := TBytesStream.Create(LItem.AsBytes);
        LStream.Position := 0;
        AHorseReq.ContentFields.AddStream(LName, LStream, {AOwnsStream=}True);

        AHorseReq.ContentFields.Dictionary.AddOrSetValue(LName + '_filename', LFileName);
        if LCType <> '' then
          AHorseReq.ContentFields.Dictionary.AddOrSetValue(LName + '_contenttype', LCType);
      end
      else
      begin
        // Plain form field — AsString auto-detects UTF-8 (ICS V9.1+).
        AHorseReq.ContentFields.Dictionary.AddOrSetValue(LName, LItem.AsString);
        if LCType <> '' then
          AHorseReq.ContentFields.Dictionary.AddOrSetValue(LName + '_contenttype', LCType);
      end;
    end;
  finally
    LAnalyser.Free;
  end;
end;
{$ENDIF}

class function TICSRequestBridge.MapMethodType(const AMethod: string): TMethodType;
begin
  if      SameText(AMethod, 'GET')    then Result := mtGet
  else if SameText(AMethod, 'POST')   then Result := mtPost
  else if SameText(AMethod, 'PUT')    then Result := mtPut
  else if SameText(AMethod, 'DELETE') then Result := mtDelete
  else if SameText(AMethod, 'PATCH')  then Result := mtPatch
  else if SameText(AMethod, 'HEAD')   then Result := mtHead
  else                                     Result := mtAny;
end;

end.
