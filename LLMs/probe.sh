#!/bin/sh

# Percorso completo di arecord (modifica se necessario)
ARECORD="/usr/bin/arecord"

# Determina il numero massimo di canali, bit depth e frequenza supportata
device="hw:0,0"

# Esegui arecord e salva l'output grezzo
$ARECORD -D $device --dump-hw-params > /tmp/arecord_output.txt 2>&1
arecord_output=$(cat /tmp/arecord_output.txt)

# Controlla se l'output è vuoto
if [ -z "$arecord_output" ]; then
    echo "Errore: il comando arecord non ha prodotto alcun output."
    exit 1
fi

# Estrai i canali massimi
max_channels=$(echo "$arecord_output" | grep "CHANNELS:" | sed -n 's/.*CHANNELS: \[\?\([0-9]*\)\( \([0-9]*\)\)\?\]/\3/p')
if [ -z "$max_channels" ]; then
    # Se non è un range, prendi il valore singolo
    max_channels=$(echo "$arecord_output" | grep "CHANNELS:" | sed -n 's/.*CHANNELS: \([0-9]*\)/\1/p')
fi

# Estrai il formato più profondo
bitformat=$(echo "$arecord_output" | grep "^FORMAT:" | sed -n 's/.*FORMAT: \(.*\)/\1/p' | awk '{print $NF}')
if [ -z "$bitformat" ]; then
    # Se il formato è unico, catturalo direttamente
    bitformat=$(echo "$arecord_output" | grep "^FORMAT:" | sed -n 's/.*FORMAT: \([A-Z0-9_]*\)/\1/p')
fi

# Funzione per estrarre il valore massimo da una riga con range
extract_max_from_range() {
    echo "$1" | sed -n 's/.*[[(]\([0-9]*\) \([0-9]*\)[])]/\2/p'
}

# Estrai i valori massimi per BUFFER_TIME, BUFFER_SIZE e BUFFER_BYTES
buffer_time_max=$(echo "$arecord_output" | grep "BUFFER_TIME:" | while read -r line; do extract_max_from_range "$line"; done)
buffer_size_max=$(echo "$arecord_output" | grep "BUFFER_SIZE:" | while read -r line; do extract_max_from_range "$line"; done)

# Estrae la frequenza massima
max_rate=$(echo "$arecord_output" | grep "RATE:" | while read -r line; do extract_max_from_range "$line"; done)
if [ -z "$max_rate" ]; then
    # Se non è un range, prendi il valore singolo
    max_rate=$(echo "$arecord_output" | grep "RATE:" | sed -n 's/.*RATE: \([0-9]*\)/\1/p')
fi

if [ "$max_rate" -gt 48000 ]; then
    max_rate=48000
fi

#if [ -z "$max_channels" ] || [ -z "$bitformat" ] || [ -z "$supported_rates" ]; then
#    echo "Errore: impossibile determinare i parametri audio."
#    exit 1
#fi

echo "Canali: $max_channels"
echo "Formato: $bitformat"
echo "MAX Frequenza: $max_rate"
echo "MAX Buffer time: $buffer_time_max"
echo "MAX Buffer size: $buffer_size_max"
