@echo off
setlocal EnableDelayedExpansion
REM ===========================================================================
REM  run-tls-tests.bat  -  TLS / mutual-TLS integration tests (ICS provider)
REM
REM  Runs HorseICSTLSTestServer + HorseICSTLSTestClient in two passes:
REM    1. one-way TLS  (no argument)   -> T1, T2
REM    2. mutual TLS   (mtls argument) -> T3, T4
REM
REM  Usage:  run-tls-tests.bat        (build first with build-tls-dcc.bat)
REM  Exit code: 0 = all passed, N = N failed assertions, 2 = VOID (nothing ran).
REM
REM  ---------------------------------------------------------------------
REM  VOID is a distinct code because every trap here produces a GREEN result
REM  rather than a red one:
REM
REM  1. A stale server makes a fresh one look healthy. Windows lets a second
REM     process bind an already-owned port without error, so "port is
REM     LISTENING" proves nothing about WHOSE server answers the client. This
REM     requires the port to be FREE before starting, and records the PID that
REM     actually takes it.
REM
REM  2. taskkill /IM truncates image names at 25 characters.
REM     "HorseICSTLSTestServer.exe" is 25 and only just fits; the sibling
REM     mORMot suite's 28-character name does not, and a kill that matches
REM     nothing still reports success. We kill by PID and sidestep it.
REM
REM  3. A stale BINARY passes just as convincingly as a current one. The
REM     CrossSocket suite reported ALL PASSED from three-week-old exes still
REM     carrying code that had since been deleted. Rebuild before believing a
REM     result.
REM
REM  What this suite genuinely proves: T1/T2 go over HTTPS through
REM  TCrossHttpClient, so a server not actually speaking TLS fails the
REM  handshake and they go red. T4 alone is weak -- it only asserts "not 200".
REM
REM  No parenthesised blocks; ping rather than timeout for the wait.
REM  ---------------------------------------------------------------------
REM ===========================================================================

set "HERE=%~dp0"
set "BIN=%HERE%bin"
set "SERVER_EXE=%BIN%\HorseICSTLSTestServer.exe"
set "CLIENT_EXE=%BIN%\HorseICSTLSTestClient.exe"
set "TLS_PORT=9111"

if not exist "%SERVER_EXE%" goto :not_built
if not exist "%CLIENT_EXE%" goto :not_built
if not exist "%BIN%\certs\server.crt" goto :no_certs

REM  ICS ships its own OpenSSL; build-tls-dcc.bat copies it from ICS-OpenSSL\.
REM  Without it the handshake fails while the server still reports listening.
set "HAVESSL="
for /f "delims=" %%F in ('dir /b "%BIN%\libssl*-x64.dll" 2^>nul') do set "HAVESSL=1"
if not defined HAVESSL goto :no_openssl

set "VOIDED=0"
set /a TOTAL=0

call :runpass "" "one-way TLS" oneway
set /a TOTAL+=%ERRORLEVEL%
call :runpass "mtls" "mutual TLS" mtls
set /a TOTAL+=%ERRORLEVEL%

echo.
echo ===========================================================================
if "%VOIDED%"=="1" goto :report_void
if not "%TOTAL%"=="0" goto :report_fail
echo  ALL PASSED - one-way TLS and mutual TLS.
echo ===========================================================================
exit /b 0
:report_fail
echo  FAILED - %TOTAL% assertion^(s^). Server logs: %BIN%\tls-*.log
echo ===========================================================================
exit /b %TOTAL%
:report_void
echo  VOID - the suite did not run. This is NOT a pass; see the reason above.
echo ===========================================================================
exit /b 2

REM ---------------------------------------------------------------------------
:runpass
set "ARG=%~1"
set "LABEL=%~2"
set "LOG=%BIN%\tls-%~3.log"
echo.
echo ===========================================================================
echo  TLS pass: !LABEL!
echo ===========================================================================

set "OWNER="
for /f "tokens=5" %%P in ('netstat -ano 2^>nul ^| findstr ":%TLS_PORT% " ^| findstr /I "LISTENING"') do set "OWNER=%%P"
echo    pre-check: port %TLS_PORT% owner=[!OWNER!]
if not "!OWNER!"=="" goto :port_busy

del /q "!LOG!" >nul 2>&1
pushd "%BIN%"
start "" /B cmd /c ""%SERVER_EXE%" !ARG! > "!LOG!" 2>&1"
popd

set /a TRIES=0
:wait_loop
set "SRVPID="
for /f "tokens=5" %%P in ('netstat -ano 2^>nul ^| findstr ":%TLS_PORT% " ^| findstr /I "LISTENING"') do set "SRVPID=%%P"
if not "!SRVPID!"=="" goto :bound
set /a TRIES+=1
if !TRIES! GEQ 20 goto :no_bind
ping -n 2 127.0.0.1 >nul 2>&1
goto :wait_loop

:bound
echo    server pid !SRVPID! listening on port %TLS_PORT%

"%CLIENT_EXE%" !ARG!
set "PASS_EXIT=!ERRORLEVEL!"

taskkill /PID !SRVPID! /F /T >nul 2>&1
exit /b !PASS_EXIT!

:port_busy
echo    [VOID] port %TLS_PORT% is already held by pid !OWNER!.
echo           Windows would let our server bind anyway and the client could
echo           then be testing the OTHER process. Stop it first:
echo             taskkill /PID !OWNER! /F
set "VOIDED=1"
exit /b 0

:no_bind
echo    [VOID] server never bound port %TLS_PORT% within 20 tries.
call :dumplog
set "VOIDED=1"
exit /b 0

:dumplog
echo    ---- server output ----
if exist "!LOG!" type "!LOG!"
echo    -----------------------
exit /b 0

:not_built
echo ERROR: the TLS test binaries are not built. Run:
echo          build-tls-dcc.bat
exit /b 2
:no_certs
echo ERROR: %BIN%\certs\server.crt not found - build-tls-dcc.bat copies them.
exit /b 2
:no_openssl
echo ERROR: no libssl*-x64.dll beside the binaries in %BIN%.
echo        ICS needs its OpenSSL at run time; without it the server starts,
echo        reports itself listening, and fails every handshake.
echo        build-tls-dcc.bat copies them from icsv97\ICS-OpenSSL\.
exit /b 2
