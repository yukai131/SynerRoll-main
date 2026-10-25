!macro customInstall
  DetailPrint "Preparing PSFA Julia / HiGHS runtime. Please wait..."
  psfa_prepare:
  nsExec::ExecToStack '"$INSTDIR\resources\runtime\node\node.exe" "$INSTDIR\resources\app\prepare-runtime.cjs" "$INSTDIR"'
  Pop $0
  Pop $1
  ${If} $0 != 0
    DetailPrint "$1"
    IfSilent psfa_prepare_failed
    MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "PSFA runtime preparation failed.$\r$\n$1$\r$\nRetry preparation?" IDRETRY psfa_prepare
    psfa_prepare_failed:
    SetErrorLevel 1
    Abort "PSFA runtime preparation failed."
  ${EndIf}
!macroend
