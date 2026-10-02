@echo off
setlocal EnableDelayedExpansion
REM ===========================================================================
REM  run-tls-tests.bat  -  TLS / mutual-TLS integration tests (ICS provider)
REM
REM  Runs HorseICSTLSTestServer + HorseICSTLSTestClient in two passes:
REM    1. one-way TLS  (no argument)   -> T1, T2
REM    2. mutual TLS   (mtls argument) -> T3, T4
REM  then a third pass whose peer is openssl s_client, not our client:
REM    3. minimum TLS version (FIX-ICS-MINVER-1) -> M0..M4. SSLVersionMethod
REM       was written to an ICS property ICS ignores, so "TLS 1.3 only"
REM       served TLS 1.2. Needs openssl.exe on PATH; without it the pass is
REM       VOID (loud), never a pass.
REM    4. TLS 1.3 cipher suites (ICS-TLS13-SUITES-1) -> C0..C5. Same openssl
REM       peer and the same VOID rule. A misspelled suite beside a valid one
REM       is silently dropped by OpenSSL, so the server must refuse to start.
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

REM -- Build first, so the gate owns its inputs ------------------------------
REM  A stale .exe passes exactly as convincingly as a current one, and nothing
REM  in the result says which you ran. That cost four void results on
REM  2026-09-24 across these three suites; the CrossSocket one was caught only
REM  because code that had since been DELETED happened to still print a
REM  diagnostic line. Timestamp heuristics can be fooled and are awkward to get
REM  right in cmd; rebuilding costs ~2 seconds and removes the question.
REM
REM  A build failure is VOID, not FAILED: nothing was tested, so reporting a
REM  count of failed assertions would be a lie.
REM
REM  Pass  nobuild  to skip it (prebuilt binaries, or a CI stage that already
REM  built) - then staleness is yours to own again.
if /I "%~1"=="nobuild" goto :skip_build
echo === building (pass "nobuild" to skip) ===
call "%HERE%build-tls-dcc.bat"
if errorlevel 1 goto :build_failed
echo.
:skip_build

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
call :runminver
set /a TOTAL+=%ERRORLEVEL%
call :runsuites
set /a TOTAL+=%ERRORLEVEL%

echo.
echo ===========================================================================
if "%VOIDED%"=="1" goto :report_void
if not "%TOTAL%"=="0" goto :report_fail
echo  ALL PASSED - one-way TLS, mutual TLS, minimum TLS version, TLS 1.3 suites.
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

REM ---------------------------------------------------------------------------
REM Pass 3 - minimum TLS version. Judged by s_client's EXIT CODE plus its
REM "New, TLSv1.x" line, never by OpenSSL error text (3.0 and 3.6 word the
REM same failure differently). Control first: the default server must accept
REM the TLS 1.2 client that minver13 must refuse - otherwise a client that
REM cannot connect at all would read as enforcement. minver12 must STILL
REM serve TLS 1.3: the setting is a minimum, and a fix that pinned 1.2 would
REM silently remove TLS 1.3. A minver server that never binds is a FAIL, not
REM VOID: the provider now reads the minimum back and refuses to start when
REM it did not take, so not starting IS the defect reporting itself.
:runminver
echo.
echo ===========================================================================
echo  TLS pass: minimum protocol version  (openssl s_client peer)
echo ===========================================================================
set "OPENSSL="
for /f "delims=" %%I in ('where openssl.exe 2^>nul') do if not defined OPENSSL set "OPENSSL=%%I"
if not defined OPENSSL goto :mv_noopenssl
set /a MVFAIL=0

call :mv_server "" control
if "!SRVPID!"=="" goto :mv_end
call :mv_expect tls1_2 ok "New, TLSv1.2" "M0 control: default server serves a TLS 1.2 client"
call :mv_stop

call :mv_server "minver13" minver13
if "!SRVPID!"=="" goto :mv_end
call :mv_expect tls1_3 ok "New, TLSv1.3" "M1 icsSslTLS13: a TLS 1.3 client is served"
call :mv_expect tls1_2 refused "" "M2 icsSslTLS13: a TLS 1.2 client is REFUSED"
call :mv_stop

call :mv_server "minver12" minver12
if "!SRVPID!"=="" goto :mv_end
call :mv_expect tls1_2 ok "New, TLSv1.2" "M3 icsSslTLS12: a TLS 1.2 client is served"
call :mv_expect tls1_3 ok "New, TLSv1.3" "M4 icsSslTLS12 is a MINIMUM: TLS 1.3 is still served"
call :mv_stop

:mv_end
exit /b !MVFAIL!

:mv_noopenssl
echo    [VOID] openssl.exe is not on PATH - the minimum TLS version was NOT
echo           exercised. Add an OpenSSL bin directory to PATH and re-run.
set "VOIDED=1"
exit /b 0

REM mv_server <arg> <logname> - sets SRVPID, or leaves it empty after counting
REM the failure (or voiding the run when the port was already taken).
:mv_server
set "SRVPID="
set "ARG=%~1"
set "LOG=%BIN%\tls-%~2.log"
set "OWNER="
for /f "tokens=5" %%P in ('netstat -ano 2^>nul ^| findstr ":%TLS_PORT% " ^| findstr /I "LISTENING"') do set "OWNER=%%P"
if not "!OWNER!"=="" goto :port_busy
del /q "!LOG!" >nul 2>&1
pushd "%BIN%"
start "" /B cmd /c ""%SERVER_EXE%" !ARG! > "!LOG!" 2>&1"
popd
set /a TRIES=0
:mv_wait
for /f "tokens=5" %%P in ('netstat -ano 2^>nul ^| findstr ":%TLS_PORT% " ^| findstr /I "LISTENING"') do set "SRVPID=%%P"
if not "!SRVPID!"=="" goto :mv_bound
set /a TRIES+=1
if !TRIES! GEQ 20 goto :mv_nobind
ping -n 2 127.0.0.1 >nul 2>&1
goto :mv_wait
:mv_bound
echo    server [%~2] pid !SRVPID! listening on port %TLS_PORT%
exit /b 0
:mv_nobind
echo    FAIL  server [%~2] never bound port %TLS_PORT% - a refused minimum?
call :dumplog
set /a MVFAIL+=1
exit /b 0

:mv_stop
taskkill /PID !SRVPID! /F /T >nul 2>&1
set /a TRIES=0
:mv_stop_wait
set "OWNER="
for /f "tokens=5" %%P in ('netstat -ano 2^>nul ^| findstr ":%TLS_PORT% " ^| findstr /I "LISTENING"') do set "OWNER=%%P"
if "!OWNER!"=="" exit /b 0
set /a TRIES+=1
if !TRIES! GEQ 10 exit /b 0
ping -n 2 127.0.0.1 >nul 2>&1
goto :mv_stop_wait

REM mv_expect <s_client protocol flag> <ok|refused> <line expected when ok> <label>
:mv_expect
"!OPENSSL!" s_client -connect 127.0.0.1:%TLS_PORT% -%~1 < nul > "%BIN%\minver-s_client.log" 2>&1
set "MVRC=!ERRORLEVEL!"
if /I "%~2"=="ok" goto :mv_expect_ok
if "!MVRC!"=="0" goto :mv_expect_bad
echo    PASS  %~4
exit /b 0
:mv_expect_ok
if not "!MVRC!"=="0" goto :mv_expect_bad
findstr /L /C:"%~3" "%BIN%\minver-s_client.log" >nul 2>&1
if errorlevel 1 goto :mv_expect_bad
echo    PASS  %~4
exit /b 0
:mv_expect_bad
echo    FAIL  %~4  [s_client exit !MVRC!; see %BIN%\minver-s_client.log]
set /a MVFAIL+=1
exit /b 0

REM ---------------------------------------------------------------------------
REM Pass 4 - TLS 1.3 cipher suites (ICS-TLS13-SUITES-1). SSLCipherList reaches
REM only SSL_CTX_set_cipher_list, which never touches TLS 1.3; the new field
REM SSLCipherSuitesTLS13 reaches SSL_CTX_set_ciphersuites. Judged the same way
REM as pass 3: s_client exit code plus its "Cipher is <suite>" line. Control
REM first: the default server must serve the AES-128-GCM client that the
REM restricted server must refuse. C3 checks that restricting TLS 1.3 left
REM TLS 1.2 alone. C4/C5 are startup refusals: a server that comes up is the
REM defect (a dropped suite, served silently), and the refusal must name the
REM suite, or it is a FAIL as well.
:runsuites
echo.
echo ===========================================================================
echo  TLS pass: TLS 1.3 cipher suites  (openssl s_client peer)
echo ===========================================================================
set "OPENSSL="
for /f "delims=" %%I in ('where openssl.exe 2^>nul') do if not defined OPENSSL set "OPENSSL=%%I"
if not defined OPENSSL goto :cs_noopenssl
set /a MVFAIL=0

call :mv_server "" control13
if "!SRVPID!"=="" goto :cs_end
call :cs_expect "-tls1_3 -ciphersuites TLS_AES_128_GCM_SHA256" ok "Cipher is TLS_AES_128_GCM_SHA256" "C0 control: default server serves a TLS 1.3 AES-128-GCM client"
call :mv_stop

call :mv_server "suites13" suites13
if "!SRVPID!"=="" goto :cs_end
call :cs_expect "-tls1_3 -ciphersuites TLS_CHACHA20_POLY1305_SHA256" ok "Cipher is TLS_CHACHA20_POLY1305_SHA256" "C1 suites13: the configured suite is negotiated"
call :cs_expect "-tls1_3 -ciphersuites TLS_AES_128_GCM_SHA256" refused "" "C2 suites13: an excluded suite is REFUSED"
call :cs_expect "-tls1_2" ok "New, TLSv1.2" "C3 suites13: TLS 1.2 is untouched by the TLS 1.3 setting"
call :mv_stop

call :cs_refusal "suites13typo" suites13typo "TLS_AES_256_GCM_SHA348" "C4 a misspelled suite beside a valid one: Listen refuses, naming it"
call :cs_refusal "suites13bad" suites13bad "Fatal:" "C5 no valid suite at all: Listen refuses"

:cs_end
exit /b !MVFAIL!

:cs_noopenssl
echo    [VOID] openssl.exe is not on PATH - TLS 1.3 suites were NOT
echo           exercised. Add an OpenSSL bin directory to PATH and re-run.
set "VOIDED=1"
exit /b 0

REM cs_expect <s_client args> <ok|refused> <line expected when ok> <label>
:cs_expect
"!OPENSSL!" s_client -connect 127.0.0.1:%TLS_PORT% %~1 < nul > "%BIN%\suites-s_client.log" 2>&1
set "MVRC=!ERRORLEVEL!"
if /I "%~2"=="ok" goto :cs_expect_ok
if "!MVRC!"=="0" goto :cs_expect_bad
echo    PASS  %~4
exit /b 0
:cs_expect_ok
if not "!MVRC!"=="0" goto :cs_expect_bad
findstr /L /C:"%~3" "%BIN%\suites-s_client.log" >nul 2>&1
if errorlevel 1 goto :cs_expect_bad
echo    PASS  %~4
exit /b 0
:cs_expect_bad
echo    FAIL  %~4  [s_client exit !MVRC!; see %BIN%\suites-s_client.log]
set /a MVFAIL+=1
exit /b 0

REM cs_refusal <arg> <logname> <text the refusal must contain> <label>
REM PASS only when the server never binds AND its log names the cause.
:cs_refusal
set "ARG=%~1"
set "LOG=%BIN%\tls-%~2.log"
set "OWNER="
for /f "tokens=5" %%P in ('netstat -ano 2^>nul ^| findstr ":%TLS_PORT% " ^| findstr /I "LISTENING"') do set "OWNER=%%P"
if not "!OWNER!"=="" goto :port_busy
del /q "!LOG!" >nul 2>&1
pushd "%BIN%"
start "" /B cmd /c ""%SERVER_EXE%" !ARG! > "!LOG!" 2>&1"
popd
set /a TRIES=0
:cs_ref_wait
ping -n 2 127.0.0.1 >nul 2>&1
set "SRVPID="
for /f "tokens=5" %%P in ('netstat -ano 2^>nul ^| findstr ":%TLS_PORT% " ^| findstr /I "LISTENING"') do set "SRVPID=%%P"
if not "!SRVPID!"=="" goto :cs_ref_served
findstr /L /C:"%~3" "!LOG!" >nul 2>&1
if not errorlevel 1 goto :cs_ref_ok
set /a TRIES+=1
if !TRIES! GEQ 10 goto :cs_ref_silent
goto :cs_ref_wait
:cs_ref_ok
echo    PASS  %~4
exit /b 0
:cs_ref_served
echo    FAIL  %~4  [the server STARTED - the suite list was accepted]
taskkill /PID !SRVPID! /F /T >nul 2>&1
call :mv_stop
set /a MVFAIL+=1
exit /b 0
:cs_ref_silent
echo    FAIL  %~4  [no listener, but the log does not contain "%~3"]
call :dumplog
set /a MVFAIL+=1
exit /b 0

:build_failed
echo.
echo ===========================================================================
echo  VOID - the build failed, so nothing was tested. This is NOT a test
echo         failure; fix the build error above and run again.
echo ===========================================================================
exit /b 2
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
