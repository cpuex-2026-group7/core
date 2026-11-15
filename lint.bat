@echo off
rem Run lint.py through WSL. Usage: lint.bat [options] [file ...]
setlocal
pushd "%~dp0" || exit /b 1

rem Accept Windows-style relative paths as well as forward slashes.
set "LINT_ARGS=%*"
wsl --exec python3 lint.py %LINT_ARGS:\=/%
set "LINT_EXIT_CODE=%ERRORLEVEL%"

popd
exit /b %LINT_EXIT_CODE%
