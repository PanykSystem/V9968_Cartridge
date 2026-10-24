@echo off
setlocal
pushd "%~dp0"
if not exist work vlib work
vlog ..\hdmi_converter.v tb.sv
if errorlevel 1 goto failed
for %%D in (0 1) do (
	for %%P in (0 5000 11000 17000 23000 31000) do (
		vsim -c -t 1ps -l log_s0_d%%D_p%%P.txt -do run.do tb +SCENARIO=0 +PHASE=%%P +DIVPHASE=%%D
		if errorlevel 1 goto failed
	)
)
for %%S in (1 2 3 4 5 6 7 8) do (
	for %%D in (0 1) do (
		vsim -c -t 1ps -l log_s%%S_d%%D.txt -do run.do tb +SCENARIO=%%S +PHASE=13000 +DIVPHASE=%%D
		if errorlevel 1 goto failed
	)
)
popd
exit /b 0
:failed
popd
exit /b 1
