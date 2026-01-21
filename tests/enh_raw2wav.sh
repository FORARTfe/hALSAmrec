#!/bin/bash
#
# Original script by J. Bruce Fields, 2024
# This version by FORART (https://forart.it/), 2025
# Patched: auto-detect 24-in-32 padding and export true 24-bit WAVs, 2026
#
# This file is part of hALSAmrec.
#
# hALSAmrec is free software: you can redistribute it and/or modify
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
# along with hALSAmrec.  If not, see <http://www.gnu.org/licenses/>.

RAWFILE="$1"
if [ -z "$RAWFILE" ]; then
    echo "Usage: $(basename "$0") filename"
    echo "Expected filename format: <timestamp>_<channels>-<rate>-<bitformat>.raw"
    exit 1
fi

BASENAME=$(basename "$RAWFILE" .raw)

IFS='_' read -r TIMESTAMP PARAMS <<< "$BASENAME"
if [ -z "$TIMESTAMP" ]; then
    echo "Error: Could not parse timestamp from filename"
    exit 1
fi

IFS='-' read -r CHANNELS RATE BITFORMAT <<< "$PARAMS"
if [ -z "$CHANNELS" ]; then
    echo "Error: Could not parse channels from filename"
    exit 1
fi
if [ -z "$RATE" ]; then
    echo "Error: Could not parse rate from filename"
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
        BITS=${BITFORMAT:1:2}
        if [ "${BITFORMAT:0:1}" = "U" ]; then
            ENCODING="unsigned-integer"
        else
            ENCODING="signed-integer"
        fi
        if [ "${BITFORMAT: -2}" = "LE" ]; then
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
        echo "Error: Unsupported/unknown BITFORMAT '$BITFORMAT'"
        exit 1
        ;;
esac

detect_24in32_padding_mode() {
    # Ritorna una stringa: none | lsb_pad | msb_signext
    # Solo per signed-integer 32-bit
    local file="$1"
    local channels="$2"
    local endian="$3"

    if ! command -v python3 >/dev/null 2>&1; then
        echo "none"
        return 0
    fi

    python3 - "$file" "$channels" "$endian" <<'PY'
import sys, os

path = sys.argv[1]
channels = int(sys.argv[2])
endian = sys.argv[3].lower()

frame_bytes = channels * 4

# Numero di frame da campionare (interleaved): evita letture enormi
max_frames = 20000

try:
    st = os.stat(path)
    if st.st_size < frame_bytes:
        print("none")
        sys.exit(0)
except Exception:
    print("none")
    sys.exit(0)

to_read = min(st.st_size, frame_bytes * max_frames)
with open(path, "rb") as f:
    data = f.read(to_read)

frames = len(data) // frame_bytes
if frames <= 0:
    print("none")
    sys.exit(0)

total_samples = (len(data) // 4)  # ogni campione è 4 byte
lsb_zero = 0
msb_is_00_ff = 0
msb_matches_signext24 = 0

# Scorriamo tutti i campioni 32-bit (inclusi tutti i canali)
for i in range(0, (len(data) // 4) * 4, 4):
    b0, b1, b2, b3 = data[i], data[i+1], data[i+2], data[i+3]

    if endian.startswith("l"):
        lsb = b0
        msb = b3
        sign24 = (b2 & 0x80) != 0
    else:
        # big endian: primo byte = MSB, ultimo = LSB
        msb = b0
        lsb = b3
        sign24 = (b1 & 0x80) != 0

    if lsb == 0x00:
        lsb_zero += 1

    if msb in (0x00, 0xFF):
        msb_is_00_ff += 1
        expected = 0xFF if sign24 else 0x00
        if msb == expected:
            msb_matches_signext24 += 1

lsb_rate = lsb_zero / total_samples
msb_00ff_rate = msb_is_00_ff / total_samples
signext_rate = (msb_matches_signext24 / total_samples) if total_samples else 0.0

# Decisione conservativa (soglie alte per evitare falsi positivi):
# 1) padding su LSB (tipico left-justified): LSB quasi sempre 0
if lsb_rate > 0.999:
    print("lsb_pad")
    sys.exit(0)

# 2) sign-extension a 24 bit su MSB (tipico right-justified con byte alto = estensione segno):
# MSB quasi sempre 00/FF e coerente col bit di segno a 24 bit
if msb_00ff_rate > 0.999 and signext_rate > 0.995:
    print("msb_signext")
    sys.exit(0)

print("none")
PY
}

OUTDIR="$TIMESTAMP"
mkdir -p "$OUTDIR"

# Default: nessuna correzione, nessuna forzatura bitdepth output
OUT_BITS=""
EXTRA_EFFECTS=()

PADMODE="none"
if [ "$ENCODING" = "signed-integer" ] && { [ "$BITFORMAT" = "S32_LE" ] || [ "$BITFORMAT" = "S32_BE" ]; }; then
    PADMODE="$(detect_24in32_padding_mode "$RAWFILE" "$CHANNELS" "$ENDIAN")"
    case "$PADMODE" in
        lsb_pad)
            # 24-in-32 con padding su LSB: basta esportare a 24 bit
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
    echo "Detected 24-in-32 container mode: $PADMODE -> exporting WAV at 24-bit"
    if [ "${#EXTRA_EFFECTS[@]}" -gt 0 ]; then
        echo "Applying extra effects: ${EXTRA_EFFECTS[*]}"
    fi
fi
echo

# Extract each channel
for ((CHANNEL=CHANNELS; CHANNEL>=1; CHANNEL--)); do
    FILENAME="track${CHANNEL}.wav"
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
