@echo off
setlocal enabledelayedexpansion
REM ===========================================================================
REM  build-tls-dcc.bat
REM  Build HorseICSTLSTestServer / HorseICSTLSTestClient by invoking dcc64
REM  DIRECTLY. Run them with run-tls-tests.bat once this reports BUILD OK.
REM
REM  ---------------------------------------------------------------------
REM  Why this script exists
REM
REM  The ICS TLS tests have no .dproj, unlike the param tests beside them. They
REM  were written, documented in TLS-TESTS.md and never made buildable - so the
REM  repo has shipped a description of a suite nobody could run since 2026-06,
REM  and the provider source says as much: "SSL is not exercised by the current
REM  test suite". The sibling mORMot suite was in exactly this state until
REM  2026-09-24, and running it for the first time found a defect that had made
REM  its TLS serve plain TCP for three months.
REM
REM  msbuild is not the way to fix that here: MSBuild's DCC task emits the IDE's
REM  entire global Library Path four times over (once each for -I/-O/-R/-U)
REM  against a 32000-character ceiling, so projects die on MSB6002/MSB6003
REM  before compiling. This drives the compiler directly, as the IDE does.
REM
REM  The two programs need DIFFERENT unit paths, which is why they are built
REM  separately below: the SERVER is Horse + ICS, and the CLIENT is the shared
REM  TCrossHttpClient HTTPS driver from Delphi-Cross-Socket that all three
REM  provider TLS suites use. Both path lists are taken from the neighbouring
REM  HorseICSParamTest*.dproj files, which already build.
REM
REM  No parenthesised blocks - same cmd quirk the sibling scripts document.
REM  ---------------------------------------------------------------------
REM
REM  Usage:  build-tls-dcc.bat [Release^|Debug]      (default Release)
REM          set ICS_ROOT=<path>  to override C:\lang\Repo\icsv97
REM  Win64 only. Run from this tests\ folder.
REM ===========================================================================

set "TGTCONFIG=%~1"
if "!TGTCONFIG!"=="" set "TGTCONFIG=Release"
if /I "!TGTCONFIG!"=="Release" goto :cfg_ok
if /I "!TGTCONFIG!"=="Debug"   goto :cfg_ok
echo ERROR: config must be Release or Debug, got "!TGTCONFIG!".
exit /b 2
:cfg_ok

REM -- Locate dcc64 ----------------------------------------------------------
if not "%DELPHI_ROOT%"=="" if exist "%DELPHI_ROOT%\bin\dcc64.exe" set "DCC=%DELPHI_ROOT%\bin\dcc64.exe"
if not defined DCC for %%V in (23.0 22.0 21.0 20.0 19.0) do call :try_version %%V
if not defined DCC for /f "delims=" %%I in ('where dcc64.exe 2^>nul') do if not defined DCC set "DCC=%%I"
if not defined DCC goto :no_dcc

for %%I in ("!DCC!") do set "DCCDIR=%%~dpI"
for %%I in ("!DCCDIR!..") do set "BDSROOT=%%~fI"
set "RTL=!BDSROOT!\lib\Win64\release"
if /I "!TGTCONFIG!"=="Debug" set "RTL=!BDSROOT!\lib\Win64\debug"
if not exist "!RTL!" goto :no_rtl

REM -- Source roots ----------------------------------------------------------
for %%I in ("%~dp0..") do set "PROV=%%~fI"
for %%I in ("!PROV!\..") do set "ROOT=%%~fI"
if not defined ICS_ROOT set "ICS_ROOT=!ROOT!\icsv97"

if not exist "!PROV!\src\Horse.Provider.ICS.Config.pas" goto :no_prov
if not exist "!ICS_ROOT!\Source"                        goto :no_ics

REM  ICS keeps its .inc files alongside the units, and some distributions add a
REM  Source\Include as well. Add it only if present rather than assuming.
set "ICSPATH=!ICS_ROOT!\Source"
if exist "!ICS_ROOT!\Source\Include" set "ICSPATH=!ICSPATH!;!ICS_ROOT!\Source\Include"

REM  SERVER: Horse + the ICS provider + ICS itself.
set "SPATH=!RTL!;!PROV!\src;!ROOT!\horse\src;!ICSPATH!"

REM  CLIENT: the TCrossHttpClient HTTPS driver, i.e. Delphi-Cross-Socket.
set "CPATH=!RTL!;!ROOT!\Delphi-Cross-Socket;!ROOT!\Delphi-Cross-Socket\Net"
set "CPATH=!CPATH!;!ROOT!\Delphi-Cross-Socket\Utils;!ROOT!\Delphi-Cross-Socket\DelphiToFPC"
set "CPATH=!CPATH!;!ROOT!\Delphi-Cross-Socket\CnPack\Common;!ROOT!\Delphi-Cross-Socket\CnPack\Crypto"

set "NS=Winapi;System.Win;Data.Win;Datasnap.Win;Web.Win;Soap.Win;Xml.Win;System;Xml;Data;Datasnap;Web;Soap"
set "ALIAS=Generics.Collections=System.Generics.Collections;Generics.Defaults=System.Generics.Defaults;WinTypes=Winapi.Windows;WinProcs=Winapi.Windows;DbiTypes=BDE;DbiProcs=BDE;DbiErrs=BDE"
set "DEFS=!TGTCONFIG!;HORSE_PROVIDER_ICS"
set "OPTS=--no-config -B -Q -TX.exe"
if /I "!TGTCONFIG!"=="Release" set "OPTS=!OPTS! -$D0 -$L- -$Y-"

set "EXEDIR=%~dp0bin"
set "DCUDIR=%~dp0temp"
if not exist "!EXEDIR!" mkdir "!EXEDIR!" 2>nul
if not exist "!DCUDIR!" mkdir "!DCUDIR!" 2>nul

echo dcc64:  !DCC!
echo config: !TGTCONFIG!
echo ICS:    !ICS_ROOT!\Source
echo out:    !EXEDIR!
echo.

set "FAILED=0"
call :build HorseICSTLSTestServer "!SPATH!"
call :build HorseICSTLSTestClient "!CPATH!"
if not "!FAILED!"=="0" goto :done_fail

if not exist "%~dp0certs\server.crt" goto :no_certs
if not exist "!EXEDIR!\certs" mkdir "!EXEDIR!\certs" 2>nul
copy /y "%~dp0certs\*" "!EXEDIR!\certs\" >nul

REM -- OpenSSL runtime. ICS ships its own DLLs, but their location varies by
REM    distribution, so find them rather than assume a folder. Without them the
REM    server starts, reports itself listening, and fails every handshake --
REM    the exact silent failure the mORMot suite hit.
set "SSLSRC="
for /f "delims=" %%F in ('dir /s /b "!ICS_ROOT!\*libssl*-x64.dll" 2^>nul') do if not defined SSLSRC set "SSLSRC=%%~dpF"
if not defined SSLSRC goto :warn_openssl
copy /y "!SSLSRC!*-x64.dll" "!EXEDIR!\" >nul 2>&1
echo openssl: copied from !SSLSRC!
goto :done_ok

:warn_openssl
echo.
echo WARNING: no libssl*-x64.dll found under !ICS_ROOT!.
echo          ICS normally ships its OpenSSL DLLs; if TLS fails at handshake
echo          time with the server still reporting "Listening", copy a matching
echo          libssl/libcrypto x64 pair into !EXEDIR! by hand.

:done_ok
echo.
echo ===========================================================================
echo  BUILD OK
echo.
echo  Run:  run-tls-tests.bat        (both passes, exit 0 / N failed / 2 VOID)
echo.
echo  Or by hand, from !EXEDIR!, in two terminals:
echo    one-way TLS:   HorseICSTLSTestServer          then  HorseICSTLSTestClient
echo    mutual TLS:    HorseICSTLSTestServer mtls     then  HorseICSTLSTestClient mtls
echo ===========================================================================
exit /b 0

:build
set "NAME=%~1"
set "UPATH=%~2"
if not exist "%~dp0!NAME!.dpr" goto :build_missing
echo -- !NAME! -----------------------------------------------------------
pushd "%~dp0"
"!DCC!" !OPTS! -A!ALIAS! -D!DEFS! -NS!NS! ^
  -U"!UPATH!" -I"!UPATH!" -R"!UPATH!" -O"!UPATH!" ^
  -E"!EXEDIR!" -N0"!DCUDIR!" -NU"!DCUDIR!" ^
  "!NAME!.dpr"
if errorlevel 1 goto :build_err
popd
echo    OK
exit /b 0
:build_err
popd
echo    FAILED - a real compiler error, look for [dcc64 Error] above
set "FAILED=1"
exit /b 0
:build_missing
echo    MISSING !NAME!.dpr
set "FAILED=1"
exit /b 0

:try_version
set "CAND=%ProgramFiles(x86)%\Embarcadero\Studio\%~1\bin\dcc64.exe"
if exist "!CAND!" if not defined DCC set "DCC=!CAND!"
exit /b 0

:no_dcc
echo ERROR: dcc64.exe not found. Set DELPHI_ROOT, e.g.
echo        set "DELPHI_ROOT=C:\Program Files (x86)\Embarcadero\Studio\23.0"
exit /b 2
:no_rtl
echo ERROR: Win64 RTL not found at !RTL!
exit /b 2
:no_prov
echo ERROR: provider source not found at !PROV!\src
exit /b 2
:no_ics
echo ERROR: ICS source not found at !ICS_ROOT!\Source
echo        Expected the sibling checkout layout: ^<root^>\icsv97, ^<root^>\horse, ...
echo        Override with:  set "ICS_ROOT=<path to icsv97>"
exit /b 2
:no_certs
echo ERROR: certs\server.crt not found next to this script.
exit /b 2
:done_fail
echo.
echo BUILD FAILED - see above.
exit /b 1
