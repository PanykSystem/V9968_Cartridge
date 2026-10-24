@echo off
rem V9968UPD for Windows build script (Visual Studio 2022 MSBuild)
setlocal
cd /d "%~dp0"

set VSWHERE="%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq tokens=*" %%i in (`%VSWHERE% -latest -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe`) do set MSBUILD="%%i"
if not defined MSBUILD (
	echo MSBuild not found. Install Visual Studio 2022.
	exit /b 1
)

%MSBUILD% V9968UpdWin.sln -restore -p:Configuration=Release -v:minimal -nologo
if errorlevel 1 exit /b 1

copy /Y V9968UpdWin\bin\Release\net472\V9968UpdWin.exe . > nul
echo.
echo Output: %~dp0V9968UpdWin.exe
endlocal
