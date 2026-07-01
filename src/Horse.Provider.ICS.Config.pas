unit Horse.Provider.ICS.Config;

(*
  Horse ICS Provider — Configuration record
  =========================================
  THorseICSConfig is the single configuration point for the OverbyteICS
  transport. Pure data record with no dependencies on Horse or ICS internals
  so it can be referenced by both the abstract base and the provider without
  circular units.

  Notable fields:
    - WorkerThreads — the off-loop pipeline pool. ICS runs every event on
      one message-loop thread; the Horse pipeline runs on this pool.
    - SSLEnabled + TLS fields — wired through to TSslContext on the
      TSslHttpServer instance. OpenSSL 3.x/4.x DLLs ship with ICS.

  Dual-compilation: Delphi only in v1.
*)

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils;
{$ELSE}
  System.SysUtils;
{$ENDIF}

const
  ICS_DEFAULT_WORKER_THREADS    = 16;
  ICS_DEFAULT_MAX_QUEUE_DEPTH   = 4096;
  ICS_DEFAULT_MAX_BODY_BYTES    = Int64(4) * 1024 * 1024;  // 4 MB
  ICS_DEFAULT_MAX_HEADER_COUNT  = 100;
  ICS_DEFAULT_DRAIN_TIMEOUT_MS  = 5000;
  ICS_DEFAULT_LISTEN_BACKLOG    = 511;
  ICS_DEFAULT_KEEPALIVE_TIME    = 30;   // seconds

type
  // Mirrors ICS TSslVersionMethod numerically; defined as plain integers so
  // this config unit stays free of ICS dependencies. The provider translates
  // these to the matching ICS enum at server-creation time.
  //   0 = sslBestVer (auto-negotiate up to TLS 1.3 — default)
  //   1 = TLS 1.2 only
  //   2 = TLS 1.3 only
  TICSSslMinVersion = (icsSslBest, icsSslTLS12, icsSslTLS13);

  THorseICSConfig = record
    // Off-loop worker pool — the Horse pipeline runs on these threads.
    // ICS forbids touching the socket off the loop thread, so each pipeline
    // result is marshaled back to the loop thread via a window message.
    // Default: 16. Range enforced by the pool: [4, 64].
    WorkerThreads:   Integer;

    // Maximum outstanding pipeline tasks before Submit raises 503.
    // Default: 4096.
    MaxQueueDepth:   Integer;

    // Maximum request body size (bytes). Enforced by TICSRequestBridge.
    // Default: 4 MB.
    MaxBodyBytes:    Int64;

    // Maximum number of headers per request. Excess headers dropped silently
    // to match the CrossSocket / mORMot providers.
    // Default: 100.
    MaxHeaderCount:  Integer;

    // Milliseconds to wait for in-flight pipeline tasks to drain on Stop.
    // Default: 5000.
    DrainTimeoutMs:  Integer;

    // TCP listen backlog (passed to THttpServer.ListenBacklog).
    // Default: 511.
    ListenBacklog:   Integer;

    // ICS keep-alive timeout in seconds (THttpConnection.KeepAliveTimeSec).
    // Default: 30.
    KeepAliveTimeSec: Cardinal;

    // HTTP Server: response banner. Empty → 'unknown' to avoid fingerprinting.
    ServerBanner:    string;

    // ── TLS / mTLS ──────────────────────────────────────────────────────────
    // Switch the server to TSslHttpServer + TSslContext.
    SSLEnabled:      Boolean;

    // Path to the server certificate file (PEM, OpenSSL 3.x).
    SSLCertFile:     string;

    // Path to the private key file (PEM, OpenSSL 3.x).
    SSLPrivKeyFile:  string;

    // CA bundle used for client-cert verification (mTLS). Optional.
    SSLCAFile:       string;

    // Passphrase for the private key (if encrypted).
    SSLPassPhrase:   string;

    // Require + verify client certificate (mutual TLS).
    SSLVerifyPeer:   Boolean;

    // Minimum negotiated TLS version.
    SSLVersionMethod: TICSSslMinVersion;

    // OpenSSL cipher list (empty → ICS default — sane modern ciphers).
    SSLCipherList:   string;

    class function Default: THorseICSConfig; static;
  end;

implementation

class function THorseICSConfig.Default: THorseICSConfig;
begin
  Result.WorkerThreads     := ICS_DEFAULT_WORKER_THREADS;
  Result.MaxQueueDepth     := ICS_DEFAULT_MAX_QUEUE_DEPTH;
  Result.MaxBodyBytes      := ICS_DEFAULT_MAX_BODY_BYTES;
  Result.MaxHeaderCount    := ICS_DEFAULT_MAX_HEADER_COUNT;
  Result.DrainTimeoutMs    := ICS_DEFAULT_DRAIN_TIMEOUT_MS;
  Result.ListenBacklog     := ICS_DEFAULT_LISTEN_BACKLOG;
  Result.KeepAliveTimeSec  := ICS_DEFAULT_KEEPALIVE_TIME;
  Result.ServerBanner      := '';
  Result.SSLEnabled        := False;
  Result.SSLCertFile       := '';
  Result.SSLPrivKeyFile    := '';
  Result.SSLCAFile         := '';
  Result.SSLPassPhrase     := '';
  Result.SSLVerifyPeer     := False;
  Result.SSLVersionMethod  := icsSslBest;
  Result.SSLCipherList     := '';
end;

end.
