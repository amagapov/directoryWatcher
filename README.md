Модуль предназначен для отслеживания файла с заданным именем в директории.
При обнаружении файла, его добавлении, переименовании или удалении в приложение отправляется соответствующее сообщение.

Использование модуля:

  FolderMonitor: TFolderMonitor;

  FolderMonitor := TFolderMonitor.Create(ExtractFilePath(ParamStr(0)), CODESITE_CONFIGFILENAME, Self.Handle);
  FolderMonitor.UseCodesiteInLaunchMode := cssUndefined;
  FolderMonitor.StartMonitor(logOptionsFileFound);

  procedure TMainFrm.AppMessage(var Msg: TMsg; var Handled: boolean);
  ...
    if Msg.message = UM_FOLDERMONITOREVENT then
      begin
        if FolderMonitor.UseCodesiteInLaunchMode = cssUndefined then
          case Msg.wParam of
            CODESITE_STOP: CodeSite.Enabled := False;
            CODESITE_START: CodeSite.Enabled := True;
            CODESITE_REFRESH: ;
          end;
      end
    else if Msg.message = UM_FOLDERMONITORERROR then
      begin
        if FolderMonitor.UseCodesiteInLaunchMode = cssUndefined then
          CodeSite.Enabled := False;
      end

  FolderMonitor.StopMonitor;
