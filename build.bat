@echo off
rem build.bat - same as make:  build.bat ^<command^> [target] [CLOCK=100] [N=20] [SYNTH=1] [CLEAN=1] [ALL=1] [STRICT=1] [V=1]
rem   build.bat help   shows the usage. The scripts are in launch\ (cli.ps1 -^> run.bat -^> flow.tcl, lint.py)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch\cli.ps1" %*
exit /b %ERRORLEVEL%
