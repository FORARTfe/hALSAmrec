@echo off

:: File RAW di input
set "RAWFILE=%1"

:: Numero di tracce
set TRACKS=18
set /a CHANNEL=%TRACKS%

:loop
if %CHANNEL% LSS 1 goto end

set "FILENAME=track%CHANNEL%.wav"
sox --type raw --bits 32 --channels %TRACKS% --encoding signed-integer --rate 48000 --endian little "%RAWFILE%" "%FILENAME%" remix %CHANNEL%

set /a CHANNEL-=1
goto loop

:end