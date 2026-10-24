@echo off
setlocal
pushd "%~dp0"
if not exist work vlib work
vlog ..\system_controller.v tb.sv
if errorlevel 1 (
	popd
	exit /b 1
)
vsim -c -t 1ps -l log.txt -do run.do tb
set result=%errorlevel%
popd
exit /b %result%
