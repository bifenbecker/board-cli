@echo off
rem Runs board from cmd.exe and PowerShell, which have no sh of their own. Git for Windows provides it.
rem cmd.exe parses %* before sh sees it, so text with quotes belongs in --body-file, not an argument.
setlocal
set "BOARD_SH="
if exist "%ProgramFiles%\Git\bin\sh.exe" set "BOARD_SH=%ProgramFiles%\Git\bin\sh.exe"
rem $PATH: leaves out the working directory, which may be a repository with an sh.exe of its own.
if not defined BOARD_SH for /f "delims=" %%i in ('where "$PATH:sh.exe" 2^>nul') do if not defined BOARD_SH set "BOARD_SH=%%i"
if not defined BOARD_SH (
    echo board: sh was not found: install Git for Windows 1>&2
    exit /b 1
)
"%BOARD_SH%" "%~dp0board" %*
