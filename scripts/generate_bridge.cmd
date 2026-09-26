@echo off
setlocal
set "REPO_ROOT=%~dp0.."
set "PATH=%REPO_ROOT%\.toolchains\flutter\bin;%USERPROFILE%\.cargo\bin;%PATH%"
pushd "%REPO_ROOT%\app"
flutter_rust_bridge_codegen generate
set "RESULT=%ERRORLEVEL%"
popd
exit /b %RESULT%
