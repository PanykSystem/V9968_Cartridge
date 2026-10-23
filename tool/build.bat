@echo off
setlocal
pushd "%~dp0"
zma.exe v9968upd.asm V9968UPD.COM
set result=%errorlevel%
popd
exit /b %result%
