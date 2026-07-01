unit Horse.Provider.ICS.RawRequest;

(*
  OverbyteICS IHorseRawRequest implementation
  ===========================================
  Wraps a request *snapshot* (NOT the live THttpConnection).

  Why a snapshot?
  ----------------
  ICS sockets are single-thread-affine — the entire server runs on one
  message-loop thread and a connection object must never be touched off it.
  TICSRequestBridge.Snapshot copies every field we need into a plain owned
  record on the loop thread, then hands ownership to the worker pool.
  The worker (and this adapter) read only from the snapshot.

  The generic TInterfacedWebRequest adapter (Horse.Provider.RawAdapters)
  delegates here to build a full TWebRequest compatible with all middleware.

  Dual-compilation: Delphi only in v1 ({$IF DEFINED(FPC)} seams retained for
  a future drapid/ICS_Lazarus port).
*)

{$IF DEFINED(FPC)}
{$MODE DELPHI}{$H+}
{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
  Classes,
{$ELSE}
  System.SysUtils,
  System.Classes,
{$ENDIF}
  Horse.Provider.RawInterfaces;

type
  // Plain-data snapshot of a single HTTP request.
  // Built by TICSRequestBridge.Snapshot on the message-loop thread and then
  // handed off to the worker. The worker owns it for the duration of the
  // pipeline; on response marshal-back the loop thread destroys it.
  TICSRequestSnapshot = record
    Method:           string;
    PathInfo:         string;   // path with the query string stripped
    QueryString:      string;
    URL:              string;   // raw request-target (Path + '?' + Params)
    ProtocolVersion:  string;
    Host:             string;
    RemoteAddr:       string;
    ServerPort:       Integer;
    ContentType:      string;
    ContentLength:    Int64;
    Body:             string;   // text body (decoded once at snapshot time)
    HeaderText:       string;   // full CRLF-delimited header block
    HeaderLines:      TArray<string>; // already-split for fast header lookup
  end;
  PICSRequestSnapshot = ^TICSRequestSnapshot;

  TICSRawRequest = class(TInterfacedObject, IHorseRawRequest)
  private
    FSnap: PICSRequestSnapshot;
  public
    constructor Create(ASnap: PICSRequestSnapshot);

    { IHorseRawRequest }
    function  GetMethod: string;
    function  GetProtocolVersion: string;
    function  GetURL: string;
    function  GetPathInfo: string;
    function  GetQueryString: string;
    function  GetHost: string;
    function  GetRemoteAddr: string;
    function  GetServerPort: Integer;
    function  GetContentType: string;
    function  GetContent: string;
{$IF DEFINED(FPC)}
    function  GetContentLength: Integer;
{$ELSEIF CompilerVersion >= 32.0}
    function  GetContentLength: Int64;
{$ELSE}
    function  GetContentLength: Integer;
{$IFEND}
    function  GetFieldByName(const AName: string): string;
    procedure PopulateQueryFields(ADest: TStrings);
    procedure PopulateContentFields(ADest: TStrings);
    procedure PopulateCookieFields(ADest: TStrings);
    function  ReadBody(var Buffer; Count: Integer): Integer;
  end;

implementation

constructor TICSRawRequest.Create(ASnap: PICSRequestSnapshot);
begin
  inherited Create;
  FSnap := ASnap;
end;

function TICSRawRequest.GetMethod: string;
begin
  Result := FSnap.Method;
end;

function TICSRawRequest.GetProtocolVersion: string;
begin
  if FSnap.ProtocolVersion <> '' then
    Result := FSnap.ProtocolVersion
  else
    Result := 'HTTP/1.1';
end;

function TICSRawRequest.GetURL: string;
begin
  Result := FSnap.URL;
end;

function TICSRawRequest.GetPathInfo: string;
begin
  Result := FSnap.PathInfo;
end;

function TICSRawRequest.GetQueryString: string;
begin
  Result := FSnap.QueryString;
end;

function TICSRawRequest.GetHost: string;
begin
  Result := FSnap.Host;
end;

function TICSRawRequest.GetRemoteAddr: string;
begin
  Result := FSnap.RemoteAddr;
end;

function TICSRawRequest.GetServerPort: Integer;
begin
  Result := FSnap.ServerPort;
end;

function TICSRawRequest.GetContentType: string;
begin
  Result := FSnap.ContentType;
end;

function TICSRawRequest.GetContent: string;
begin
  Result := FSnap.Body;
end;

{$IF DEFINED(FPC)}
function TICSRawRequest.GetContentLength: Integer;
{$ELSEIF CompilerVersion >= 32.0}
function TICSRawRequest.GetContentLength: Int64;
{$ELSE}
function TICSRawRequest.GetContentLength: Integer;
{$IFEND}
begin
  Result := FSnap.ContentLength;
end;

function TICSRawRequest.GetFieldByName(const AName: string): string;
var
  I:        Integer;
  LLine:    string;
  LSearch:  string;
  LColon:   Integer;
begin
  Result  := '';
  LSearch := LowerCase(AName);
  for I := 0 to High(FSnap.HeaderLines) do
  begin
    LLine := FSnap.HeaderLines[I];
    LColon := Pos(':', LLine);
    if LColon = 0 then Continue;
    if LowerCase(Trim(Copy(LLine, 1, LColon - 1))) = LSearch then
    begin
      Result := Trim(Copy(LLine, LColon + 1, MaxInt));
      Exit;
    end;
  end;
end;

procedure TICSRawRequest.PopulateQueryFields(ADest: TStrings);
var
  S, Pair, Key, Val: string;
  AmpPos, EqPos: Integer;
begin
  S := FSnap.QueryString;
  while S <> '' do
  begin
    AmpPos := Pos('&', S);
    if AmpPos > 0 then
    begin
      Pair := Copy(S, 1, AmpPos - 1);
      Delete(S, 1, AmpPos);
    end
    else
    begin
      Pair := S;
      S := '';
    end;
    EqPos := Pos('=', Pair);
    if EqPos > 0 then
    begin
      Key := Copy(Pair, 1, EqPos - 1);
      Val := Copy(Pair, EqPos + 1, MaxInt);
    end
    else
    begin
      Key := Pair;
      Val := '';
    end;
    if Key <> '' then
      ADest.Add(Key + '=' + Val);
  end;
end;

procedure TICSRawRequest.PopulateContentFields(ADest: TStrings);
var
  S, Pair: string;
  AmpPos: Integer;
begin
  if Pos('application/x-www-form-urlencoded', LowerCase(FSnap.ContentType)) > 0 then
  begin
    S := FSnap.Body;
    while S <> '' do
    begin
      AmpPos := Pos('&', S);
      if AmpPos > 0 then
      begin
        Pair := Copy(S, 1, AmpPos - 1);
        Delete(S, 1, AmpPos);
      end
      else
      begin
        Pair := S;
        S := '';
      end;
      ADest.Add(Pair);
    end;
  end;
end;

procedure TICSRawRequest.PopulateCookieFields(ADest: TStrings);
var
  S, Pair: string;
  SemiPos, EqPos: Integer;
  CookieName, CookieVal: string;
begin
  S := Trim(GetFieldByName('Cookie'));
  while S <> '' do
  begin
    SemiPos := Pos(';', S);
    if SemiPos > 0 then
    begin
      Pair := Trim(Copy(S, 1, SemiPos - 1));
      Delete(S, 1, SemiPos);
      S := TrimLeft(S);
    end
    else
    begin
      Pair := Trim(S);
      S := '';
    end;
    if Pair <> '' then
    begin
      EqPos := Pos('=', Pair);
      if EqPos > 0 then
      begin
        CookieName := Trim(Copy(Pair, 1, EqPos - 1));
        CookieVal  := Trim(Copy(Pair, EqPos + 1, MaxInt));
      end
      else
      begin
        CookieName := Pair;
        CookieVal  := '';
      end;
      ADest.Add(CookieName + '=' + CookieVal);
    end;
  end;
end;

function TICSRawRequest.ReadBody(var Buffer; Count: Integer): Integer;
var
  LLen: Integer;
begin
  LLen := Length(FSnap.Body);
  if LLen = 0 then Exit(0);
  if Count > LLen then
    Count := LLen;
  Move(FSnap.Body[1], Buffer, Count * SizeOf(Char));
  Result := Count;
end;

end.
