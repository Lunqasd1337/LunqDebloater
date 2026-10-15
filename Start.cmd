@echo off
rem Double-click to run LunqDebloater in step-by-step mode.
rem The script asks for administrator rights by itself.
rem Full path: a powershell.exe earlier in PATH (or PowerShell 7) must not be picked up.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0LunqDebloater.ps1"
rem Keep the window open on failure so the error can be read.
if errorlevel 1 pause
