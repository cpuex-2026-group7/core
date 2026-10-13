@echo off
rem build.bat - wrapper for _build.tcl (Windows cmd / PowerShell)
  rem usage: build.bat [all^|build^|program^|errors^|status^|timing [N]] [clean]
rem To use a specific Vivado:  set VIVADO=C:\Xilinx\Vivado\2024.2\bin\vivado.bat
setlocal
cd /d "%~dp0"

if not exist _build.tcl (
    echo *** _build.tcl not found in %CD%
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
set "ARGS="
if not "%~1"=="" set "ARGS=-tclargs %*"
call "%VIVADO%" -mode batch -nojournal -nolog -notrace -source _build.tcl %ARGS%
exit /b %ERRORLEVEL%
