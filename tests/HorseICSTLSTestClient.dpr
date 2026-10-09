program HorseICSTLSTestClient;

{$APPTYPE CONSOLE}

{
  Horse + OverbyteICS  —  TLS / mutual-TLS test client
  =====================================================
  Destination: horse-provider-ics/samples/tests/HorseICSTLSTestClient.dpr

  Drives HorseICSTLSTestServer over HTTPS (https://127.0.0.1:9111) with
  TCrossHttpClient (used purely as a provider-neutral HTTP/TLS driver, same as
  the ICS param test client). Two modes, matching the server's argument:

    (no arg)   one-way TLS
                 T1  GET  /ping  over https → 200 "pong"
                 T2  POST /echo  over https → body echoed (Content-Length body)

    mtls       mutual TLS
                 T3  GET /ping WITH client cert    → 200
                 T4  GET /ping WITHOUT client cert  → rejected

  The client certificate is injected by overriding TCrossHttpClient's virtual
  CreateHttpCli to set the cert on the HTTPS socket before it connects.

  Exit code = number of failed assertions (0 = all passed).
}

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  Net.CrossSslSocket.Base,      // ICrossSslSocket.SetCertificateFile
  Net.CrossHttpClient;

const
  BASE_URL   = 'https://127.0.0.1:9111';
  TIMEOUT_MS = 8000;

var
  GPassCount: Integer = 0;
  GFailCount: Integer = 0;
  GClientCert: string = '';
  GClientKey:  string = '';

type
  TMTLSHttpClient = class(TCrossHttpClient)
  protected
    function CreateHttpCli(const AProtocol: string): ICrossHttpClientSocket; override;
  end;

  TReqResult = record
    StatusCode: Integer;
    Body:       string;
    TimedOut:   Boolean;
    Failed:     Boolean;
  end;

function TMTLSHttpClient.CreateHttpCli(const AProtocol: string): ICrossHttpClientSocket;
begin
  Result := inherited CreateHttpCli(AProtocol);
  if SameText(AProtocol, 'https') and (GClientCert <> '') then
  begin
    Result.SetCertificateFile(GClientCert);
    Result.SetPrivateKeyFile(GClientKey);
  end;
end;

function StreamToStr(AStream: TStream): string;
var
  LBytes: TBytes;
begin
  Result := '';
  if not Assigned(AStream) or (AStream.Size = 0) then
    Exit;
  AStream.Position := 0;
  SetLength(LBytes, AStream.Size);
  AStream.ReadBuffer(LBytes[0], AStream.Size);
  Result := TEncoding.UTF8.GetString(LBytes);
end;

function FindCertDir: string;
const
  CANDIDATES: array[0..3] of string = (
    'certs', '..\certs', 'tests\certs', '..\tests\certs');
var
  LBase, LCand: string;
  I: Integer;
begin
  LBase := ExtractFilePath(ParamStr(0));
  for I := Low(CANDIDATES) to High(CANDIDATES) do
  begin
    LCand := LBase + CANDIDATES[I] + PathDelim;
    if FileExists(LCand + 'client.crt') then
      Exit(LCand);
  end;
  for I := Low(CANDIDATES) to High(CANDIDATES) do
  begin
    LCand := CANDIDATES[I] + PathDelim;
    if FileExists(LCand + 'client.crt') then
      Exit(LCand);
  end;
  raise Exception.Create(
    'Could not locate certs\client.crt — copy tests\certs next to the binary.');
end;

function DoSync(const AClient: TCrossHttpClient; const AMethod, AUrl, ABody: string): TReqResult;
var
  LEvent: TEvent;
  LLocal: TReqResult;
  LBytes: TBytes;
begin
  LLocal := Default(TReqResult);
  LEvent := TEvent.Create(nil, True, False, '');
  try
    if ABody <> '' then
      LBytes := TEncoding.UTF8.GetBytes(ABody)
    else
      LBytes := nil;

    AClient.DoRequest(AMethod, AUrl, nil, LBytes, nil, nil,
      procedure(const AResp: ICrossHttpClientResponse)
      begin
        if AResp <> nil then
        begin
          LLocal.StatusCode := AResp.StatusCode;
          LLocal.Body       := StreamToStr(AResp.Content);
        end
        else
          LLocal.Failed := True;
        LEvent.SetEvent;
      end);

    LLocal.TimedOut := (LEvent.WaitFor(TIMEOUT_MS) <> wrSignaled);
  finally
    LEvent.Free;
  end;
  Result := LLocal;
end;

procedure Check(const AName: string; const APassed: Boolean; const ADetail: string = '');
begin
  if APassed then
  begin
    Writeln(Format('  PASS  %s', [AName]));
    Inc(GPassCount);
  end
  else
  begin
    if ADetail <> '' then
      Writeln(Format('  FAIL  %s  [%s]', [AName, ADetail]))
    else
      Writeln(Format('  FAIL  %s', [AName]));
    Inc(GFailCount);
  end;
end;

procedure RunOneWay;
var
  LClient: TCrossHttpClient;
  R:       TReqResult;
begin
  Writeln('[one-way TLS]');
  LClient := TCrossHttpClient.Create(2);
  try
    R := DoSync(LClient, 'GET', BASE_URL + '/ping', '');
    Check('T1  GET /ping over https → 200',
      (not R.TimedOut) and (R.StatusCode = 200) and (R.Body = 'pong'),
      Format('status=%d failed=%s body=%s', [R.StatusCode, BoolToStr(R.Failed, True), R.Body]));

    R := DoSync(LClient, 'POST', BASE_URL + '/echo', 'hello-tls');
    Check('T2  POST /echo over https → body echoed',
      (not R.TimedOut) and (R.StatusCode = 200) and (R.Body = 'hello-tls'),
      Format('status=%d body=%s', [R.StatusCode, R.Body]));

    // [FIX-ICS-SSLCONN-1] T5a: a body-less PUT over TLS reaches the handler.
    // Until Delphi-Cross-Socket 1.0.15 TCrossHttpClient sent NO Content-Length
    // for an empty body, which is the request ICS rejects with 400 before the
    // handler runs unless the provider's lenient THorseICSConnection is the
    // TLS server's ClientClass. DCS 1.0.16 (winddriver #208) sends
    // Content-Length: 0 instead, so this check no longer reaches that path:
    // it now covers only the Content-Length: 0 case. The no-Content-Length
    // case is T5b, sent raw through openssl s_client by run-tls-tests.bat,
    // which no client library can "fix".
    R := DoSync(LClient, 'PUT', BASE_URL + '/nobody', '');
    Check('T5a PUT /nobody (empty body, Content-Length: 0) over https -> handler ran',
      (not R.TimedOut) and (R.StatusCode = 200) and (R.Body = 'put-ok'),
      Format('status=%d body=%s', [R.StatusCode, R.Body]));

    // [ICS-OSSLRUNTIME-1] The provider records the OpenSSL it loaded at
    // Listen. Read it from the running server: it must name an OpenSSL build
    // and the libcrypto file it came from.
    R := DoSync(LClient, 'GET', BASE_URL + '/openssl', '');
    Check('T6  provider reports the loaded OpenSSL (OpenSslRuntime)',
      (not R.TimedOut) and (R.StatusCode = 200) and
      (Pos('OpenSSL ', R.Body) = 1) and (Pos(' from ', R.Body) > 0) and
      (Pos('libcrypto', LowerCase(R.Body)) > 0),
      Format('status=%d body=%s', [R.StatusCode, R.Body]));
    if R.StatusCode = 200 then
      Writeln('        ', R.Body);
  finally
    LClient.Free;
  end;
end;

procedure RunMutual;
var
  LClient:  TCrossHttpClient;
  LCertDir: string;
  R:        TReqResult;
begin
  Writeln('[mutual TLS]');
  LCertDir := FindCertDir;

  GClientCert := LCertDir + 'client.crt';
  GClientKey  := LCertDir + 'client.key';
  LClient := TMTLSHttpClient.Create(2);
  try
    R := DoSync(LClient, 'GET', BASE_URL + '/ping', '');
    Check('T3  GET /ping WITH client cert → 200',
      (not R.TimedOut) and (R.StatusCode = 200) and (R.Body = 'pong'),
      Format('status=%d failed=%s', [R.StatusCode, BoolToStr(R.Failed, True)]));
  finally
    LClient.Free;
  end;

  GClientCert := '';
  GClientKey  := '';
  LClient := TCrossHttpClient.Create(2);
  try
    R := DoSync(LClient, 'GET', BASE_URL + '/ping', '');
    Check('T4  GET /ping WITHOUT client cert → rejected',
      R.TimedOut or R.Failed or (R.StatusCode <> 200),
      Format('status=%d failed=%s timedout=%s',
        [R.StatusCode, BoolToStr(R.Failed, True), BoolToStr(R.TimedOut, True)]));
  finally
    LClient.Free;
  end;
end;

begin
  Writeln('Horse + OverbyteICS  —  TLS / mutual-TLS test');
  Writeln(Format('  Target: %s', [BASE_URL]));
  Writeln('');
  try
    if SameText(ParamStr(1), 'mtls') then
      RunMutual
    else
      RunOneWay;
  except
    on E: Exception do
    begin
      Writeln('Fatal: ' + E.Message);
      Inc(GFailCount);
    end;
  end;

  Writeln('');
  Writeln(Format('Results: %d passed, %d failed', [GPassCount, GFailCount]));
  ExitCode := GFailCount;
end.
