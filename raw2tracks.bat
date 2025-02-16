@echo off

:: RAW input file
set "RAWFILE=%1"

:: Tracks number
set TRACKS=18
set /a CHANNEL=%TRACKS%

:loop
if %CHANNEL% LSS 1 goto end

set "FILENAME=track%CHANNEL%.wav"
sox --type raw --bits 32 --channels %TRACKS% --encoding signed-integer --rate 48000 --endian little "%RAWFILE%" "%FILENAME%" remix %CHANNEL%

set /a CHANNEL-=1
goto loop

:end
