@echo off
rem xenon launcher (windows cmd / powershell). add this bin folder to PATH, then: xenon help
setlocal
set "XENON_CWD=%CD%"
pushd "%~dp0.."
lune run xenon.luau %*
set "XENON_EXIT=%ERRORLEVEL%"
popd
exit /b %XENON_EXIT%
