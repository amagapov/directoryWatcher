unit FolderMonitor;

interface

uses
  Windows, Messages, Classes, IniFiles, SysUtils;

const
  UM_FOLDERMONITOREVENT   = WM_USER + 101;
  UM_FOLDERMONITORERROR   = WM_USER + 102;
  CODESITE_STOP           = 0;
  CODESITE_START          = 1;
  CODESITE_REFRESH        = 2;
  FM_THREADFATALERROR     = 1;
  FM_THREADERROR          = 2;
  CODESITE_CONFIGFILENAME = 'Monitoring.ini';

type
  TFMParamKind = (pkWindow, pkThread);
  TCodeSiteStatus = (cssEnabled, cssDisabled, cssUndefined);
  TMonitoringStatus = (msStarted, msStopped);

  FILE_NOTIFY_INFORMATION = packed record
    NextEntryOffset: DWORD;
    Action: DWORD;
    FileNameLength: DWORD;
    FileName: array[0..0] of WideChar;
  end;

  PFILE_NOTIFY_INFORMATION = ^FILE_NOTIFY_INFORMATION;

  TOnFileEventEvent = procedure (aFlag: Byte) of object;
  TOnErrorEvent = procedure (const ErrMsg: string; errCode: Integer) of object;

  TMonitorThread = class(TThread)
  private
    FLogOptionFileNameT: string;
    FEventsToWait: array[0..1] of THandle;
    FDirectoryHandle: THandle;
    FOverlapped: OVERLAPPED;
    FBuffer: PChar;
    FOnFileEvent: TOnFileEventEvent;
    FOnError: TOnErrorEvent;
  protected
    procedure Execute; override;
    procedure DoOnFileEvent (aFlag: Byte); dynamic;
    procedure DoOnError (const ErrMsg: string); dynamic;
    procedure ParseNotificationBuffer (Buffer: PChar); dynamic;
  public
    constructor Create (AStopEvent, ADirectoryHandle: THandle; aLogOptionFileNameT: string);
    destructor Destroy; override;
    property OnFileEvent: TOnFileEventEvent read FOnFileEvent write FOnFileEvent;
    property OnError: TOnErrorEvent read FOnError write FOnError;
  end;

  TFolderMonitor = class
  private
    FMonitorThread: TMonitorThread;
    FDirectoryHandle: HFILE;
    FDirName: string;
    FBuffer: PChar;
    FHandle: DWORD;
    FStopEvent: THandle;
    FFMParamKind: TFMParamKind;
    FLogOptionsFileName: string;
    FTimePoint: Cardinal;
    FStatus: TMonitoringStatus;
    FThreadStartAttemtsNumber: Integer;
    FMonitoringIniFile: TIniFile;
    FTracingEnabled: Boolean;
    FUseCodesiteInLaunchMode: TCodeSiteStatus;
    function GetTracingEnabled: Boolean;
    procedure FileEvent(aFlag: Byte);
    procedure OnError(const ErrMsg: string; errCode: Integer);
    function ReadFolderContents: Boolean;
    procedure ThreadTerminated(Sender: TObject);
  public
    constructor Create (const ADirName, ALogOptionFileName: string; AHandle: DWORD; AFMParamKind: TFMParamKind = pkWindow);
    destructor Destroy; override;
    procedure StartMonitor(out logOptionsFileFound: Boolean);
    procedure StopMonitor;
    property DirName: string read FDirName;
    property TracingEnabled: Boolean read GetTracingEnabled;
    property UseCodesiteInLaunchMode: TCodeSiteStatus read FUseCodesiteInLaunchMode write FUseCodesiteInLaunchMode;
  end;

implementation

const
  FOLDER_MONITOR_BUFFER_SIZE = 65530;

{ TFolderMonitor }
constructor TFolderMonitor.Create(const ADirName, ALogOptionFileName: string; AHandle: DWORD; AFMParamKind: TFMParamKind);
begin
  FStatus := msStopped;
  FTimePoint := 0;
  FThreadStartAttemtsNumber := 0;
  FLogOptionsFileName := ALogOptionFileName;
  FHandle := AHandle;
  FFMParamKind := AFMParamKind;
  FDirectoryHandle := INVALID_HANDLE_VALUE;
  FDirName := ExcludeTrailingBackSlash(ADirName);
  FDirectoryHandle := CreateFile(
      PWideChar(ADirName),
      GENERIC_READ,
      FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
      nil,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OVERLAPPED,
      0);
  Win32Check(FDirectoryHandle <> INVALID_HANDLE_VALUE);
  FBuffer := AllocMem(FOLDER_MONITOR_BUFFER_SIZE);
  if not Assigned(FBuffer) then
    raise EOutOfMemory.Create('Not enough memory');
end;

destructor TFolderMonitor.Destroy;
begin
  if FStopEvent <> 0 then
    begin
      CloseHandle(FStopEvent);
      FStopEvent := 0;
    end;
  if Assigned(FBuffer) then
    begin
      FreeMem(FBuffer);
      FBuffer := nil;
    end;
  if FDirectoryHandle <> INVALID_HANDLE_VALUE then
    begin
      CloseHandle(FDirectoryHandle);
      FDirectoryHandle := INVALID_HANDLE_VALUE;
    end;
  inherited;
end;

procedure TFolderMonitor.FileEvent(aFlag: Byte);
var
  tc: Cardinal;
begin
  tc := GetTickCount;
  // для отправки только первого сообщения из очереди надо проверять интервал между сообщениями, так как
  // при создании файла генерируются два-три сообщения подряд: первое - FILE_ACTION_ADDED, второе и третье - FILE_ACTION_MODIFIED, отправляем только сообщение о создании
  // также при изменении файла следуют подряд два сообщения FILE_ACTION_MODIFIED - отправляем только одно
  if (tc - FTimePoint) > 50 then
    if FFMParamKind = pkWindow then
      PostMessage(HWND(FHandle), UM_FOLDERMONITOREVENT, WPARAM(aFlag), 0)
    else
      PostThreadMessage(FHandle, UM_FOLDERMONITOREVENT, WPARAM(aFlag), 0);
  FTimePoint := tc;
  case aFlag of
    CODESITE_STOP:
      begin
        if Assigned(FMonitoringIniFile) then
          FreeAndNil(FMonitoringIniFile);
        FTracingEnabled := False;
      end;
    CODESITE_START:
      begin
        if not Assigned(FMonitoringIniFile) then
          FMonitoringIniFile := TIniFile.Create(FDirName + '/' + FLogOptionsFileName);
        FTracingEnabled := (FMonitoringIniFile.ReadInteger('options', 'tracing', 0) = 1);
      end;
    CODESITE_REFRESH:
      FTracingEnabled := (FMonitoringIniFile.ReadInteger('options', 'tracing', 0) = 1);
  end;
end;

function TFolderMonitor.GetTracingEnabled: Boolean;
begin
  case FUseCodesiteInLaunchMode of
    cssEnabled: Result := True;
    cssDisabled: Result := False;
    cssUndefined:
      begin
        if FTracingEnabled then
          Result := (FMonitoringIniFile.ReadInteger('options', 'tracing', 0) = 1)
        else
          Result := False;
      end;
  end;
end;

procedure TFolderMonitor.OnError(const ErrMsg: string; errCode: Integer);
begin
  if FFMParamKind = pkWindow then
    PostMessage(HWND(FHandle), UM_FOLDERMONITORERROR, WPARAM(errCode), LPARAM(PChar(ErrMsg)))
  else
    PostThreadMessage(FHandle, UM_FOLDERMONITORERROR, WPARAM(errCode), LPARAM(PChar(ErrMsg)));
end;

function TFolderMonitor.ReadFolderContents: Boolean;
var
  Status: Integer;
  F: SysUtils.TSearchRec;
  OldDirectory: string;
begin
  Result := False;
  OldDirectory := GetCurrentDir;
  SetCurrentDir(FDirName);
  try
    Status := FindFirst(FLogOptionsFileName, faAnyFile, F);
    try
      if Status = 0 then
        if (F.Attr and faDirectory) = 0 then
          Result := True;
    finally
      FindClose(F);
    end;
  finally
    SetCurrentDir(OldDirectory);
  end;
end;

procedure TFolderMonitor.StartMonitor(out logOptionsFileFound: Boolean);
begin
  FStatus := msStarted;
  Inc(FThreadStartAttemtsNumber);
  FStopEvent := CreateEvent (nil, True, False, nil);
  Win32Check(FStopEvent <> 0);
  logOptionsFileFound := ReadFolderContents;
  if logOptionsFileFound then
    begin
      FMonitoringIniFile := TIniFile.Create(FDirName + '/' + FLogOptionsFileName);
      FTracingEnabled := (FMonitoringIniFile.ReadInteger('options', 'tracing', 0) = 1);
    end;
  FMonitorThread := TMonitorThread.Create (FStopEvent, FDirectoryHandle, FLogOptionsFileName);
  FMonitorThread.OnFileEvent := FileEvent;
  FMonitorThread.OnError := OnError;
  FMonitorThread.OnTerminate := ThreadTerminated;
  FMonitorThread.Start;
end;

procedure TFolderMonitor.StopMonitor;
begin
  FStatus := msStopped;
  SetEvent(FStopEvent);
  if not Assigned(FMonitorThread) then
    Exit;
  FMonitorThread.Terminate;
  FreeAndNil(FMonitorThread);
end;

procedure TFolderMonitor.ThreadTerminated(Sender: TObject);
var
  e: Exception;
  temp: Boolean;
begin
  e := ((Sender as TThread).FatalException as Exception);
  if e <> nil then
    if FThreadStartAttemtsNumber > 5 then
      begin
        StopMonitor;
        OnError(e.Message, FM_THREADFATALERROR);
        Exit;
      end;
  if FStatus = msStarted then
    StartMonitor(temp);
end;

{ TMonitorThread }
constructor TMonitorThread.Create(AStopEvent, ADirectoryHandle: THandle; ALogOptionFileNameT: string);
begin
  inherited Create(True);
  FLogOptionFileNameT := ALogOptionFileNameT;
  FEventsToWait[0] := AStopEvent;
  FEventsToWait[1] := CreateEvent(nil, True, False, nil);
  FillChar(FOverlapped, SizeOf(TOverlapped), 0);
  FOverlapped.hEvent := FEventsToWait[1];
  FDirectoryHandle := ADirectoryHandle;
  FBuffer := AllocMem(FOLDER_MONITOR_BUFFER_SIZE);
  if not Assigned(FBuffer) then
    SetEvent(AStopEvent);
end;

destructor TMonitorThread.Destroy;
begin
  CloseHandle(FEventsToWait[1]);
  if Assigned(FBuffer) then
    begin
      FreeMem (FBuffer);
      FBuffer := nil;
    end;
  inherited;
end;

procedure TMonitorThread.DoOnError(const ErrMsg: string);
begin
  if Assigned(FOnError) then
    FOnError(ErrMsg, FM_THREADERROR);
end;

procedure TMonitorThread.DoOnFileEvent(aFlag: Byte);
begin
  if Assigned(FOnFileEvent) then
    FOnFileEvent(aFlag);
end;

procedure TMonitorThread.ParseNotificationBuffer (Buffer: PChar);
var
  PEntry: PFILE_NOTIFY_INFORMATION;
  MoreEntries: Boolean;
  action: DWORD;
  fileName: string;
begin
  PEntry := PFILE_NOTIFY_INFORMATION(Buffer);
  MoreEntries := True;
  while MoreEntries do
    begin
      action := PEntry^.Action;
      fileName := WideCharLenToString(PEntry^.FileName, PEntry^.FileNameLength div SizeOf(WideChar));
      if fileName = FLogOptionFileNameT then
        case action of
          FILE_ACTION_ADDED:            DoOnFileEvent(CODESITE_START);
          FILE_ACTION_REMOVED:          DoOnFileEvent(CODESITE_STOP);
          FILE_ACTION_MODIFIED:         DoOnFileEvent(CODESITE_REFRESH);
          FILE_ACTION_RENAMED_OLD_NAME: DoOnFileEvent(CODESITE_STOP);
          FILE_ACTION_RENAMED_NEW_NAME: DoOnFileEvent(CODESITE_START);
        end;
      if (PEntry^.NextEntryOffset > 0) then
        PEntry := PFILE_NOTIFY_INFORMATION(DWORD(PEntry) + PEntry^.NextEntryOffset)
      else
        MoreEntries := False;
    end;
end;

procedure TMonitorThread.Execute;
var
  BytesRead: DWORD;
  WaitResult: DWORD;
begin
  // не уничтожен ли текущий поток еще при создании
  if WaitForSingleObject(FEventsToWait[0], 1) <> WAIT_TIMEOUT then
    Exit;
  while not Terminated do
    begin
      if not ReadDirectoryChangesW(
                FDirectoryHandle,
                FBuffer,
                FOLDER_MONITOR_BUFFER_SIZE,
                False,
                FILE_NOTIFY_CHANGE_FILE_NAME or FILE_NOTIFY_CHANGE_LAST_WRITE,
                @BytesRead,
                @FOverlapped,
                nil) then
        begin
          DoOnError(SysErrorMessage(GetLastError));
          Terminate;
          Break; // невозможно поставить запрос наблюдения каталога в очередь
        end;
      WaitResult := WaitForMultipleObjects(2, @FEventsToWait, False, INFINITE);
      if WaitResult = WAIT_OBJECT_0 then
        begin
          Terminate;
          Break; // получен внешний запрос на окончание наблюдения
        end
      else if WaitResult <> WAIT_OBJECT_0 + 1 then
        begin
          DoOnError(SysErrorMessage(GetLastError));
          Terminate;
          Break; // неизвестная ошибка
        end
      else
        begin
          // закончилась операция чтения изменений в каталоге
          if not GetOverlappedResult (FDirectoryHandle, FOverlapped, BytesRead, False) then
            begin
              DoOnError(SysErrorMessage(GetLastError));
              Terminate;
              Break;  // неизвестная ошибка при попытке получения результата окончания
                      // асинхронной операции ввода-вывода
            end;
          // сейчас в буфере находится BytesRead байт информации об изменениях в каталоге
          try
            ParseNotificationBuffer(FBuffer);
          except
          end;
        end;
    end;
end;

end.
