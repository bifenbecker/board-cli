@echo off
rem Runs board from cmd.exe and PowerShell, which have no sh of their own. Git for Windows provides it.
setlocal
set "BOARD_SH="
where sh >nul 2>nul && set "BOARD_SH=sh"
if not defined BOARD_SH if exist "%ProgramFiles%\Git\bin\sh.exe" set "BOARD_SH=%ProgramFiles%\Git\bin\sh.exe"
if not defined BOARD_SH (
    echo board: sh was not found: install Git for Windows 1>&2
    exit /b 1
)
"%BOARD_SH%" "%~dp0board" %*
