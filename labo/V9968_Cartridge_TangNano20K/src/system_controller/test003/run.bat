@echo off
setlocal
pushd "%~dp0"
if not exist work vlib work
vlog ..\..\spi_rom\sfrom_test_model.v ..\..\spi_rom\ip_spi_rom.v ..\system_controller.v tb.sv
if errorlevel 1 (
	popd
	exit /b 1
)
vsim -c -t 1ps -l log.txt -do run.do tb
set result=%errorlevel%
popd
exit /b %result%
