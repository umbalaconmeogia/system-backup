@ECHO OFF
REM Restore database from a backup, on Windows.
REM Usage: restore.bat [-Config FILE] [-AsIs] [-Yes] <backup directory | zip file | zip.gpg file | sql file>
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore.ps1" %*
EXIT /B %ERRORLEVEL%
