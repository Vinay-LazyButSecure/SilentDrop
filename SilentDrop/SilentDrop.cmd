@echo off
:: Double-click this to start SilentDrop.
:: SilentDrop by Vinay Kumar Kamtam - https://github.com/Vinay-LazyButSecure/SilentDrop
:: You can also drag an .msi straight onto this file and it opens with it loaded.

start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0SilentDrop.ps1" -MsiPath "%~1"
