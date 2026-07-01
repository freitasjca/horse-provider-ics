unit Horse.Provider.ICS.Pool;

(*
  Horse ICS Provider — Context Object Pool
  ========================================
  Pre-allocates THorseContext objects so the hot path never has to allocate
  a fresh THorseRequest/THorseResponse pair.

  ── Prerequisite: Horse fork patches ───────────────────────────────────────
    PATCH-REQ-1 (Horse.Request.pas)   parameterless constructor
    PATCH-REQ-2 (Horse.Request.pas)   THorseRequest.Clear
    PATCH-RES-2 (Horse.Response.pas)  THorseResponse.Clear

  ── ICS-specific ownership note ─────────────────────────────────────────────
  THorseRequest.FBody is never assigned a live TStream on this path — the
  ICS request body is captured by TICSRequestBridge.Snapshot as a Pascal
  string and stored via SetBodyString (PATCH-REQ-9). Clear sets FBody := nil
  without freeing, which is safe.

  Mirrors Horse.Provider.Mormot.Pool / Horse.Provider.CrossSocket.Pool.

  Security tags reused from the mORMot pool:
    [SEC-7]  Complete Reset via patched Clear methods.
    [SEC-8]  DEBUG double-acquire/release guard.
    [SEC-9]  FBody nil throughout — Clear, never Body(nil).
    [SEC-10] IdleCount read via TInterlocked.
    [SEC-11] WarmUp outside the lock.

  Dual-compilation: Delphi (FPC seam reserved for ICS_Lazarus).
*)

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
  Classes,
  SyncObjs,
  Generics.Collections,
{$ELSE}
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
{$ENDIF}
  Horse.Request,
  Horse.Response;

const
  POOL_MAX_SIZE    = 512;
  POOL_WARMUP_SIZE = 32;

type
  THorseContext = class
  private
    FRequest:  THorseRequest;
    FResponse: THorseResponse;
    FInUse:    Boolean;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure Reset;

    property Request:  THorseRequest  read FRequest;
    property Response: THorseResponse read FResponse;
    property InUse:    Boolean        read FInUse write FInUse;
  end;

  THorseContextPool = class
  private
    class var FPool:      TStack<THorseContext>;
    class var FLock:      TCriticalSection;
    class var FIdleCount: Integer;

    class procedure InternalWarmUp;
  public
    class constructor Create;
    class destructor  Destroy;

    class function  Acquire: THorseContext;
    class procedure Release(AContext: THorseContext);
    class function  IdleCount: Integer; inline;
  end;

implementation

{ THorseContext }

constructor THorseContext.Create;
begin
  inherited Create;
  FRequest  := THorseRequest.Create;       // PATCH-REQ-1
  FResponse := THorseResponse.Create(nil);
  FInUse    := False;
end;

destructor THorseContext.Destroy;
begin
  // [SEC-9] FBody is always nil on the ICS path (snapshot-based, string body).
  // Clear (PATCH-REQ-2) clears it without freeing — safe.
  FRequest.Clear;
  FRequest.Free;
  FResponse.Free;
  inherited Destroy;
end;

procedure THorseContext.Reset;
begin
  FRequest.Clear;     // PATCH-REQ-2
  FResponse.Clear;    // PATCH-RES-2
  FInUse := False;
end;

{ THorseContextPool }

class constructor THorseContextPool.Create;
begin
  FPool      := TStack<THorseContext>.Create;
  FLock      := TCriticalSection.Create;
  FIdleCount := 0;
  InternalWarmUp;     // [SEC-11]
end;

class destructor THorseContextPool.Destroy;
var
  Ctx: THorseContext;
begin
  FLock.Acquire;
  try
    while FPool.Count > 0 do
    begin
      Ctx := FPool.Pop;
      Ctx.Free;
    end;
    FIdleCount := 0;
  finally
    FLock.Release;
  end;
  FPool.Free;
  FLock.Free;
end;

class procedure THorseContextPool.InternalWarmUp;
var
  I:     Integer;
  Batch: array[0..POOL_WARMUP_SIZE - 1] of THorseContext;
begin
  for I := 0 to POOL_WARMUP_SIZE - 1 do
    Batch[I] := THorseContext.Create;
  FLock.Acquire;
  try
    for I := 0 to POOL_WARMUP_SIZE - 1 do
    begin
      FPool.Push(Batch[I]);
      Inc(FIdleCount);
    end;
  finally
    FLock.Release;
  end;
end;

class function THorseContextPool.Acquire: THorseContext;
begin
  FLock.Acquire;
  try
    if FPool.Count > 0 then
    begin
      Result := FPool.Pop;
      Dec(FIdleCount);
    end
    else
      Result := THorseContext.Create;
  finally
    FLock.Release;
  end;
  {$IFDEF DEBUG}
  Assert(not Result.InUse,
    'THorseContextPool.Acquire: context already marked in-use (double-acquire?)');
  {$ENDIF}
  Result.InUse := True;
end;

class procedure THorseContextPool.Release(AContext: THorseContext);
begin
  if AContext = nil then Exit;
  {$IFDEF DEBUG}
  Assert(AContext.InUse,
    'THorseContextPool.Release: context was not acquired (double-release?)');
  {$ENDIF}
  try
    AContext.Reset;
  except
    AContext.Free;
    Exit;
  end;
  FLock.Acquire;
  try
    if FIdleCount < POOL_MAX_SIZE then
    begin
      FPool.Push(AContext);
      Inc(FIdleCount);
    end
    else
      AContext.Free;
  finally
    FLock.Release;
  end;
end;

class function THorseContextPool.IdleCount: Integer;
begin
  Result := TInterlocked.CompareExchange(FIdleCount, 0, 0);
end;

end.
