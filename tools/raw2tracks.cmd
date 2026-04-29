@echo off
setlocal enabledelayedexpansion

:: RAW input file
set "RAWFILE=%~1"
if "%RAWFILE%"=="" (
    echo Usage: %~nx0 filename
    echo Expected filename format: ^<timestamp^>_^<channels^>-^<rate^>-^<bitformat^>.raw
    exit /b 1
)

:: Extract filename without extension
for %%F in ("%RAWFILE%") do set "BASENAME=%%~nF"

:: Parse filename: <timestamp>_<channels>-<rate>-<bitformat>
set "TIMESTAMP="
set "CHANNELS="
set "RATE="
set "BITFORMAT="

for /f "tokens=1* delims=_" %%a in ("%BASENAME%") do (
    set "TIMESTAMP=%%a"
    set "PARAMS=%%b"
)

if "%TIMESTAMP%"=="" (
    echo Error: Could not parse timestamp from filename
    exit /b 1
)

for /f "tokens=1-3 delims=-" %%a in ("%PARAMS%") do (
    set "CHANNELS=%%a"
    set "RATE=%%b"
    set "BITFORMAT=%%c"
)

if "%CHANNELS%"=="" (
    echo Error: Could not parse channels from filename
    exit /b 1
)
if "%RATE%"=="" (
    echo Error: Could not parse rate from filename
    exit /b 1
)
if "%BITFORMAT%"=="" (
    echo Error: Could not parse bitformat from filename
    exit /b 1
)

:: Map BITFORMAT to Sox parameters
set "BITS="
set "ENCODING="
set "ENDIAN="

:: Signed/Unsigned Integer
for %%F in (S8 U8 S16_LE S16_BE U16_LE U16_BE S24_LE S24_BE U24_LE U24_BE S32_LE S32_BE U32_LE U32_BE S24_3LE S24_3BE U24_3LE U24_3BE S20_3LE S20_3BE U20_3LE U20_3BE S18_3LE S18_3BE U18_3LE U18_3BE) do (
    if /i "!BITFORMAT!"=="%%F" (
        set "BITS=!BITFORMAT:~1,2!"
        if "!BITFORMAT:~0,1!"=="U" (
            set "ENCODING=unsigned-integer"
        ) else (
            set "ENCODING=signed-integer"
        )
        if "!BITFORMAT:~-2!"=="LE" set "ENDIAN=little"
        if "!BITFORMAT:~-2!"=="BE" set "ENDIAN=big"
    )
)

:: Float
if /i "!BITFORMAT!"=="FLOAT_LE" (
    set "BITS=32"
    set "ENCODING=float"
    set "ENDIAN=little"
)
if /i "!BITFORMAT!"=="FLOAT_BE" (
    set "BITS=32"
    set "ENCODING=float"
    set "ENDIAN=big"
)
if /i "!BITFORMAT!"=="FLOAT64_LE" (
    set "BITS=64"
    set "ENCODING=float"
    set "ENDIAN=little"
)
if /i "!BITFORMAT!"=="FLOAT64_BE" (
    set "BITS=64"
    set "ENCODING=float"
    set "ENDIAN=big"
)

:: DSD
for %%F in (DSD_U8 DSD_U16_LE DSD_U16_BE DSD_U32_LE DSD_U32_BE DSD_U8_BE) do (
    if /i "!BITFORMAT!"=="%%F" (
        set "ENCODING=dsd"
        if "%%F"=="DSD_U8" set "BITS=8"
        if "%%F"=="DSD_U16_LE" set "BITS=16" & set "ENDIAN=little"
        if "%%F"=="DSD_U16_BE" set "BITS=16" & set "ENDIAN=big"
        if "%%F"=="DSD_U32_LE" set "BITS=32" & set "ENDIAN=little"
        if "%%F"=="DSD_U32_BE" set "BITS=32" & set "ENDIAN=big"
        if "%%F"=="DSD_U8_BE" set "BITS=8" & set "ENDIAN=big"
    )
)

:: Interactive destination directory prompt
set "DEFAULT_OUTDIR=%TIMESTAMP%"
echo.
echo Destination directory selection.
echo You may enter a full or relative path, or press Enter to use the default: "%DEFAULT_OUTDIR%"
set /p "OUTDIR=Destination folder: "
if "%OUTDIR%"=="" set "OUTDIR=%DEFAULT_OUTDIR%"

:: Remove any surrounding quotes the user may have entered
set "OUTDIR=%OUTDIR:"=%"

:: Create directory if it doesn't exist
if not exist "%OUTDIR%" (
    mkdir "%OUTDIR%" 2>nul
    if errorlevel 1 (
        echo Error: Failed to create destination directory "%OUTDIR%".
        exit /b 1
    )
)

:: Final existence check
if not exist "%OUTDIR%" (
    echo Error: Destination directory "%OUTDIR%" does not exist and could not be created.
    exit /b 1
)

echo Extracting %CHANNELS% tracks to "%OUTDIR%" from %RAWFILE% (%BITS% bits, %RATE% Hz, %ENCODING%, %ENDIAN% endian):
:: Extract each channel
set /a CHANNEL=%CHANNELS%
:loop
if %CHANNEL% LSS 1 goto end

set "FILENAME=track!CHANNEL!.wav"
echo - writing "%OUTDIR%\!FILENAME!"
sox --type raw --bits %BITS% --channels %CHANNELS% --encoding %ENCODING% --rate %RATE% --endian %ENDIAN% "%RAWFILE%" "%OUTDIR%\!FILENAME!" remix %CHANNEL%

set /a CHANNEL-=1
goto loop

:end
echo %CHANNELS% tracks successfully extracted to "%OUTDIR%"!
pause
