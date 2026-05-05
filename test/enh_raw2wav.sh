#!/bin/bash
#
# Original script by J. Bruce Fields, 2024
# This version by FORART (https://forart.it/), 2025
# Patched:  auto-detect 24-in-32 padding and export true 24-bit WAVs, 2026
#
# This file is part of hALSAmrec.
#
# hALSAmrec is free software:  you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# hALSAmrec is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with hALSAmrec.   If not, see <http://www.gnu.org/licenses/>. 

RAWFILE="$1"
if [ -z "$RAWFILE" ]; then
    echo "Usage:  $(basename "$0") filename"
    echo "Expected filename format: <timestamp>_<channels>-<rate>-<bitformat>. raw"
    exit 1
fi

BASENAME=$(basename "$RAWFILE" .raw)

IFS='_' read -r TIMESTAMP PARAMS <<< "$BASENAME"
if [ -z "$TIMESTAMP" ]; then
    echo "Error:  Could not parse timestamp from filename"
    exit 1
fi

IFS='-' read -r CHANNELS RATE BITFORMAT <<< "$PARAMS"
if [ -z "$CHANNELS" ]; then
    echo "Error:  Could not parse channels from filename"
    exit 1
fi
if [ -z "$RATE" ]; then
    echo "Error:  Could not parse rate from filename"
    exit 1
fi
if [ -z "$BITFORMAT" ]; then
    echo "Error: Could not parse bitformat from filename"
    exit 1
fi

BITS=""
ENCODING=""
ENDIAN=""

case "$BITFORMAT" in
    S8)
        BITS=8
        ENCODING="signed-integer"
        ;;
    U8)
        BITS=8
        ENCODING="unsigned-integer"
        ;;
    S16_LE|S16_BE|U16_LE|U16_BE|S24_LE|S24_BE|U24_LE|U24_BE|S32_LE|S32_BE|U32_LE|U32_BE|S24_3LE|S24_3BE|U24_3LE|U24_3BE|S20_3LE|S20_3BE|U20_3LE|U20_3BE|S18_3LE|S18_3BE|U18_3LE|U18_3BE)
        BITS=${BITFORMAT: 1: 2}
        if [ "${BITFORMAT:0:1}" = "U" ]; then
            ENCODING="unsigned-integer"
        else
            ENCODING="signed-integer"
        fi
        if [ "${BITFORMAT:  -2}" = "LE" ]; then
            ENDIAN="little"
        elif [ "${BITFORMAT: -2}" = "BE" ]; then
            ENDIAN="big"
        fi
        ;;
    FLOAT_LE)
        BITS=32
        ENCODING="float"
        ENDIAN="little"
        ;;
    FLOAT_BE)
        BITS=32
        ENCODING="float"
        ENDIAN="big"
        ;;
    FLOAT64_LE)
        BITS=64
        ENCODING="float"
        ENDIAN="little"
        ;;
    FLOAT64_BE)
        BITS=64
        ENCODING="float"
        ENDIAN="big"
        ;;
    DSD_U8)
        ENCODING="dsd"
        BITS=8
        ;;
    DSD_U16_LE)
        ENCODING="dsd"
        BITS=16
        ENDIAN="little"
        ;;
    DSD_U16_BE)
        ENCODING="dsd"
        BITS=16
        ENDIAN="big"
        ;;
    DSD_U32_LE)
        ENCODING="dsd"
        BITS=32
        ENDIAN="little"
        ;;
    DSD_U32_BE)
        ENCODING="dsd"
        BITS=32
        ENDIAN="big"
        ;;
    DSD_U8_BE)
        ENCODING="dsd"
        BITS=8
        ENDIAN="big"
        ;;
    *)
        echo "Error:  Unsupported/unknown BITFORMAT '$BITFORMAT'"
        exit 1
        ;;
esac

detect_24in32_padding_mode() {
    # Ritorna una stringa:  none | lsb_pad | msb_signext
    # Solo per signed-integer 32-bit
    local file="$1"
    local channels="$2"
    local endian="$3"

    # Check if file exists and is readable
    if [ ! -r "$file" ]; then
        echo "none"
        return 0
    fi

    # Get file size
    local file_size
    file_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)
    if [ "$file_size" -eq 0 ]; then
        echo "none"
        return 0
    fi

    local frame_bytes=$((channels * 4))
    local max_frames=20000
    local to_read=$((frame_bytes * max_frames))

    # Don't read more than file size
    if [ "$to_read" -gt "$file_size" ]; then
        to_read=$file_size
    fi

    # Use od to read bytes and convert to hex
    local hex_data
    hex_data=$(od -An -tx1 -N "$to_read" "$file" | tr -d ' \n')

    local total_bytes=${#hex_data}
    if [ "$total_bytes" -lt 8 ]; then
        echo "none"
        return 0
    fi

    # Convert hex string to bytes (2 hex chars = 1 byte)
    local total_samples=$((total_bytes / 8))

    local lsb_zero=0
    local msb_is_00_ff=0
    local msb_matches_signext24=0

    # Process each 32-bit sample (8 hex chars)
    local i=0
    while [ "$i" -lt "$total_bytes" ]; do
        # Extract 8 hex characters (4 bytes)
        local byte_hex="${hex_data:$i:8}"

        if [ ${#byte_hex} -lt 8 ]; then
            break
        fi

        # Parse bytes
        local b0="0x${byte_hex:0:2}"
        local b1="0x${byte_hex:2:2}"
        local b2="0x${byte_hex: 4:2}"
        local b3="0x${byte_hex:6:2}"

        # Convert to decimal
        b0=$((b0))
        b1=$((b1))
        b2=$((b2))
        b3=$((b3))

        # Determine endianness and extract LSB, MSB, sign bit
        local lsb msb sign24

        if [[ "$endian" == l* ]]; then
            # Little endian:  first byte = LSB, last byte = MSB
            lsb=$b0
            msb=$b3
            sign24=$(( (b2 & 0x80) != 0 ?  1 : 0 ))
        else
            # Big endian: first byte = MSB, last byte = LSB
            msb=$b0
            lsb=$b3
            sign24=$(( (b1 & 0x80) != 0 ? 1 :  0 ))
        fi

        # Count LSB zeros
        if [ "$lsb" -eq 0 ]; then
            ((lsb_zero++))
        fi

        # Count MSB as 0x00 or 0xFF
        if [ "$msb" -eq 0 ] || [ "$msb" -eq 255 ]; then
            ((msb_is_00_ff++))
            # Check if MSB matches sign extension pattern
            local expected=255
            if [ "$sign24" -eq 0 ]; then
                expected=0
            fi
            if [ "$msb" -eq "$expected" ]; then
                ((msb_matches_signext24++))
            fi
        fi

        i=$((i + 8))
    done

    # Calculate rates (using integer math to avoid floating point)
    # Rate = (count * 1000) / total_samples (in per-mille)
    local lsb_rate_permille=$(( (lsb_zero * 1000) / total_samples ))
    local msb_00ff_rate_permille=$(( (msb_is_00_ff * 1000) / total_samples ))
    local signext_rate_permille=$(( (msb_matches_signext24 * 1000) / total_samples ))

    # Decision:  thresholds 999/1000 = 0.999, 995/1000 = 0.995
    if [ "$lsb_rate_permille" -gt 999 ]; then
        echo "lsb_pad"
        return 0
    fi

    if [ "$msb_00ff_rate_permille" -gt 999 ] && [ "$signext_rate_permille" -gt 995 ]; then
        echo "msb_signext"
        return 0
    fi

    echo "none"
}

OUTDIR="$TIMESTAMP"
mkdir -p "$OUTDIR"

# Default:  nessuna correzione, nessuna forzatura bitdepth output
OUT_BITS=""
EXTRA_EFFECTS=()

PADMODE="none"
if [ "$ENCODING" = "signed-integer" ] && { [ "$BITFORMAT" = "S32_LE" ] || [ "$BITFORMAT" = "S32_BE" ]; }; then
    PADMODE="$(detect_24in32_padding_mode "$RAWFILE" "$CHANNELS" "$ENDIAN")"
    case "$PADMODE" in
        lsb_pad)
            # 24-in-32 con padding su LSB:  basta esportare a 24 bit
            OUT_BITS="24"
            ;;
        msb_signext)
            # 24-in-32 right-justified (sign-extension): serve riportare la scala corretta
            # fattore 256 = 2^8
            OUT_BITS="24"
            EXTRA_EFFECTS=(vol 256)
            ;;
        none)
            ;;
        *)
            PADMODE="none"
            ;;
    esac
fi

echo "Extracting $CHANNELS tracks from $RAWFILE ($BITS bits, $RATE Hz, $ENCODING, $ENDIAN endian)"
if [ "$PADMODE" != "none" ]; then
    echo "Detected 24-in-32 container mode:  $PADMODE -> exporting WAV at 24-bit"
    if [ "${#EXTRA_EFFECTS[@]}" -gt 0 ]; then
        echo "Applying extra effects: ${EXTRA_EFFECTS[*]}"
    fi
fi
echo

# Extract each channel
for ((CHANNEL=CHANNELS; CHANNEL>=1; CHANNEL--)); do
    FILENAME="track${CHANNEL}. wav"
    echo "- writing $OUTDIR/$FILENAME"

    # Output file options (solo se serve)
    OUT_OPTS=()
    if [ -n "$OUT_BITS" ]; then
        OUT_OPTS+=(--bits "$OUT_BITS")
        # per WAV, forziamo PCM signed-integer quando esportiamo a 24 bit
        OUT_OPTS+=(--encoding signed-integer)
    fi

    sox \
        --type raw --bits "$BITS" --channels "$CHANNELS" --encoding "$ENCODING" --rate "$RATE" --endian "$ENDIAN" \
        "$RAWFILE" \
        "${OUT_OPTS[@]}" "$OUTDIR/$FILENAME" \
        "${EXTRA_EFFECTS[@]}" remix "$CHANNEL"
done

echo
echo "$CHANNELS tracks successfully extracted!"
read -p "Press enter to continue..."
