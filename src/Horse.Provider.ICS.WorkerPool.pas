unit Horse.Provider.ICS.WorkerPool;

(*
  Horse ICS Provider — Worker Thread Pool
  ========================================
  Off-loop pool for running the Horse pipeline.

  Why a pool? ICS runs on one message-loop thread; running THorse.Execute
  inline there would serialise the server. The provider snapshots each
  request on the loop thread and queues it here; one of these workers
  populates THorseRequest, runs THorse.Execute, and then PostMessages the
  response back to the loop thread for AnswerString.

  Implementation mirrors Horse.Provider.CrossSocket.WorkerPool with the
  same FIX-WP-1..4 lessons:
    [SEC-25] No exception swallowing (caller-provided OnTaskError logs).
    [SEC-26] Queue depth limit — Submit raises HTTP 503 when full.
    [SEC-27] Graceful shutdown drain.
    [SEC-28] Thread names for debuggability.
    [FIX-WP-4] TQueue<Pointer> avoids generic-over-anonymous-method compile
               errors on Delphi pre-10.4 — store IWorkerTask as raw Pointer
               with manual _AddRef / _Release.

  Dual-compilation: Delphi only in v1.
*)

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections;

const
  ICS_WORKER_POOL_MIN_THREADS  = 4;
  ICS_WORKER_POOL_MAX_THREADS  = 64;
  ICS_WORKER_MAX_QUEUE_DEPTH   = 4096;
  ICS_WORKER_SHUTDOWN_DRAIN_MS = 5000;

type
  IWorkerTask = interface
    ['{C0A1B2D3-E4F5-4061-9788-1AB2C3D4E5F6}']
    procedure Execute;
  end;

  TWorkerTask = reference to procedure;
  TWorkerErrorProc = reference to procedure(const E: Exception; ATaskIndex: Int64);

  TICSWorkerThread = class(TThread)
  private
    FPool:      TObject;
    FThreadIdx: Integer;
  protected
    procedure Execute; override;
  end;

  THorseICSWorkerPool = class
  private
    FQueue:        TQueue<Pointer>;
    FLock:         TCriticalSection;
    FWorkEvent:    TEvent;
    FDrainEvent:   TEvent;
    FThreads:      TList<TICSWorkerThread>;
    FShutdown:     Boolean;
    FThreadCount:  Integer;
    FRunningTasks: Integer;
    FTaskIndex:    Int64;
    FMaxQueueDepth: Integer;
    FOnTaskError:  TWorkerErrorProc;

    procedure SpawnThread(AIndex: Integer);
    procedure WorkerLoop(AThreadIdx: Integer);
    procedure TaskStarted;  inline;
    procedure TaskFinished; inline;
    procedure EnqueueTask(const ATask: TWorkerTask);
    function  DequeueTask(out ATask: IWorkerTask): Boolean;

  public
    constructor Create(AMinThreads, AMaxThreads, AMaxQueueDepth: Integer);
    destructor  Destroy; override;

    procedure Submit(ATask: TWorkerTask);

    property OnTaskError: TWorkerErrorProc read FOnTaskError write FOnTaskError;
    property ThreadCount: Integer read FThreadCount;

    class function  Instance: THorseICSWorkerPool;
    class procedure Initialize(
      AMinThreads:    Integer = ICS_WORKER_POOL_MIN_THREADS;
      AMaxThreads:    Integer = ICS_WORKER_POOL_MAX_THREADS;
      AMaxQueueDepth: Integer = ICS_WORKER_MAX_QUEUE_DEPTH
    );
    class procedure Finalize;
  end;

implementation

uses
  Horse.Commons,
  Horse.Exception;

var
  GHorseICSWorkerPool: THorseICSWorkerPool;

type
  TWorkerTaskWrapper = class(TInterfacedObject, IWorkerTask)
  private
    FProc: TWorkerTask;
  public
    constructor Create(const AProc: TWorkerTask);
    procedure Execute;
  end;

constructor TWorkerTaskWrapper.Create(const AProc: TWorkerTask);
begin
  inherited Create;
  FProc := AProc;
end;

procedure TWorkerTaskWrapper.Execute;
begin
  if Assigned(FProc) then
    FProc;
end;

{ TICSWorkerThread }

procedure TICSWorkerThread.Execute;
begin
  TThread.NameThreadForDebugging('HorseICSWorker-' + IntToStr(FThreadIdx));
  THorseICSWorkerPool(FPool).WorkerLoop(FThreadIdx);
end;

{ THorseICSWorkerPool }

constructor THorseICSWorkerPool.Create(AMinThreads, AMaxThreads,
  AMaxQueueDepth: Integer);
var
  I: Integer;
begin
  inherited Create;
  if AMinThreads < ICS_WORKER_POOL_MIN_THREADS then
    AMinThreads := ICS_WORKER_POOL_MIN_THREADS;
  if AMaxThreads > ICS_WORKER_POOL_MAX_THREADS then
    AMaxThreads := ICS_WORKER_POOL_MAX_THREADS;
  if AMinThreads > AMaxThreads then
    AMinThreads := AMaxThreads;
  if AMaxQueueDepth <= 0 then
    AMaxQueueDepth := ICS_WORKER_MAX_QUEUE_DEPTH;

  FQueue         := TQueue<Pointer>.Create;
  FLock          := TCriticalSection.Create;
  FWorkEvent     := TEvent.Create(nil, False, False, '');
  FDrainEvent    := TEvent.Create(nil, True,  True,  '');
  FThreads       := TList<TICSWorkerThread>.Create;
  FShutdown      := False;
  FThreadCount   := 0;
  FRunningTasks  := 0;
  FTaskIndex     := 0;
  FMaxQueueDepth := AMaxQueueDepth;

  FOnTaskError :=
    procedure(const E: Exception; ATaskIndex: Int64)
    begin
      System.WriteLn(ErrOutput,
        Format('[HorseICSWorkerPool] Task #%d raised %s: %s',
               [ATaskIndex, E.ClassName, E.Message]));
    end;

  for I := 0 to AMinThreads - 1 do
    SpawnThread(I);
end;

destructor THorseICSWorkerPool.Destroy;
var
  T:    TICSWorkerThread;
  Task: IWorkerTask;
begin
  FLock.Acquire;
  FShutdown := True;
  FLock.Release;

  for T in FThreads do
    FWorkEvent.SetEvent;

  if FRunningTasks > 0 then
    FDrainEvent.WaitFor(ICS_WORKER_SHUTDOWN_DRAIN_MS);

  for T in FThreads do
  begin
    T.WaitFor;
    T.Free;
  end;

  while DequeueTask(Task) do
    Task := nil;

  FThreads.Free;
  FQueue.Free;
  FWorkEvent.Free;
  FDrainEvent.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure THorseICSWorkerPool.EnqueueTask(const ATask: TWorkerTask);
var
  Wrapper: IWorkerTask;
  Ptr:     Pointer;
begin
  Wrapper := TWorkerTaskWrapper.Create(ATask);
  Ptr := Pointer(Wrapper);
  IInterface(Ptr)._AddRef;
  FQueue.Enqueue(Ptr);
end;

function THorseICSWorkerPool.DequeueTask(out ATask: IWorkerTask): Boolean;
var
  Ptr: Pointer;
begin
  Result := FQueue.Count > 0;
  if not Result then Exit;
  Ptr   := FQueue.Dequeue;
  ATask := IWorkerTask(Ptr);
  IInterface(Ptr)._Release;
end;

procedure THorseICSWorkerPool.SpawnThread(AIndex: Integer);
var
  T: TICSWorkerThread;
begin
  T                 := TICSWorkerThread.Create(True);
  T.FPool           := Self;
  T.FThreadIdx      := AIndex;
  T.FreeOnTerminate := False;
  FThreads.Add(T);
  Inc(FThreadCount);
  T.Start;
end;

procedure THorseICSWorkerPool.TaskStarted;
begin
  if TInterlocked.Increment(FRunningTasks) = 1 then
    FDrainEvent.ResetEvent;
end;

procedure THorseICSWorkerPool.TaskFinished;
begin
  if TInterlocked.Decrement(FRunningTasks) = 0 then
    FDrainEvent.SetEvent;
end;

procedure THorseICSWorkerPool.WorkerLoop(AThreadIdx: Integer);
var
  Task:    IWorkerTask;
  HasTask: Boolean;
  TaskIdx: Int64;
begin
  while True do
  begin
    FWorkEvent.WaitFor(INFINITE);
    while True do
    begin
      FLock.Acquire;
      try
        if FShutdown and (FQueue.Count = 0) then
        begin
          FWorkEvent.SetEvent;   // cascade to next worker
          Exit;
        end;
        HasTask := DequeueTask(Task);
        if FQueue.Count > 0 then
          FWorkEvent.SetEvent;
      finally
        FLock.Release;
      end;
      if not HasTask then Break;

      TaskIdx := TInterlocked.Increment(FTaskIndex);
      TaskStarted;
      try
        try
          Task.Execute;
        except
          on E: Exception do
            if Assigned(FOnTaskError) then
              FOnTaskError(E, TaskIdx);
        end;
      finally
        Task := nil;
        TaskFinished;
      end;
    end;
  end;
end;

procedure THorseICSWorkerPool.Submit(ATask: TWorkerTask);
var
  LEx: EHorseException;
begin
  FLock.Acquire;
  try
    if FShutdown then
    begin
      LEx := EHorseException.Create;
      LEx.Error('Server is shutting down').Status(THTTPStatus.ServiceUnavailable);
      raise LEx;
    end;
    if FQueue.Count >= FMaxQueueDepth then
    begin
      LEx := EHorseException.Create;
      LEx.Error('Worker queue full — server overloaded').Status(THTTPStatus.ServiceUnavailable);
      raise LEx;
    end;
    EnqueueTask(ATask);
  finally
    FLock.Release;
  end;
  FWorkEvent.SetEvent;
end;

class function THorseICSWorkerPool.Instance: THorseICSWorkerPool;
begin
  if not Assigned(GHorseICSWorkerPool) then
    Initialize;
  Result := GHorseICSWorkerPool;
end;

class procedure THorseICSWorkerPool.Initialize(
  AMinThreads, AMaxThreads, AMaxQueueDepth: Integer);
begin
  if not Assigned(GHorseICSWorkerPool) then
    GHorseICSWorkerPool :=
      THorseICSWorkerPool.Create(AMinThreads, AMaxThreads, AMaxQueueDepth);
end;

class procedure THorseICSWorkerPool.Finalize;
begin
  FreeAndNil(GHorseICSWorkerPool);
end;

initialization
  GHorseICSWorkerPool := nil;

finalization
  THorseICSWorkerPool.Finalize;

end.
