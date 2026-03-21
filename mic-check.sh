#!/bin/bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  PRE-CALL MIC CHECK
#  mit USB / Bluetooth Auto-Erkennung
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
VERSION="1.4.4"
export LANG=C.UTF-8

# --- CONFIG ---
CHECK_SECS=3
RATE=44100
CHANNELS=1
BITS=16
BAR_W=25
MAX_RESTARTS=2
LOG_FILE="${HOME}/.mic-check.log"
# --------------

show_help() {
    cat <<EOF
mic-check v${VERSION} – Schneller Mikrofon-Test vor Anrufen

Verwendung:  ./mic-check.sh [OPTIONEN]

Optionen:
  --help      Diese Hilfe anzeigen
  --version   Versionsnummer anzeigen
  --keep      Aktuelle Geräte beibehalten,
              kein Umschalten vorschlagen
  --debug     Debug-Infos zur Geräte-Erkennung
  --list      Alle Audio-Geräte auflisten
  --history   Letzte Test-Ergebnisse anzeigen

Was das Script macht:
  1. Erkennt Audio-Server (PipeWire / PulseAudio)
  2. Prüft Mikrofon- und Ausgabe-Gerät
  3. Zeigt Bluetooth-Codec/Profil (mSBC, CVSD, SBC, AAC)
  4. Wechselt BT automatisch auf Handsfree mSBC
  5. Erkennt USB / Bluetooth Headsets
  6. Schlägt Umschalten vor (USB > BT > Intern)
  7. Misst Rauschboden (Noise Floor)
  8. ${CHECK_SECS}-Sekunden Live-Pegeltest mit VU-Meter
  9. Frequenzgang-Prüfung (4kHz-Cutoff-Erkennung)
 10. Berechnet Signal-Rausch-Abstand (SNR)
 11. Kurze Wiedergabe zur Kontrolle
 12. Speichert Ergebnisse in ${LOG_FILE}

Abhängigkeiten:  sox (sudo pacman -S sox)

Alias-Tipp:  echo 'alias miccheck="~/mic-check.sh"' >> ~/.bashrc
EOF
    exit 0
}

show_list() {
    echo "mic-check v${VERSION} – Geräte-Übersicht"
    echo ""
    wpctl status 2>/dev/null | awk '
        /Audio/,/Video/ { print }
    ' | head -40
    exit 0
}

show_history() {
    echo "mic-check v${VERSION} – Test-Verlauf"
    echo ""
    if [[ ! -f "$LOG_FILE" ]]; then
        echo "  Noch keine Tests gespeichert."
        echo "  Log-Datei: ${LOG_FILE}"
    else
        echo "  Letzte 20 Ergebnisse (${LOG_FILE}):"
        echo ""
        tail -20 "$LOG_FILE" | while IFS='|' read -r ts verdict device codec snr_val noise_val peak_val freq_ok; do
            local icon="?"
            case "$verdict" in
                OK)   icon="✓" ;;
                WARN) icon="⚠" ;;
                FAIL) icon="✗" ;;
            esac
            printf "  %s  %s  %-6s  %-25s  Codec:%-5s  SNR:%s  Noise:%s  Peak:%s  Freq:%s\n" \
                "$ts" "$icon" "$verdict" "$device" "$codec" "$snr_val" "$noise_val" "$peak_val" "$freq_ok"
        done
    fi
    echo ""
    exit 0
}

# --- OPTIONEN ---
KEEP_DEVICES=0
DEBUG=0
for arg in "$@"; do
    case "$arg" in
        --help|-h)    show_help ;;
        --version|-v) echo "mic-check v${VERSION}"; exit 0 ;;
        --keep)       KEEP_DEVICES=1 ;;
        --debug)      DEBUG=1 ;;
        --list)       show_list ;;
        --history)    show_history ;;
    esac
done

BYTES_PER_SEC=$(( RATE * CHANNELS * (BITS / 8) ))
CHUNK_BYTES=$(( BYTES_PER_SEC / 5 ))
CHUNK_COUNT=$(( CHECK_SECS * 5 ))
FILE=$(mktemp /tmp/miccheck.XXXXXX.raw)

RESTART_COUNT="${_MICCHECK_RESTARTS:-0}"

# --- Farben ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'
BG_RED='\033[41m'
BG_GREEN='\033[42m'

# ━━━ AUDIO-SERVER ERKENNUNG ━━━
detect_audio_server() {
    AUDIO_SERVER="unknown"
    AUDIO_SERVER_VERSION=""

    if command -v pipewire &>/dev/null && pgrep -x pipewire &>/dev/null; then
        AUDIO_SERVER="pipewire"
        AUDIO_SERVER_VERSION=$(pipewire --version 2>/dev/null | grep -oP 'pipewire\s+\K[0-9.]+' | head -1)
        if pgrep -f pipewire-pulse &>/dev/null; then
            AUDIO_SERVER="${AUDIO_SERVER}+pulse"
        fi
    elif command -v pulseaudio &>/dev/null && pgrep -x pulseaudio &>/dev/null; then
        AUDIO_SERVER="pulseaudio"
        AUDIO_SERVER_VERSION=$(pulseaudio --version 2>/dev/null | grep -oP '[0-9.]+' | head -1)
    fi

    # WirePlumber als Session-Manager?
    if pgrep -x wireplumber &>/dev/null; then
        SESSION_MANAGER="wireplumber"
    else
        SESSION_MANAGER=""
    fi
}

# ━━━ BLUETOOTH CODEC/PROFIL ERKENNUNG ━━━
detect_bt_codec() {
    BT_CODEC=""
    BT_PROFILE=""
    BT_PROFILE_LABEL=""
    BT_CODEC_WARNING=""
    BT_ALL_PROFILES=()

    # Kein BT-Gerät → nichts zu tun
    [[ -z "$BT_SRC_ID" && -z "$BT_SINK_ID" ]] && return

    # Finde den Bluetooth-Device-Namen für pactl
    local bt_device_id="${BT_SRC_ID:-$BT_SINK_ID}"

    # Aktives Profil über wpctl inspect ermitteln
    local inspect_src="" inspect_sink=""
    if [[ -n "$BT_SRC_ID" ]]; then
        inspect_src=$(wpctl inspect "$BT_SRC_ID" 2>/dev/null)
    fi
    if [[ -n "$BT_SINK_ID" ]]; then
        inspect_sink=$(wpctl inspect "$BT_SINK_ID" 2>/dev/null)
    fi

    # Codec aus der media.name / node.name / api.bluez5.codec Eigenschaft
    local codec_line
    codec_line=$(echo "$inspect_src" "$inspect_sink" | grep -i 'api.bluez5.codec' | head -1)
    if [[ -n "$codec_line" ]]; then
        BT_CODEC=$(echo "$codec_line" | sed 's/.*= *"\?\([^"]*\)"\?/\1/' | xargs)
    fi

    # Profil-Erkennung: pactl list cards für Bluetooth-Karte
    local bt_card_info
    bt_card_info=$(pactl list cards 2>/dev/null | awk '
        /Name:.*bluez/{found=1}
        found{print}
        found && /^$/{found=0}
    ')

    if [[ -n "$bt_card_info" ]]; then
        # Aktives Profil
        BT_PROFILE=$(echo "$bt_card_info" | grep -A1 "Active Profile:" | head -1 | sed 's/.*Active Profile: *//')

        # Alle verfügbaren Profile sammeln
        local in_profiles=0
        while IFS= read -r line; do
            if echo "$line" | grep -q "Profiles:"; then
                in_profiles=1
                continue
            fi
            if (( in_profiles )); then
                # Ende der Profile-Sektion
                if echo "$line" | grep -qE "^[[:space:]]*(Active Profile|Ports):"; then
                    break
                fi
                local pname
                pname=$(echo "$line" | sed 's/^\s*//' | cut -d: -f1 | xargs)
                [[ -n "$pname" && "$pname" != "off" ]] && BT_ALL_PROFILES+=("$pname")
            fi
        done <<< "$bt_card_info"
    fi

    # Profil-Label für Anzeige
    case "$BT_PROFILE" in
        *handsfree*head*unit*HFP*|*handsfree_head_unit*)
            BT_PROFILE_LABEL="Handsfree (HFP)" ;;
        *headset*head*unit*|*headset_head_unit*)
            BT_PROFILE_LABEL="Headset (HSP/HFP)" ;;
        *a2dp*sink*|*a2dp-sink*)
            BT_PROFILE_LABEL="Headphones (A2DP)" ;;
        *)
            BT_PROFILE_LABEL="$BT_PROFILE" ;;
    esac

    # Codec-Label normalisieren
    case "$BT_CODEC" in
        msbc|mSBC|MSBC)   BT_CODEC="mSBC" ;;
        cvsd|CVSD)         BT_CODEC="CVSD" ;;
        sbc_xq|sbc-xq)    BT_CODEC="SBC-XQ" ;;
        sbc|SBC)           BT_CODEC="SBC" ;;
        aac|AAC)           BT_CODEC="AAC" ;;
    esac

    # Warnung wenn nicht optimaler Codec für Mikrofon
    if [[ -n "$BT_CODEC" ]]; then
        case "$BT_CODEC" in
            mSBC)
                BT_CODEC_WARNING="" ;;  # Bester Codec für Mikro
            CVSD)
                BT_CODEC_WARNING="CVSD hat niedrige Qualität (8kHz). mSBC wäre besser." ;;
            SBC|SBC-XQ|AAC)
                BT_CODEC_WARNING="A2DP-Codec – kein Mikrofon verfügbar! Wechsle zu Handsfree (mSBC)." ;;
        esac
    fi
}

# ━━━ AUTO-SWITCH BT → HANDSFREE mSBC (System-weit) ━━━
# 3-Sekunden-Countdown mit [Leertaste] zum Abbrechen
countdown_switch() {
    local message="$1"
    local seconds="${2:-3}"

    tput cnorm
    for (( i=seconds; i>0; i-- )); do
        printf "\r    ${YELLOW}⏳ ${message} in ${BOLD}${i}s${NC}${YELLOW} – [Leertaste] zum Überspringen${NC}  "
        # read mit 1s Timeout, einzelnes Zeichen
        if read -r -s -n 1 -t 1 key 2>/dev/null; then
            if [[ "$key" == "" || "$key" == " " ]]; then
                printf "\r    ${DIM}↷ Übersprungen.${NC}%40s\n"
                tput civis
                return 1
            fi
        fi
    done
    printf "\r%80s\r"
    tput civis
    return 0
}

switch_bt_to_msbc() {
    # Nur wenn BT-Gerät vorhanden und nicht bereits auf mSBC
    [[ -z "$BT_SRC_ID" && -z "$BT_SINK_ID" ]] && return 1
    [[ "$BT_CODEC" == "mSBC" ]] && return 1

    # Finde BT-Karten-Name über pactl
    local bt_card_name
    bt_card_name=$(pactl list cards short 2>/dev/null | grep -i 'bluez' | awk '{print $2}' | head -1)
    [[ -z "$bt_card_name" ]] && return 1

    # Profil-Auswahl: Bestes Handsfree-Profil finden
    # Priorität: 1) headset-head-unit (ohne suffix = mSBC)
    #            2) *msbc* Variante
    #            3) irgendein headset/handsfree Profil (nicht -cvsd)
    #            4) headset-head-unit-cvsd als letzter Fallback
    local best_profile=""

    # 1) Exakt "headset-head-unit" (ohne Suffix = mSBC auf den meisten Systemen)
    for p in "${BT_ALL_PROFILES[@]}"; do
        [[ "$p" == "headset-head-unit" ]] && { best_profile="$p"; break; }
    done

    # 2) Explizites mSBC-Profil
    if [[ -z "$best_profile" ]]; then
        for p in "${BT_ALL_PROFILES[@]}"; do
            if echo "$p" | grep -qi 'msbc'; then
                best_profile="$p"
                break
            fi
        done
    fi

    # 3) Handsfree/Headset (nicht CVSD)
    if [[ -z "$best_profile" ]]; then
        for p in "${BT_ALL_PROFILES[@]}"; do
            if echo "$p" | grep -qi 'handsfree\|headset.*head.*unit\|hfp' && \
               ! echo "$p" | grep -qi 'cvsd'; then
                best_profile="$p"
                break
            fi
        done
    fi

    # 4) Letzter Fallback: CVSD (besser als A2DP ohne Mic)
    if [[ -z "$best_profile" ]]; then
        for p in "${BT_ALL_PROFILES[@]}"; do
            if echo "$p" | grep -qi 'handsfree\|headset.*head.*unit\|hfp\|cvsd'; then
                best_profile="$p"
                break
            fi
        done
    fi

    [[ -z "$best_profile" ]] && return 1
    [[ "$best_profile" == "$BT_PROFILE" ]] && return 1

    # Nachricht abhängig vom aktuellen Codec
    local switch_msg=""
    case "$BT_CODEC" in
        CVSD)
            echo -e "    ${YELLOW}⚠ CVSD hat niedrige Qualität (8kHz). mSBC wäre besser.${NC}"
            switch_msg="Wechsle zu ${best_profile}"
            ;;
        SBC|SBC-XQ|AAC)
            echo -e "    ${YELLOW}⚠ A2DP-Codec – kein Mikrofon verfügbar! Wechsle zu Handsfree (mSBC).${NC}"
            switch_msg="Wechsle zu ${best_profile}"
            ;;
        *)
            echo -e "    ${YELLOW}⚠ Profil nicht optimal für Mikrofon.${NC}"
            switch_msg="Wechsle zu ${best_profile}"
            ;;
    esac
    echo ""

    if countdown_switch "$switch_msg" 3; then
        echo -e "    ${DIM}Setze BT-Profil system-weit → ${best_profile}...${NC}"
        pactl set-card-profile "$bt_card_name" "$best_profile" 2>/dev/null

        if (( $? == 0 )); then
            echo -e "    ${GREEN}✓${NC} Profil umgeschaltet auf ${BOLD}${best_profile}${NC} (system-weit)"
            sleep 1
            echo ""
            echo -e "    ${BOLD}↻ Starte Mic-Check neu...${NC}"
            do_restart
        else
            echo -e "    ${RED}✗${NC} Profilwechsel fehlgeschlagen"
            echo ""
        fi
    fi
    echo ""
    return 0
}

# ━━━ FREQUENZGANG-PRÜFUNG ━━━
check_frequency_response() {
    FREQ_OK=""
    FREQ_HAS_HIGH=""
    FREQ_WARNING=""
    FREQ_BANDWIDTH=""

    # Braucht die Aufnahme-Datei
    [[ ! -s "$FILE" ]] && return

    # sox stat -freq liefert Frequenz-Amplitude-Paare
    local freq_data
    freq_data=$(sox -t raw -r $RATE -c $CHANNELS -b $BITS -e signed-integer "$FILE" \
        -n stat -freq 2>&1 | awk '$1 ~ /^[0-9]/ && $2 ~ /^[0-9]/ {print $1, $2}')

    [[ -z "$freq_data" ]] && return

    # Energie in Bändern messen
    # Band 1: 300-1000 Hz (Grundfrequenz Stimme)
    # Band 2: 1000-4000 Hz (Klarheit/Verständlichkeit)
    # Band 3: 4000-8000 Hz (Brillanz/Zischlaute)
    local energy_low energy_mid energy_high
    energy_low=$(echo "$freq_data" | awk '$1+0 >= 300 && $1+0 < 1000 {s += $2*$2} END{print s+0}')
    energy_mid=$(echo "$freq_data" | awk '$1+0 >= 1000 && $1+0 < 4000 {s += $2*$2} END{print s+0}')
    energy_high=$(echo "$freq_data" | awk '$1+0 >= 4000 && $1+0 < 8000 {s += $2*$2} END{print s+0}')

    # Prüfe ob 4kHz+ vorhanden (CVSD schneidet bei 4kHz ab)
    if (( $(awk "BEGIN{print ($energy_high > 0 && $energy_mid > 0) ? 1 : 0}") )); then
        local ratio_high_mid
        ratio_high_mid=$(awk "BEGIN{printf \"%.2f\", $energy_high / ($energy_mid + 0.001)}")

        if (( $(awk "BEGIN{print ($ratio_high_mid > 0.01) ? 1 : 0}") )); then
            FREQ_HAS_HIGH="yes"
            FREQ_BANDWIDTH="Breitband (>4kHz)"
        else
            FREQ_HAS_HIGH="no"
            FREQ_BANDWIDTH="Schmalband (≤4kHz)"
        fi
    else
        FREQ_HAS_HIGH="no"
        FREQ_BANDWIDTH="Schmalband (≤4kHz)"
    fi

    # Bewertung
    if [[ "$FREQ_HAS_HIGH" == "yes" ]]; then
        FREQ_OK="OK"
    else
        FREQ_OK="WARN"
        if [[ "$BT_CODEC" == "CVSD" ]]; then
            FREQ_WARNING="CVSD-Codec begrenzt auf 4kHz – Wechsel zu mSBC empfohlen."
        else
            FREQ_WARNING="Kein Signal über 4kHz erkannt – Sprachqualität eingeschränkt."
        fi
    fi
}

# ━━━ SNR-BERECHNUNG ━━━
calculate_snr() {
    SNR_DB=""
    SNR_RATING=""

    # Braucht Noise Floor und Signal Peak
    (( NOISE_PEAK <= 0 )) && NOISE_PEAK=1
    (( max_peak <= 0 )) && return

    SNR_DB=$(awk "BEGIN{printf \"%.1f\", 20*log($max_peak/$NOISE_PEAK)/log(10)}")
    local snr_int=${SNR_DB%%.*}

    if (( snr_int >= 40 )); then
        SNR_RATING="exzellent"
    elif (( snr_int >= 25 )); then
        SNR_RATING="gut"
    elif (( snr_int >= 15 )); then
        SNR_RATING="akzeptabel"
    else
        SNR_RATING="schlecht – Hintergrundgeräusche zu laut"
    fi
}

# ━━━ ERGEBNIS LOGGEN ━━━
log_result() {
    local timestamp device codec snr_val noise_val peak_val freq_val verdict_val
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    device=$(extract_name "$DEFAULT_SRC_LINE")
    codec="${BT_CODEC:-n/a}"
    snr_val="${SNR_DB:-n/a}"
    noise_val="${NOISE_DB:-n/a}"
    peak_val="${max_peak:-0}"
    freq_val="${FREQ_OK:-n/a}"
    verdict_val="${VERDICT:-FAIL}"

    echo "${timestamp}|${verdict_val}|${device}|${codec}|${snr_val}|${noise_val}|${peak_val}|${freq_val}" >> "$LOG_FILE"
}

# ━━━ RAUSCHBODEN-MESSUNG ━━━
measure_noise_floor() {
    local noise_file
    noise_file=$(mktemp /tmp/micnoise.XXXXXX.raw)

    # 1 Sekunde Stille aufnehmen
    rec -q -c $CHANNELS -r $RATE -b $BITS -e signed-integer -t raw "$noise_file" \
        trim 0 1 2>/dev/null

    if [[ -s "$noise_file" ]]; then
        NOISE_PEAK=$(od -An -td2 -v "$noise_file" | tr -s ' \n' '\n' | \
            awk 'BEGIN{m=0} $1!=""{v=$1+0; if(v<0)v=-v; if(v>m)m=v} END{print m+0}')
        if (( NOISE_PEAK > 0 )); then
            NOISE_DB=$(awk "BEGIN{printf \"%.1f\", 20*log($NOISE_PEAK/32768)/log(10)}")
        else
            NOISE_DB="-inf"
        fi
    else
        NOISE_PEAK=0
        NOISE_DB="-inf"
    fi

    rm -f "$noise_file"
}

cleanup() {
    tput cnorm 2>/dev/null
    rm -f "$FILE" 2>/dev/null
    [[ -n "$PLAY_PIPE" ]] && rm -f "$PLAY_PIPE" 2>/dev/null
    [[ -n "$MIC_PIPE" ]]  && rm -f "$MIC_PIPE"  2>/dev/null
    [[ -n "$WAIT_PIPE" ]] && rm -f "$WAIT_PIPE" 2>/dev/null
}
trap cleanup EXIT

# ━━━ VU-BALKEN ━━━
draw_vu() {
    local peak="$1"
    local level=$(( peak * BAR_W / 32768 ))
    (( level > BAR_W )) && level=$BAR_W

    local db
    if (( peak > 0 )); then
        db=$(awk "BEGIN{printf \"%.1f\", 20*log($peak/32768)/log(10)}")
    else
        db="-inf"
    fi

    local color="$GREEN"
    (( level > BAR_W * 70 / 100 )) && color="$RED"
    (( level > BAR_W * 45 / 100 && level <= BAR_W * 70 / 100 )) && color="$YELLOW"

    local bar="" empty=""
    (( level > 0 )) && bar=$(printf '█%.0s' $(seq 1 "$level"))
    local rest=$(( BAR_W - level ))
    (( rest > 0 )) && empty=$(printf '░%.0s' $(seq 1 "$rest"))

    printf "[${color}%s${NC}%s] %s dB" "$bar" "$empty" "$db"
}

# Nur der Balken ohne dB-Wert
draw_bar() {
    local peak="$1"
    local level=$(( peak * BAR_W / 32768 ))
    (( level > BAR_W )) && level=$BAR_W

    local color="$GREEN"
    (( level > BAR_W * 70 / 100 )) && color="$RED"
    (( level > BAR_W * 45 / 100 && level <= BAR_W * 70 / 100 )) && color="$YELLOW"

    local bar="" empty=""
    (( level > 0 )) && bar=$(printf '█%.0s' $(seq 1 "$level"))
    local rest=$(( BAR_W - level ))
    (( rest > 0 )) && empty=$(printf '░%.0s' $(seq 1 "$rest"))

    printf "[${color}%s${NC}%s]" "$bar" "$empty"
}

# ━━━ ROBUSTE PARSER ━━━

# Holt die erste Zahl die direkt vor einem Punkt steht
# "│  *  147. USB Composite Device Mono [vol: 1.00]" → "147"
extract_id() {
    echo "$1" | grep -oE '[0-9]+\.' | head -1 | tr -d '.'
}

# Gibt die ganze Zeile ab "ID. Name" zurück (Tree-Zeichen + Sterne weg)
# "│  *  147. USB Composite Device Mono [vol: 1.00]" → "147. USB Composite Device Mono [vol: 1.00]"
extract_display() {
    echo "$1" | sed 's/^[^0-9]*//'
}

# Nur der Name (ohne ID und ohne [...])
# "│  *  147. USB Composite Device Mono [vol: 1.00]" → "USB Composite Device Mono"
extract_name() {
    local display
    display=$(extract_display "$1")
    # Entferne "123. " am Anfang, dann alles ab "["
    echo "$display" | sed 's/^[0-9]*\.\s*//' | sed 's/\[.*//' | xargs
}

# Bestimmt Verbindungstyp anhand des Zeileninhalts
line_type() {
    local line="$1"
    if echo "$line" | grep -qi "usb"; then
        echo "usb"
    elif echo "$line" | grep -qi "bluez\|haylou\|jabra\|sony\|bose\|airpod\|galaxy\|jbl\|beats\|oneplus"; then
        echo "bluetooth"
    elif echo "$line" | grep -qi "arrow\|cavs\|realtek\|hdmi\|built-in\|alc\|intel"; then
        echo "internal"
    else
        echo "unknown"
    fi
}

# ━━━ GERÄTE-ERKENNUNG ━━━
detect_devices() {
    local wpctl_raw
    wpctl_raw=$(wpctl status 2>/dev/null)

    # --- Sektionen via Zeilennummern ---
    local sinks_ln sources_ln filters_ln streams_ln total_ln

    sinks_ln=$(echo "$wpctl_raw" | grep -n "Sinks:" | head -1 | cut -d: -f1)
    sources_ln=$(echo "$wpctl_raw" | grep -n "Sources:" | head -1 | cut -d: -f1)
    filters_ln=$(echo "$wpctl_raw" | grep -n "Filters:" | head -1 | cut -d: -f1)
    streams_ln=$(echo "$wpctl_raw" | grep -n "Streams:" | head -1 | cut -d: -f1)
    total_ln=$(echo "$wpctl_raw" | wc -l)

    local sinks_block="" sources_block="" filters_block=""

    if [[ -n "$sinks_ln" && -n "$sources_ln" ]] && (( sources_ln > sinks_ln + 1 )); then
        sinks_block=$(echo "$wpctl_raw" | sed -n "$((sinks_ln + 1)),$((sources_ln - 1))p")
    fi

    if [[ -n "$sources_ln" && -n "$filters_ln" ]] && (( filters_ln > sources_ln + 1 )); then
        sources_block=$(echo "$wpctl_raw" | sed -n "$((sources_ln + 1)),$((filters_ln - 1))p")
    fi

    local filters_end=$(( ${streams_ln:-$total_ln} - 1 ))
    if [[ -n "$filters_ln" ]] && (( filters_end > filters_ln )); then
        filters_block=$(echo "$wpctl_raw" | sed -n "$((filters_ln + 1)),${filters_end}p")
    fi

    # Nur Zeilen mit Node-IDs (haben "Zahl." Muster gefolgt von Buchstaben)
    sinks_block=$(echo "$sinks_block" | grep -E '[0-9]+\.\s+[A-Za-z]')
    sources_block=$(echo "$sources_block" | grep -E '[0-9]+\.\s+[A-Za-z]')
    filters_block=$(echo "$filters_block" | grep -E '[0-9]+\.')

    # --- Debug ---
    if (( DEBUG )); then
        echo -e "  ${DIM}[DEBUG] Sinks (ab Zeile $sinks_ln):${NC}"
        echo "$sinks_block" | sed 's/^/    /'
        echo -e "  ${DIM}[DEBUG] Sources (ab Zeile $sources_ln):${NC}"
        echo "$sources_block" | sed 's/^/    /'
        echo -e "  ${DIM}[DEBUG] Filters (ab Zeile $filters_ln):${NC}"
        echo "$filters_block" | sed 's/^/    /'
        echo ""
    fi

    # --- Default Source ---
    DEFAULT_SRC_LINE=$(echo "$sources_block" | grep '[*]' | head -1)
    if [[ -z "$DEFAULT_SRC_LINE" ]]; then
        DEFAULT_SRC_LINE=$(echo "$filters_block" | grep '[*]' | head -1)
    fi
    CURRENT_SRC_ID=$(extract_id "$DEFAULT_SRC_LINE")
    CURRENT_SRC_TYPE=$(line_type "$DEFAULT_SRC_LINE")

    # --- Default Sink ---
    DEFAULT_SINK_LINE=$(echo "$sinks_block" | grep '[*]' | head -1)
    CURRENT_SINK_ID=$(extract_id "$DEFAULT_SINK_LINE")
    CURRENT_SINK_TYPE=$(line_type "$DEFAULT_SINK_LINE")

    # --- USB Source ---
    USB_SRC_ID=""
    USB_SRC_NAME=""
    USB_SRC_LINE=""
    local usb_src_line
    usb_src_line=$(echo "$sources_block" | grep -i "usb" | head -1)
    if [[ -n "$usb_src_line" ]]; then
        USB_SRC_ID=$(extract_id "$usb_src_line")
        USB_SRC_NAME=$(extract_name "$usb_src_line")
        USB_SRC_LINE="$usb_src_line"
    fi

    # --- Bluetooth Source ---
    BT_SRC_ID=""
    BT_SRC_NAME=""
    BT_SRC_LINE=""
    local bt_src_line=""

    # 1) Unter Sources: bekannte Headset-Namen
    bt_src_line=$(echo "$sources_block" | grep -i "haylou\|jabra\|sony\|bose\|airpod\|galaxy\|jbl\|beats\|oneplus" | head -1)

    # 2) Unter Sources: alles was nicht intern/USB
    if [[ -z "$bt_src_line" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local lt
            lt=$(line_type "$line")
            [[ "$lt" == "internal" || "$lt" == "usb" ]] && continue
            bt_src_line="$line"
            break
        done <<< "$sources_block"
    fi

    # 3) Unter Filters: bluez_input (NICHT bluez_capture_internal!)
    if [[ -z "$bt_src_line" ]]; then
        bt_src_line=$(echo "$filters_block" | grep -i 'bluez_input\.' | grep -vi 'capture_internal' | head -1)
    fi

    if [[ -n "$bt_src_line" ]]; then
        BT_SRC_ID=$(extract_id "$bt_src_line")
        BT_SRC_NAME=$(extract_name "$bt_src_line")
        BT_SRC_LINE="$bt_src_line"
    fi

    # --- USB Sink ---
    # Bevorzuge Analog Stereo über Digital Stereo (IEC958/S/PDIF)
    USB_SINK_ID=""
    USB_SINK_NAME=""
    USB_SINK_LINE=""

    local usb_sink_analog usb_sink_any
    usb_sink_analog=$(echo "$sinks_block" | grep -i "usb" | grep -vi "iec958\|digital\|spdif\|s/pdif" | head -1)
    usb_sink_any=$(echo "$sinks_block" | grep -i "usb" | head -1)

    local usb_sink_line="${usb_sink_analog:-$usb_sink_any}"
    if [[ -n "$usb_sink_line" ]]; then
        USB_SINK_ID=$(extract_id "$usb_sink_line")
        USB_SINK_NAME=$(extract_name "$usb_sink_line")
        USB_SINK_LINE="$usb_sink_line"
    fi

    # --- Bluetooth Sink ---
    BT_SINK_ID=""
    BT_SINK_NAME=""
    BT_SINK_LINE=""
    local bt_sink_line
    bt_sink_line=$(echo "$sinks_block" | grep -i "haylou\|jabra\|sony\|bose\|airpod\|galaxy\|jbl\|beats\|oneplus" | head -1)
    if [[ -z "$bt_sink_line" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local lt
            lt=$(line_type "$line")
            [[ "$lt" == "internal" || "$lt" == "usb" ]] && continue
            bt_sink_line="$line"
            break
        done <<< "$sinks_block"
    fi
    if [[ -n "$bt_sink_line" ]]; then
        BT_SINK_ID=$(extract_id "$bt_sink_line")
        BT_SINK_NAME=$(extract_name "$bt_sink_line")
        BT_SINK_LINE="$bt_sink_line"
    fi

    # --- Debug ---
    if (( DEBUG )); then
        echo -e "  ${DIM}[DEBUG] Default Src:  ID=${CURRENT_SRC_ID} Type=${CURRENT_SRC_TYPE}${NC}"
        echo -e "  ${DIM}[DEBUG] Default Sink: ID=${CURRENT_SINK_ID} Type=${CURRENT_SINK_TYPE}${NC}"
        echo -e "  ${DIM}[DEBUG] USB Src:  ${USB_SRC_ID} = ${USB_SRC_NAME}${NC}"
        echo -e "  ${DIM}[DEBUG] BT Src:   ${BT_SRC_ID} = ${BT_SRC_NAME}${NC}"
        echo -e "  ${DIM}[DEBUG] USB Sink: ${USB_SINK_ID} = ${USB_SINK_NAME}${NC}"
        echo -e "  ${DIM}[DEBUG] BT Sink:  ${BT_SINK_ID} = ${BT_SINK_NAME}${NC}"
        echo ""
    fi
}

connection_label() {
    case "$1" in
        usb)       echo -e "${GREEN}USB${NC}" ;;
        bluetooth) echo -e "${CYAN}BT${NC}" ;;
        internal)  echo -e "${DIM}Intern${NC}" ;;
        *)         echo -e "${DIM}?${NC}" ;;
    esac
}

do_restart() {
    sleep 1
    cleanup
    export _MICCHECK_RESTARTS=$(( RESTART_COUNT + 1 ))
    exec "$0" "$@"
}

switch_to_device() {
    local src_id="$1" src_name="$2" sink_id="$3" sink_name="$4"

    echo -e "  ${DIM}Setze Mikrofon  → ${src_name} (${src_id})${NC}"
    wpctl set-default "$src_id" 2>/dev/null

    if [[ -n "$sink_id" ]]; then
        echo -e "  ${DIM}Setze Ausgabe   → ${sink_name} (${sink_id})${NC}"
        wpctl set-default "$sink_id" 2>/dev/null
    fi

    sleep 0.5
    echo -e "  ${GREEN}✓${NC} Umgeschaltet"
    echo ""
    echo -e "  ${BOLD}↻ Starte Mic-Check neu...${NC}"
    do_restart
}

# ━━━ ABHÄNGIGKEITEN ━━━
if ! command -v sox &>/dev/null; then
    echo -e "${RED}Fehler: 'sox' fehlt!${NC}  → sudo pacman -S sox"
    exit 1
fi

# ━━━ Endlosschleifen-Schutz ━━━
if (( RESTART_COUNT >= MAX_RESTARTS )); then
    clear
    echo -e "${RED}${BOLD}Abbruch: Umschalten nach ${MAX_RESTARTS} Versuchen fehlgeschlagen.${NC}"
    echo ""
    echo -e "  ${DIM}Debug: ./mic-check.sh --debug${NC}"
    echo ""
    tput cnorm
    exit 1
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  PHASE 1:  System-Check
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
clear
tput civis

KEEP_LABEL=""
(( KEEP_DEVICES )) && KEEP_LABEL=" ${DIM}(--keep)${NC}"

detect_devices
detect_audio_server
detect_bt_codec

# --- Audio-Server Label ---
AUDIO_SRV_SHORT=""
case "$AUDIO_SERVER" in
    pipewire+pulse|pipewire) AUDIO_SRV_SHORT="PipeWire" ;;
    pulseaudio)              AUDIO_SRV_SHORT="PulseAudio" ;;
    *)                       AUDIO_SRV_SHORT="?" ;;
esac
[[ -n "$AUDIO_SERVER_VERSION" ]] && AUDIO_SRV_SHORT="${AUDIO_SRV_SHORT} v${AUDIO_SERVER_VERSION}"
[[ -n "$SESSION_MANAGER" ]] && AUDIO_SRV_SHORT="${AUDIO_SRV_SHORT} + ${SESSION_MANAGER}"

# --- Mic/Out Info ---
MIC_VOL=$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null)
MIC_PCT=$(echo "$MIC_VOL" | awk '{printf "%.0f", $2*100}')
MIC_MUTED=$(echo "$MIC_VOL" | grep -o "MUTED")

OUT_VOL=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null)
OUT_PCT=$(echo "$OUT_VOL" | awk '{printf "%.0f", $2*100}')
OUT_MUTED=$(echo "$OUT_VOL" | grep -o "MUTED")

# --- Status-Kurzform ---
if [[ -n "$MIC_MUTED" ]]; then
    MIC_SHORT="${BG_RED}${BOLD}STUMM${NC}"
elif (( MIC_PCT < 20 )); then
    MIC_SHORT="${YELLOW}${MIC_PCT}%${NC}"
else
    MIC_SHORT="${GREEN}${MIC_PCT}%${NC}"
fi

if [[ -n "$OUT_MUTED" ]]; then
    OUT_SHORT="${BG_RED}${BOLD}STUMM${NC}"
elif (( OUT_PCT < 20 )); then
    OUT_SHORT="${YELLOW}${OUT_PCT}%${NC}"
else
    OUT_SHORT="${GREEN}${OUT_PCT}%${NC}"
fi

SRC_LABEL=$(connection_label "$CURRENT_SRC_TYPE")
SINK_LABEL=$(connection_label "$CURRENT_SINK_TYPE")
MIC_NAME=$(extract_name "$DEFAULT_SRC_LINE")
OUT_NAME=$(extract_name "$DEFAULT_SINK_LINE")

# --- BT Codec Kurzform ---
BT_CODEC_SHORT=""
if [[ -n "$BT_CODEC" ]]; then
    codec_color="$GREEN"
    [[ "$BT_CODEC" == "CVSD" ]] && codec_color="$RED"
    [[ "$BT_CODEC" == "SBC" || "$BT_CODEC" == "SBC-XQ" || "$BT_CODEC" == "AAC" ]] && codec_color="$YELLOW"
    BT_CODEC_SHORT="Codec: ${codec_color}${BT_CODEC}${NC}"
fi

# ━━━ HEADER (Wide Compact) ━━━
echo -e "  ${BOLD}🎧🎙 MIC CHECK${NC}${KEEP_LABEL} ${DIM}v${VERSION}${NC} ─── ${DIM}${AUDIO_SRV_SHORT}${NC} ─── ${BOLD}${MIC_NAME}${NC} ${DIM}[${NC}${SRC_LABEL}${DIM}]${NC}"
echo -e "  Mic: ${MIC_SHORT}  Out: ${OUT_SHORT}  ${BT_CODEC_SHORT}"

# --- BT-Profile (kompakt, gruppiert nach Typ) ---
if [[ -n "$BT_SRC_ID" || -n "$BT_SINK_ID" ]] && [[ ${#BT_ALL_PROFILES[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${DIM}BT-Profile:${NC}"
    output_line="" headset_line=""
    for p in "${BT_ALL_PROFILES[@]}"; do
        entry="$p"
        [[ "$p" == "$BT_PROFILE" ]] && entry="${p} ${CYAN}(aktiv)${NC}${DIM}"
        if echo "$p" | grep -qi 'headset\|handsfree\|hfp\|head.unit'; then
            [[ -n "$headset_line" ]] && headset_line+=" | "
            headset_line+="$entry"
        else
            [[ -n "$output_line" ]] && output_line+=" | "
            output_line+="$entry"
        fi
    done
    [[ -n "$output_line" ]] && echo -e "    🎧  ${DIM}${output_line}${NC}"
    [[ -n "$headset_line" ]] && echo -e "    🎧🎙 ${DIM}${headset_line}${NC}"
fi
echo ""

# ━━━ SMART ROUTING (nur ohne --keep) ━━━
if (( KEEP_DEVICES == 0 )); then
    tput cnorm

    # Auto-Switch: BT auf Handsfree mSBC wenn A2DP oder CVSD aktiv
    if [[ "$CURRENT_SRC_TYPE" == "bluetooth" || "$CURRENT_SINK_TYPE" == "bluetooth" ]]; then
        if [[ "$BT_CODEC" != "mSBC" && -n "$BT_CODEC" ]]; then
            switch_bt_to_msbc
        fi
    fi

    # Auto-Fix: Mic=USB aber Ausgabe≠USB
    if [[ "$CURRENT_SRC_TYPE" == "usb" && "$CURRENT_SINK_TYPE" != "usb" && -n "$USB_SINK_ID" ]]; then
        echo -e "  ${YELLOW}⚠${NC}  Mikrofon ist USB, aber Ausgabe ist $(connection_label "$CURRENT_SINK_TYPE")"
        echo -e "  ${DIM}Korrigiere Ausgabe auf USB...${NC}"
        echo -e "  ${DIM}→ $(extract_display "$USB_SINK_LINE")${NC}"
        wpctl set-default "$USB_SINK_ID" 2>/dev/null
        echo -e "  ${GREEN}✓${NC} Ausgabe umgeschaltet"
        echo ""
        echo -e "  ${BOLD}↻ Starte Mic-Check neu...${NC}"
        do_restart
    fi

    # Auto-Fix: Mic=BT aber Ausgabe≠BT
    if [[ "$CURRENT_SRC_TYPE" == "bluetooth" && "$CURRENT_SINK_TYPE" != "bluetooth" && -n "$BT_SINK_ID" ]]; then
        echo -e "  ${YELLOW}⚠${NC}  Mikrofon ist BT, aber Ausgabe ist $(connection_label "$CURRENT_SINK_TYPE")"
        echo -e "  ${DIM}Korrigiere Ausgabe auf BT...${NC}"
        echo -e "  ${DIM}→ $(extract_display "$BT_SINK_LINE")${NC}"
        wpctl set-default "$BT_SINK_ID" 2>/dev/null
        echo -e "  ${GREEN}✓${NC} Ausgabe umgeschaltet"
        echo ""
        echo -e "  ${BOLD}↻ Starte Mic-Check neu...${NC}"
        do_restart
    fi

    # Vorschlag: USB verfügbar und nicht aktiv
    if [[ "$CURRENT_SRC_TYPE" != "usb" && -n "$USB_SRC_ID" ]]; then
        echo -e "  ${GREEN}●${NC} USB-Headset erkannt: ${BOLD}${USB_SRC_NAME}${NC}"
        echo -e "    ${DIM}Aktuell: $(connection_label "$CURRENT_SRC_TYPE")${NC}"
        echo ""
        read -r -p "    Auf USB umschalten (Mic + Ausgabe)? [J/n] " answer
        answer=${answer:-j}
        if [[ "$answer" =~ ^[jJyY]$ ]]; then
            echo ""
            switch_to_device "$USB_SRC_ID" "$USB_SRC_NAME" "$USB_SINK_ID" "$USB_SINK_NAME"
        fi
        echo ""
    fi

    # Vorschlag: Mic=Intern, kein USB, BT verfügbar
    if [[ "$CURRENT_SRC_TYPE" == "internal" && -z "$USB_SRC_ID" && -n "$BT_SRC_ID" ]]; then
        echo -e "  ${CYAN}●${NC} Bluetooth-Headset erkannt: ${BOLD}${BT_SRC_NAME}${NC}"
        echo -e "    ${DIM}Aktuell wird das interne Mikrofon verwendet.${NC}"
        echo ""
        read -r -p "    Auf Bluetooth umschalten (Mic + Ausgabe)? [J/n] " answer
        answer=${answer:-j}
        if [[ "$answer" =~ ^[jJyY]$ ]]; then
            echo ""
            switch_to_device "$BT_SRC_ID" "$BT_SRC_NAME" "$BT_SINK_ID" "$BT_SINK_NAME"
        fi
        echo ""
    fi

    tput civis
fi

# Bei MUTE abbrechen
if [[ -n "$MIC_MUTED" ]]; then
    echo -e "  ${RED}${BOLD}✗ Mikrofon ist stumm!${NC}  ${DIM}→ wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 0${NC}"
    echo ""
    tput cnorm
    exit 1
fi

# ━━━ PHASE 1.5: Noise Floor (kompakt) ━━━
printf "  🔇 Rauschboden-Messung ${DIM}(Bitte 1s still sein...)${NC}: "
measure_noise_floor

if [[ "$NOISE_DB" == "-inf" ]]; then
    echo -e "${GREEN}Kein Rauschen${NC}"
elif (( NOISE_PEAK < 200 )); then
    echo -e "${GREEN}${NOISE_DB} dB${NC} ${DIM}(sehr gut)${NC}"
elif (( NOISE_PEAK < 800 )); then
    echo -e "${YELLOW}${NOISE_DB} dB${NC} ${DIM}(akzeptabel)${NC}"
else
    echo -e "${RED}${NOISE_DB} dB${NC} ${DIM}(zu hoch)${NC}"
fi
echo ""

# ━━━ PHASE 2: Live-Pegel (INPUT-Zeile als einzige Anzeige) ━━━
printf "  🎙 INPUT   $(draw_bar 0)  ${DIM}warte auf Pegel...${NC}"

# --- Phase 2a: Warte bis zu 3s auf Signal ---
WAIT_PIPE=$(mktemp -u /tmp/micwait.XXXXXX)
mkfifo "$WAIT_PIPE"

rec -q -c $CHANNELS -r $RATE -b $BITS -e signed-integer -t raw - \
    trim 0 3 2>/dev/null > "$WAIT_PIPE" &
WAIT_PID=$!

exec 5<"$WAIT_PIPE"

SIGNAL_DETECTED=0
WAIT_MAX=$(( 3 * 5 ))
wait_i=0

while (( wait_i < WAIT_MAX )); do
    chunk_data=$(dd bs=$CHUNK_BYTES count=1 <&5 2>/dev/null | od -An -td2 -v | tr -s ' \n' '\n')
    peak=$(echo "$chunk_data" | awk 'BEGIN{m=0} $1!=""{v=$1+0; if(v<0)v=-v; if(v>m)m=v} END{print m+0}')
    [[ -z "$peak" ]] && peak=0

    printf "\r  🎙 INPUT   $(draw_bar "$peak")  ${DIM}warte auf Pegel...${NC}\033[K"

    if (( peak > 500 )); then
        SIGNAL_DETECTED=1
        break
    fi
    (( wait_i++ ))
done

exec 5<&-
kill "$WAIT_PID" 2>/dev/null
wait "$WAIT_PID" 2>/dev/null
rm -f "$WAIT_PIPE"

# --- Phase 2b: Aufnahme mit Countdown ---
printf "\r  🎙 INPUT   $(draw_bar 0)  ${DIM}Sprich ${CHECK_SECS}s lang... ⏱ ${CHECK_SECS}s${NC}\033[K"

MIC_PIPE=$(mktemp -u /tmp/micpipe.XXXXXX)
mkfifo "$MIC_PIPE"

rec -q -c $CHANNELS -r $RATE -b $BITS -e signed-integer -t raw - \
    trim 0 $CHECK_SECS 2>/dev/null \
    | tee "$FILE" > "$MIC_PIPE" &
REC_PID=$!

exec 3<"$MIC_PIPE"

max_peak=0
chunk_i=0

while (( chunk_i < CHUNK_COUNT )); do
    chunk_data=$(dd bs=$CHUNK_BYTES count=1 <&3 2>/dev/null | od -An -td2 -v | tr -s ' \n' '\n')

    peak=$(echo "$chunk_data" | awk 'BEGIN{m=0} $1!=""{v=$1+0; if(v<0)v=-v; if(v>m)m=v} END{print m+0}')
    [[ -z "$peak" ]] && peak=0
    (( peak > max_peak )) && max_peak=$peak

    remaining=$(( CHECK_SECS - chunk_i / 5 ))

    printf "\r  🎙 INPUT   $(draw_bar "$peak")  ${DIM}Sprich ${CHECK_SECS}s lang... ⏱ %ds${NC}\033[K" "$remaining"

    (( chunk_i++ ))
done

exec 3<&-
wait "$REC_PID" 2>/dev/null
rm -f "$MIC_PIPE"
MIC_PIPE=""

# --- INPUT Ergebnis ---
printf "\r  🎙 INPUT   $(draw_vu "$max_peak")\033[K"

# ━━━ PEGEL-BEWERTUNG ━━━
if (( max_peak < 300 )); then
    echo ""
    echo -e "  ${RED}${BOLD}✗ KEIN SIGNAL${NC} – Mic empfängt nichts!"
    echo ""

    if (( KEEP_DEVICES == 1 )); then
        echo -e "  ${DIM}(--keep aktiv, kein Gerätewechsel)${NC}"
        echo ""
        echo -e "  ${BG_RED}${BOLD} ✗ MIKROFON PROBLEM – NICHT ANRUFEN ${NC}"
        echo ""
        tput cnorm
        exit 1
    fi

    tput cnorm
    SWITCHED=0

    if [[ -n "$USB_SRC_ID" && "$CURRENT_SRC_TYPE" != "usb" ]]; then
        echo -e "  ${GREEN}●${NC} USB verfügbar: ${BOLD}${USB_SRC_NAME}${NC}"
        read -r -p "    Auf USB umschalten? [J/n] " answer
        answer=${answer:-j}
        if [[ "$answer" =~ ^[jJyY]$ ]]; then
            echo ""
            switch_to_device "$USB_SRC_ID" "$USB_SRC_NAME" "$USB_SINK_ID" "$USB_SINK_NAME"
            SWITCHED=1
        fi
    fi

    if (( SWITCHED == 0 )) && [[ -n "$BT_SRC_ID" && "$CURRENT_SRC_TYPE" != "bluetooth" ]]; then
        echo -e "  ${CYAN}●${NC} BT verfügbar: ${BOLD}${BT_SRC_NAME}${NC}"
        read -r -p "    Auf Bluetooth umschalten? [J/n] " answer
        answer=${answer:-j}
        if [[ "$answer" =~ ^[jJyY]$ ]]; then
            echo ""
            switch_to_device "$BT_SRC_ID" "$BT_SRC_NAME" "$BT_SINK_ID" "$BT_SINK_NAME"
            SWITCHED=1
        fi
    fi

    if (( SWITCHED == 0 )); then
        echo -e "  ${DIM}Tipps: Kabel prüfen · Mute-Schalter · ./mic-check.sh --debug${NC}"
        echo ""
        echo -e "  ${BG_RED}${BOLD} ✗ MIKROFON PROBLEM – NICHT ANRUFEN ${NC}"
        echo ""
        tput cnorm
        exit 1
    fi

elif (( max_peak < 2000 )); then
    VERDICT="WARN"
elif (( max_peak > 30000 )); then
    VERDICT="WARN"
else
    VERDICT="OK"
fi

# ━━━ PHASE 3: Wiedergabe (sequenziell) ━━━
if [[ -s "$FILE" && -n "$VERDICT" ]]; then
    # Cursor ist am Ende der INPUT-Zeile – zeige "Warte..." während Wiedergabe startet
    printf "  ${DIM}Warte...${NC}"

    PLAY_PIPE=$(mktemp -u /tmp/playpipe.XXXXXX)
    mkfifo "$PLAY_PIPE"

    sox -q -t raw -r $RATE -c $CHANNELS -b $BITS -e signed-integer "$FILE" \
        -t raw -r $RATE -c $CHANNELS -b $BITS -e signed-integer - 2>/dev/null \
        | tee >(sox -q -t raw -r $RATE -c $CHANNELS -b $BITS -e signed-integer - \
                -d 2>/dev/null) > "$PLAY_PIPE" &
    PLAY_PID=$!

    exec 4<"$PLAY_PIPE"

    playback_first=1
    while true; do
        chunk_data=$(dd bs=$CHUNK_BYTES count=1 <&4 2>/dev/null | od -An -td2 -v | tr -s ' \n' '\n')
        peak=$(echo "$chunk_data" | awk 'BEGIN{m=0} $1!=""{v=$1+0; if(v<0)v=-v; if(v>m)m=v} END{print m+0}')
        [[ -z "$peak" ]] && peak=0

        if (( peak == 0 )); then
            kill -0 "$PLAY_PID" 2>/dev/null || break
        fi

        if (( playback_first )); then
            # INPUT finalisieren (Warte... → ✓), OUTPUT starten
            printf "\r  🎙 INPUT   $(draw_vu "$max_peak") ${GREEN}✓${NC}\033[K\n"
            printf "  🔊 OUTPUT $(draw_vu "$peak")\033[K"
            playback_first=0
        else
            printf "\r  🔊 OUTPUT $(draw_vu "$peak")\033[K"
        fi
    done

    exec 4<&-
    wait "$PLAY_PID" 2>/dev/null
    rm -f "$PLAY_PIPE"
    PLAY_PIPE=""

    # Finale Anzeige
    if (( playback_first )); then
        # Wiedergabe hatte keine Frames
        printf "\r  🎙 INPUT   $(draw_vu "$max_peak") ${GREEN}✓${NC}\033[K\n"
        printf "  🔊 OUTPUT $(draw_vu "$max_peak") ${GREEN}✓${NC}\033[K\n"
    else
        printf "\r  🔊 OUTPUT $(draw_vu "$max_peak") ${GREEN}✓${NC}\033[K\n"
    fi
else
    # Kein Playback, INPUT finalisieren
    if [[ -n "$VERDICT" ]]; then
        printf " ${GREEN}✓${NC}\033[K\n"
    fi
fi
echo ""

# ━━━ SNR + Frequenzgang (kompakt, eine Zeile) ━━━
if [[ -n "$VERDICT" ]]; then
    calculate_snr
    check_frequency_response

    STATS_LINE="  "

    # Pegel-Bewertung
    if [[ "$VERDICT" == "OK" ]]; then
        STATS_LINE+="${GREEN}✓ Pegel OK${NC}"
    elif (( max_peak < 2000 )); then
        STATS_LINE+="${YELLOW}⚠ Sehr leise${NC}"
    else
        STATS_LINE+="${YELLOW}⚠ Clipping${NC}"
    fi

    # SNR
    if [[ -n "$SNR_DB" ]]; then
        local_snr_int=${SNR_DB%%.*}
        snr_color="$GREEN"
        (( local_snr_int < 25 )) && snr_color="$YELLOW"
        (( local_snr_int < 15 )) && snr_color="$RED"
        STATS_LINE+=" │ SNR: ${snr_color}${SNR_DB}dB${NC} ${DIM}(${SNR_RATING})${NC}"
    fi

    # Frequenz
    if [[ -n "$FREQ_OK" ]]; then
        if [[ "$FREQ_OK" == "OK" ]]; then
            STATS_LINE+=" │ Freq: ${GREEN}>4kHz ✓${NC}"
        else
            STATS_LINE+=" │ Freq: ${YELLOW}≤4kHz${NC}"
        fi
    fi

    echo -e "$STATS_LINE"
    echo ""
fi

# ━━━ ERGEBNIS ━━━
# Ergebnis loggen
if [[ -n "$VERDICT" ]]; then
    log_result
fi

case "$VERDICT" in
    OK)
        echo -e "  ══ ${BG_GREEN}${BOLD} ✅ BEREIT FÜR DEN ANRUF ${NC} ${DIM}(log:${LOG_FILE})${NC} ══"
        ;;
    WARN)
        echo -e "  ══ ${YELLOW}${BOLD} ⚠  PEGEL ANPASSEN ${NC} ${DIM}(log:${LOG_FILE})${NC} ══"
        ;;
esac

echo ""
tput cnorm
