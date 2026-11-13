@echo off
rem launch\run.bat - find Vivado and run launch\flow.tcl (called by build.bat and make)
rem usage: run.bat [all^|build^|program^|errors^|status^|timing^|ip^|view^|open] [top^|backend^|module] [synth] [N] [100mhz^|10ns] [clean]
rem To use a specific Vivado:  set VIVADO=C:\Xilinx\Vivado\2024.2\bin\vivado.bat
setlocal
cd /d "%~dp0.."

if not exist launch\flow.tcl (
    echo *** launch\flow.tcl not found in %CD%
    exit /b 1
)

if defined VIVADO goto run

where vivado.bat >nul 2>&1
if not errorlevel 1 (
    set "VIVADO=vivado.bat"
    goto run
)

rem search common install dirs (alphabetical order -> last one = newest)
for /d %%D in ("C:\Xilinx\Vivado\*") do if exist "%%D\bin\vivado.bat" set "VIVADO=%%D\bin\vivado.bat"
for /d %%D in ("C:\Xilinx\*") do if exist "%%D\Vivado\bin\vivado.bat" set "VIVADO=%%D\Vivado\bin\vivado.bat"
for /d %%D in ("C:\AMDDesignTools\*") do if exist "%%D\Vivado\bin\vivado.bat" set "VIVADO=%%D\Vivado\bin\vivado.bat"

if not defined VIVADO (
    echo *** vivado not found. Add its bin dir to PATH or: set VIVADO=C:\path\to\vivado.bat
    exit /b 1
)

:run
echo [build] Vivado: %VIVADO%
set "VIEW="
set "OPEN="
for %%A in (%*) do if /i "%%~A"=="view" set "VIEW=1"
for %%A in (%*) do if /i "%%~A"=="open" set "OPEN=1"

rem open: no build, just open the previous result in the GUI
if defined OPEN goto gui

set "ARGS="
if not "%~1"=="" set "ARGS=-tclargs %*"
call "%VIVADO%" -mode batch -nojournal -nolog -notrace -source launch\boot.tcl %ARGS%
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" exit /b %RC%

rem view: build OK -> open the result in the Vivado GUI
if not defined VIEW exit /b 0

:gui
echo [build] opening the result in the Vivado GUI ...
start "" /b "%VIVADO%" -mode gui -nojournal -nolog -notrace -source launch\boot.tcl -tclargs %* gui
exit /b 0
