@echo off
REM RAW to WAV Multitrack Extractor for Windows
REM Based on original script by J. Bruce Fields, 2024
REM Windows version with 24-in-32 padding detection, 2026
REM
REM This file is part of hALSAmrec.
REM
REM hALSAmrec is free software: you can redistribute it and/or modify
REM it under the terms of the GNU General Public License as published by
REM the Free Software Foundation, either version 3 of the License, or
REM (at your option) any later version.
REM
REM This program is distributed in the hope that it will be useful,
REM but WITHOUT ANY WARRANTY; without even the implied warranty of
REM MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
REM GNU General Public License for more details.
REM
REM You should have received a copy of the GNU General Public License
REM along with hALSAmrec. If not, see <http://www.gnu.org/licenses/>.
REM
REM Requires: SoX (Sound eXchange) - http://sox.sourceforge.net/
REM
REM Usage: Drag and drop a .raw file onto this script
REM Expected filename format: <timestamp>_<channels>-<rate>-<bitformat>.raw
REM Example: 20260122_143025_8-48000-S32_LE.raw

setlocal enabledelayedexpansion

if "%~1"=="" (
    echo Usage: %~nx0 filename.raw
    echo Expected filename format: ^<timestamp^>_^<channels^>-^<rate^>-^<bitformat^>.raw
    echo Example: 20260122_143025_8-48000-S32_LE.raw
    echo.
    pause
    exit /b 1
)

set "RAWFILE=%~1"
set "RAWEXT=%~x1"

if /i not "%RAWEXT%"==".raw" (
    echo Error: Input file must be a .raw file
    pause
    exit /b 1
)

if not exist "%RAWFILE%" (
    echo Error: File not found: %RAWFILE%
    pause
    exit /b 1
)

REM Check if SoX is available
where sox >nul 2>&1
if errorlevel 1 (
    echo Error: SoX not found. Please install SoX and add it to your PATH
    echo Download from: http://sox.sourceforge.net/
    pause
    exit /b 1
)

REM Parse filename
set "BASENAME=%~n1"

REM Split by underscore to get timestamp and params
for /f "tokens=1,2 delims=_" %%a in ("%BASENAME%") do (
    set "TIMESTAMP=%%a"
    set "PARAMS=%%b"
)

if "%TIMESTAMP%"=="" (
    echo Error: Could not parse timestamp from filename
    echo Expected format: ^<timestamp^>_^<channels^>-^<rate^>-^<bitformat^>.raw
    pause
    exit /b 1
)

REM Split params by dash to get channels, rate, and bitformat
for /f "tokens=1,2,3 delims=-" %%a in ("%PARAMS%") do (
    set "CHANNELS=%%a"
    set "RATE=%%b"
    set "BITFORMAT=%%c"
)

if "%CHANNELS%"=="" (
    echo Error: Could not parse channels from filename
    pause
    exit /b 1
)

if "%RATE%"=="" (
    echo Error: Could not parse rate from filename
    pause
    exit /b 1
)

if "%BITFORMAT%"=="" (
    echo Error: Could not parse bitformat from filename
    pause
    exit /b 1
)

REM Parse bitformat
set "BITS="
set "ENCODING="
set "ENDIAN="

REM Handle different bitformats
if "%BITFORMAT%"=="S8" (
    set "BITS=8"
    set "ENCODING=signed-integer"
) else if "%BITFORMAT%"=="U8" (
    set "BITS=8"
    set "ENCODING=unsigned-integer"
) else if "%BITFORMAT%"=="S16_LE" (
    set "BITS=16"
    set "ENCODING=signed-integer"
    set "ENDIAN=little"
) else if "%BITFORMAT%"=="S16_BE" (
    set "BITS=16"
    set "ENCODING=signed-integer"
    set "ENDIAN=big"
) else if "%BITFORMAT%"=="U16_LE" (
    set "BITS=16"
    set "ENCODING=unsigned-integer"
    set "ENDIAN=little"
) else if "%BITFORMAT%"=="U16_BE" (
    set "BITS=16"
    set "ENCODING=unsigned-integer"
    set "ENDIAN=big"
) else if "%BITFORMAT%"=="S24_LE" (
    set "BITS=24"
    set "ENCODING=signed-integer"
    set "ENDIAN=little"
) else if "%BITFORMAT%"=="S24_BE" (
    set "BITS=24"
    set "ENCODING=signed-integer"
    set "ENDIAN=big"
) else if "%BITFORMAT%"=="U24_LE" (
    set "BITS=24"
    set "ENCODING=unsigned-integer"
    set "ENDIAN=little"
) else if "%BITFORMAT%"=="U24_BE" (
    set "BITS=24"
    set "ENCODING=unsigned-integer"
    set "ENDIAN=big"
) else if "%BITFORMAT%"=="S32_LE" (
    set "BITS=32"
    set "ENCODING=signed-integer"
    set "ENDIAN=little"
) else if "%BITFORMAT%"=="S32_BE" (
    set "BITS=32"
    set "ENCODING=signed-integer"
    set "ENDIAN=big"
) else if "%BITFORMAT%"=="U32_LE" (
    set "BITS=32"
    set "ENCODING=unsigned-integer"
    set "ENDIAN=little"
) else if "%BITFORMAT%"=="U32_BE" (
    set "BITS=32"
    set "ENCODING=unsigned-integer"
    set "ENDIAN=big"
) else if "%BITFORMAT%"=="S24_3LE" (
    set "BITS=24"
    set "ENCODING=signed-integer"
    set "ENDIAN=little"
) else if "%BITFORMAT%"=="S24_3BE" (
    set "BITS=24"
    set "ENCODING=signed-integer"
    set "ENDIAN=big"
) else if "%BITFORMAT%"=="U24_3LE" (
    set "BITS=24"
    set "ENCODING=unsigned-integer"
    set "ENDIAN=little"
) else if "%BITFORMAT%"=="U24_3BE" (
    set "BITS=24"
    set "ENCODING=unsigned-integer"
    set "ENDIAN=big"
) else if "%BITFORMAT%"=="S20_3LE" (
    set "BITS=20"
    set "ENCODING=signed-integer"
    set "ENDIAN=little"
) else if "%BITFORMAT%"=="S20_3BE" (
    set "BITS=20"
    set "ENCODING=signed-integer"
    set "ENDIAN=big"
) else if "%BITFORMAT%"=="U20_3LE" (
    set "BITS=20"
    set "ENCODING=unsigned-integer"
    set "ENDIAN=little"
) else if "%BITFORMAT%"=="U20_3BE" (
    set "BITS=20"
    set "ENCODING=unsigned-integer"
    set "ENDIAN=big"
) else if "%BITFORMAT%"=="S18_3LE" (
    set "BITS=18"
    set "ENCODING=signed-integer"
    set "ENDIAN=little"
) else if "%BITFORMAT%"=="S18_3BE" (
    set "BITS=18"
    set "ENCODING=signed-integer"
    set "ENDIAN=big"
) else if "%BITFORMAT%"=="U18_3LE" (
    set "BITS=18"
    set "ENCODING=unsigned-integer"
    set "ENDIAN=little"
) else if "%BITFORMAT%"=="U18_3BE" (
    set "BITS=18"
    set "ENCODING=unsigned-integer"
    set "ENDIAN=big"
) else if "%BITFORMAT%"=="FLOAT_LE" (
    set "BITS=32"
    set "ENCODING=floating-point"
    set "ENDIAN=little"
) else if "%BITFORMAT%"=="FLOAT_BE" (
    set "BITS=32"
    set "ENCODING=floating-point"
    set "ENDIAN=big"
) else if "%BITFORMAT%"=="FLOAT64_LE" (
    set "BITS=64"
    set "ENCODING=floating-point"
    set "ENDIAN=little"
) else if "%BITFORMAT%"=="FLOAT64_BE" (
    set "BITS=64"
    set "ENCODING=floating-point"
    set "ENDIAN=big"
) else if "%BITFORMAT%"=="DSD_U8" (
    set "BITS=8"
    set "ENCODING=dsd"
) else if "%BITFORMAT%"=="DSD_U16_LE" (
    set "BITS=16"
    set "ENCODING=dsd"
    set "ENDIAN=little"
) else if "%BITFORMAT%"=="DSD_U16_BE" (
    set "BITS=16"
    set "ENCODING=dsd"
    set "ENDIAN=big"
) else if "%BITFORMAT%"=="DSD_U32_LE" (
    set "BITS=32"
    set "ENCODING=dsd"
    set "ENDIAN=little"
) else if "%BITFORMAT%"=="DSD_U32_BE" (
    set "BITS=32"
    set "ENCODING=dsd"
    set "ENDIAN=big"
) else if "%BITFORMAT%"=="DSD_U8_BE" (
    set "BITS=8"
    set "ENCODING=dsd"
    set "ENDIAN=big"
) else (
    echo Error: Unsupported/unknown BITFORMAT '%BITFORMAT%'
    pause
    exit /b 1
)

REM Detect 24-in-32 padding for S32 formats
set "PADMODE=none"
set "OUT_BITS="
set "EXTRA_EFFECTS="

if "%ENCODING%"=="signed-integer" (
    if "%BITFORMAT%"=="S32_LE" set "DO_DETECT=1"
    if "%BITFORMAT%"=="S32_BE" set "DO_DETECT=1"
)

if defined DO_DETECT (
    echo Analyzing file for 24-in-32 padding...
    echo.
    
    REM Determine endian flag for PowerShell
    set "PS_ENDIAN=little"
    if "%BITFORMAT%"=="S32_BE" set "PS_ENDIAN=big"
    
    REM Detect padding using PowerShell
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
"$file='%RAWFILE%'; $ch=%CHANNELS%; $endian='%PS_ENDIAN%'; $bytes=Get-Content $file -Encoding Byte -TotalCount 80000 -EA SilentlyContinue; if(!$bytes){exit 1}; $frames=[Math]::Min($bytes.Length/($ch*4),20000); $lsb=0; $msb00ff=0; $signext=0; for($i=0;$i -lt $frames*$ch*4;$i+=4){if($endian -eq 'little'){$b0=$bytes[$i]; $b1=$bytes[$i+1]; $b2=$bytes[$i+2]; $b3=$bytes[$i+3]; $lsbyte=$b0; $msbyte=$b3; $signbit=($b2 -band 0x80)}else{$b0=$bytes[$i]; $b1=$bytes[$i+1]; $b2=$bytes[$i+2]; $b3=$bytes[$i+3]; $msbyte=$b0; $lsbyte=$b3; $signbit=($b1 -band 0x80)}; if($lsbyte -eq 0){$lsb++}; if($msbyte -eq 0 -or $msbyte -eq 255){$msb00ff++; $expected=if($signbit -ne 0){255}else{0}; if($msbyte -eq $expected){$signext++}};}; $total=$frames*$ch; $lsbr=($lsb*1000)/$total; $msbr=($msb00ff*1000)/$total; $sigr=($signext*1000)/$total; if($lsbr -gt 999){'lsb_pad'}elseif($msbr -gt 999 -and $sigr -gt 995){'msb_signext'}else{'none'}" > "%TEMP%\padmode_%RANDOM%.txt"
    
    set /p PADMODE=<"%TEMP%\padmode_%RANDOM%.txt"
    del "%TEMP%\padmode_*.txt" 2>nul
    
    if "!PADMODE!"=="lsb_pad" (
        set "OUT_BITS=24"
        echo Detected: 24-in-32 with LSB padding
        echo Will export as true 24-bit WAV
        echo.
    ) else if "!PADMODE!"=="msb_signext" (
        set "OUT_BITS=24"
        set "EXTRA_EFFECTS=vol 256"
        echo Detected: 24-in-32 with MSB sign extension
        echo Will apply scaling and export as true 24-bit WAV
        echo.
    ) else (
        echo No 24-in-32 padding detected - processing as true 32-bit
        echo.
    )
)

REM Create output directory
set "OUTDIR=%~dp1%TIMESTAMP%"
if not exist "%OUTDIR%" mkdir "%OUTDIR%"

echo Extracting %CHANNELS% tracks from %~nx1
echo Format: %BITS% bits, %RATE% Hz, %ENCODING%, %ENDIAN% endian
echo Output directory: %TIMESTAMP%
echo.

REM Extract each channel
set /a CHANNEL=%CHANNELS%
:extract_loop
if %CHANNEL% LEQ 0 goto extract_done

set "FILENAME=track%CHANNEL%.wav"
echo - writing %TIMESTAMP%\!FILENAME!

REM Build SoX command
set "SOX_CMD=sox"
set "SOX_CMD=!SOX_CMD! -t raw -b %BITS% -c %CHANNELS% -e %ENCODING% -r %RATE%"
if defined ENDIAN set "SOX_CMD=!SOX_CMD! --endian %ENDIAN%"
set "SOX_CMD=!SOX_CMD! "%RAWFILE%""

REM Output options
if defined OUT_BITS (
    set "SOX_CMD=!SOX_CMD! -b %OUT_BITS% -e signed-integer"
)
set "SOX_CMD=!SOX_CMD! "%OUTDIR%\!FILENAME!""

REM Add effects
if defined EXTRA_EFFECTS (
    set "SOX_CMD=!SOX_CMD! %EXTRA_EFFECTS%"
)
set "SOX_CMD=!SOX_CMD! remix %CHANNEL%"

REM Execute SoX
!SOX_CMD!

if errorlevel 1 (
    echo Error extracting track %CHANNEL%
    pause
    exit /b 1
)

set /a CHANNEL=%CHANNEL%-1
goto extract_loop

:extract_done
echo.
echo %CHANNELS% tracks successfully extracted!
echo.
pause
