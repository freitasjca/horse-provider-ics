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
  // MINIMUM negotiated TLS version. Kept free of ICS types so this config unit
  // has no ICS dependency; the provider maps it to ICS's SslMinVersion at
  // server-creation time and reads the result back from the OpenSSL context.
  //   icsSslBest  = ICS / OpenSSL default floor (default)
  //   icsSslTLS12 = TLS 1.2 minimum - TLS 1.3 is still allowed
  //   icsSslTLS13 = TLS 1.3 minimum, i.e. TLS 1.3 only
  // [FIX-ICS-MINVER-1] Before provider v1.0.9 this was written to ICS's
  // SslVersionMethod, which ICS ignores, so NO value had any effect.
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

    // Require + verify client certificate (mutual TLS). Set SSLCAFile too, or
    // there is nothing to verify against.
    // Genuinely REQUIRES a certificate as of FIX-ICS-MTLS-1 (2026-09-24). Before
    // that this field set ICS's SslVerifyPeer alone, which only *requests* one:
    // clients that declined were served anyway, so mTLS was configurable but
    // never enforced. Verified by tests\run-tls-tests.bat (T4).
    SSLVerifyPeer:   Boolean;

    // Minimum negotiated TLS version (see TICSSslMinVersion). Enforced and
    // verified at Listen since v1.0.9; ignored before.
    SSLVersionMethod: TICSSslMinVersion;

    // TLS 1.2-and-below cipher RULES in OpenSSL syntax (SSL_CTX_set_cipher_list),
    // e.g. 'ECDHE+AESGCM:!aNULL'. Empty = ICS default. Does NOT affect TLS 1.3,
    // which OpenSSL configures separately - use SSLCipherSuitesTLS13 for that.
    // An @SECLEVEL=n here does set the context-wide security level, which TLS
    // 1.3 handshakes also obey.
    SSLCipherList:   string;

    // TLS 1.3 cipher SUITES (SSL_CTX_set_ciphersuites): exact, case-sensitive
    // names, colon-separated, in priority order, e.g.
    // 'TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256'. Empty = ICS's
    // default (sslCipherSuitesTLS13: AES-256-GCM, CHACHA20, AES-128-GCM).
    // OpenSSL silently DROPS a misspelled name that sits beside a valid one,
    // so Listen reads the effective list back and raises, naming every
    // requested suite OpenSSL did not keep (ICS-TLS13-SUITES-1, v1.0.10).
    SSLCipherSuitesTLS13: string;

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
  Result.SSLCipherSuitesTLS13 := '';
end;

end.
