#!/bin/bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  PRE-CALL MIC CHECK
#  mit USB / Bluetooth Auto-Erkennung
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
VERSION="1.5.0"
# Stabile (englische) Ausgabe von pactl/sox und '.' als Dezimalpunkt.
# LANG allein reicht nicht, wenn der Benutzer LC_ALL oder LC_MESSAGES setzt.
export LC_ALL=C.UTF-8

# --- CONFIG (kann in ~/.config/mic-check/config überschrieben werden) ---
CHECK_SECS=3          # Länge der Sprachaufnahme
NOISE_SECS=1          # Länge der Rauschboden-Messung
WAIT_SECS=5           # max. Wartezeit, bis du zu sprechen beginnst
RATE=44100
CHANNELS=1
BITS=16               # muss 16 bleiben (Auswertung liest 16-Bit-Samples)
CHUNKS_PER_SEC=10     # Aktualisierungsrate der Pegelanzeige
BAR_W=30              # Breite der Pegelanzeige (Zeichen)
DB_FLOOR=-60          # linker Rand der Pegelanzeige (dBFS)
MAX_AUTO_SWITCHES=4   # Schutz gegen Umschalt-Schleifen
LOG_FILE="${HOME}/.mic-check.log"

# Bewertung (dBFS)
LVL_NO_SIGNAL=-40     # Sprach-Peak darunter → kein Signal
LVL_QUIET=-24         # darunter → zu leise
LVL_CLIP=-1           # darüber → übersteuert
LVL_TARGET=-9         # Ziel-Peak der automatischen Gain-Korrektur
NOISE_GOOD=-56        # Rauschboden (RMS) darunter → sehr gut
NOISE_OK=-44          # darunter → akzeptabel, sonst hoch
SNR_EXCELLENT=30
SNR_GOOD=20
SNR_OK=12             # darunter → Hintergrund zu laut
BW_MIN_DB=-30         # Energie 4.5–7.5 kHz relativ zu 1–4 kHz; darunter → Schmalband
MAX_GAIN_PCT=150      # Obergrenze der Gain-Korrektur
BATTERY_WARN=20       # BT-Akku in %, darunter Warnung
READ_PROMPT="Sechs Schweizer Spezialisten testen das Mikrofon."
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/mic-check/config"
# shellcheck source=/dev/null
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
# -----------------------------------------------------------------------

show_help() {
    cat <<EOF
mic-check v${VERSION} – Schneller Mikrofon-Test vor Anrufen

Verwendung:  ./mic-check.sh [OPTIONEN]

Optionen:
  --help          Diese Hilfe anzeigen
  --version       Versionsnummer anzeigen
  --keep          Aktuelle Geräte beibehalten, nichts umschalten
  --no-playback   Aufnahme nicht abspielen (kein Ausgabe-Test)
  --no-menu       Nach dem Ergebnis direkt beenden
  --no-clear      Bildschirm vorher nicht löschen
  --ascii         Ohne Emojis (bei Darstellungsproblemen im Terminal)
  --debug         Debug-Infos zur Geräte-Erkennung
  --list          Alle Audio-Geräte auflisten
  --history [N]   Letzte N Test-Ergebnisse anzeigen (Standard: 20)

Was das Script macht:
  1. Erkennt Audio-Server, Mikrofon und Ausgabe (USB / Bluetooth / Intern)
  2. Schlägt das beste Gerät vor (USB > Bluetooth > Webcam > Intern)
  3. Wechselt Bluetooth auf das beste Headset-Profil (z.B. CVSD → mSBC)
  4. Bietet an, stummes Mikrofon / stumme Ausgabe einzuschalten
  5. Misst Rauschboden, Sprachpegel, SNR und Bandbreite (4kHz-Cutoff)
  6. Spielt die Aufnahme ab und fragt, ob du dich gehört hast
  7. Prüft, ob laufende Apps (Zoom, Browser…) das getestete Mikro nutzen
  8. Warnt vor Echo-Gefahr und schwachem Headset-Akku
  9. Korrigiert den Mic-Pegel auf Tastendruck
 10. Speichert Ergebnisse in ${LOG_FILE}

Tasten nach dem Test:
  Enter/q Ende · r Nochmal · p Anhören · g Gain anpassen
  a Apps umleiten · d Gerät wählen

Abhängigkeiten:  sox, pactl (libpulse bzw. pulseaudio-utils)
Konfiguration:   ${CONFIG_FILE}

Alias-Tipp:  echo 'alias miccheck="~/mic-check/mic-check.sh"' >> ~/.bashrc
EOF
}

# ━━━ OPTIONEN ━━━
KEEP_DEVICES=0
DEBUG=0
NO_PLAYBACK=0
NO_MENU=0
NO_CLEAR=0
ASCII=0
ACTION="check"
HISTORY_N=20

while (( $# )); do
    case "$1" in
        --help|-h)     ACTION="help" ;;
        --version|-v)  ACTION="version" ;;
        --keep)        KEEP_DEVICES=1 ;;
        --debug)       DEBUG=1 ;;
        --list)        ACTION="list" ;;
        --history)
            ACTION="history"
            if [[ "${2:-}" =~ ^[0-9]+$ ]]; then HISTORY_N=$2; shift; fi ;;
        --no-playback) NO_PLAYBACK=1 ;;
        --no-menu)     NO_MENU=1 ;;
        --no-clear)    NO_CLEAR=1 ;;
        --ascii)       ASCII=1 ;;
        *)
            echo "mic-check: unbekannte Option '$1' (siehe --help)" >&2
            exit 2 ;;
    esac
    shift
done

# ━━━ AUSGABE / FARBEN / SYMBOLE ━━━
IS_TTY=0;      [[ -t 1 ]] && IS_TTY=1
INTERACTIVE=0; [[ -t 0 && -t 1 ]] && INTERACTIVE=1
TIMEOUT_CMD=(); command -v timeout >/dev/null && TIMEOUT_CMD=(timeout 5)

setup_ui() {
    if (( IS_TTY )) && [[ -z "${NO_COLOR:-}" ]]; then
        RED=$'\e[0;31m'; GREEN=$'\e[0;32m'; YELLOW=$'\e[1;33m'; CYAN=$'\e[0;36m'
        BOLD=$'\e[1m'; DIM=$'\e[2m'; NC=$'\e[0m'
        BG_RED=$'\e[41m'; BG_GREEN=$'\e[42m'; BG_YELLOW=$'\e[43;30m'
    else
        RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; DIM=""; NC=""
        BG_RED=""; BG_GREEN=""; BG_YELLOW=""
    fi
    EL=""; (( IS_TTY )) && EL=$'\e[K'

    if (( ASCII )); then
        I_TITLE="MIC CHECK"; I_MIC="MIC"; I_OUT="OUT"; I_HUSH="..."; I_SAY=">>"
        I_HEADSET="Headset"; I_MUSIC="Musik"; I_BAT="Akku"; I_WAIT="..."
        I_OK="OK"; I_WARN="!"; I_FAIL="X"; I_INFO="i"; I_REDO="->"; I_DOT="*"; I_REC="REC"
        I_READY="[OK]"; I_NOTREADY="[X]"; I_WARNB="[!] "; SEP="|"
        BAR_FULL="#"; BAR_EMPTY="."; BAR_ZONE=":"; BAR_PEAK="|"
    else
        I_TITLE="🎧🎙 MIC CHECK"; I_MIC="🎤"; I_OUT="🔊"; I_HUSH="🤫"; I_SAY="💬"
        I_HEADSET="🎧🎙 Headset"; I_MUSIC="🎧 Musik"; I_BAT="🔋"; I_WAIT="⏳"
        I_OK="✓"; I_WARN="⚠"; I_FAIL="✗"; I_INFO="ℹ"; I_REDO="↻"; I_DOT="●"; I_REC="● REC"
        I_READY="✅"; I_NOTREADY="❌"; I_WARNB="⚠  "; SEP="│"
        BAR_FULL="█"; BAR_EMPTY="░"; BAR_ZONE="▒"; BAR_PEAK="│"
    fi

    # Schmale Terminals: Pegelanzeige verkürzen, damit die Live-Zeile nicht umbricht
    if (( IS_TTY )); then
        local cols
        cols=$(tput cols 2>/dev/null)
        if [[ "$cols" =~ ^[0-9]+$ ]] && (( cols < BAR_W + 48 )); then
            BAR_W=$(( cols - 48 ))
            (( BAR_W < 10 )) && BAR_W=10
        fi
    fi

    # Zielzone der Pegelanzeige (in Zeichen)
    db_cells "$LVL_QUIET"; ZONE_START=$REPLY
    db_cells "$LVL_CLIP";  ZONE_END=$(( REPLY - 1 ))
}

say()      { printf '%s\n' "$*"; }
cur_hide() { (( IS_TTY )) && tput civis 2>/dev/null; return 0; }
cur_show() { (( IS_TTY )) && tput cnorm 2>/dev/null; return 0; }
# Gleitkomma-Vergleich: flt A B  →  wahr, wenn A < B
flt()      { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 < b + 0) }'; }
# dBFS → Anzahl Zeichen der Pegelanzeige (REPLY)
db_cells() {
    REPLY=$(awk -v d="$1" -v f="$DB_FLOOR" -v w="$BAR_W" \
        'BEGIN { c = int((d - f) / (-f) * w); if (c < 0) c = 0; if (c > w) c = w; print c }')
}
# Restliche Tastendrücke (z.B. Pfeiltasten-Sequenzen) verwerfen
drain_keys() { local _k; while read -rsn1 -t 0.01 _k; do :; done; return 0; }

# ━━━ ABFRAGEN ━━━
ask_yn() {   # $1 = Frage → 0 = ja (Standard), 1 = nein / nicht interaktiv
    (( INTERACTIVE )) || return 1
    local ans
    cur_show
    read -r -p "    $1 [J/n] " ans
    cur_hide
    [[ -z "$ans" || "$ans" =~ ^[jJyY] ]]
}

countdown() {   # $1 = Nachricht, $2 = Sekunden → 0 = ausführen, 1 = übersprungen
    (( INTERACTIVE )) || return 1
    local msg="$1" secs="${2:-3}" key end remain
    cur_show
    # Restzeit kommt aus der Uhr: Tastendrücke verkürzen den Countdown nicht
    end=$(( SECONDS + secs ))
    while (( (remain = end - SECONDS) > 0 )); do
        printf '\r    %s%s %s in %s%ss%s%s – [beliebige Taste] = überspringen%s%s' \
            "$YELLOW" "$I_WAIT" "$msg" "$BOLD" "$remain" "$NC" "$YELLOW" "$NC" "$EL"
        if read -rsn1 -t 1 key; then
            drain_keys
            printf '\r    %s↷ Übersprungen.%s%s\n' "$DIM" "$NC" "$EL"
            cur_hide
            return 1
        fi
    done
    printf '\r%s' "$EL"
    cur_hide
    return 0
}

# ━━━ GERÄTE-ERKENNUNG (pactl) ━━━
# pactl funktioniert mit PipeWire (pipewire-pulse) und PulseAudio und hat –
# anders als 'wpctl status' – ein über Versionen stabiles Ausgabeformat.
# Geräte werden über ihre Eigenschaften (node.name, device.api, device.bus)
# erkannt statt über Markennamen in der Beschreibung.

PA_NODE_AWK='
function val(s) { sub(/^[^"]*"/, "", s); sub(/"[^"]*$/, "", s); return s }
function rest(s) { return substr(s, index(s, ": ") + 2) }
function flush() {
    if (name != "" && !mon && name !~ /capture_internal/ && mclass !~ /Internal/) {
        gsub(/\|/, "/", desc)
        print name "|" desc "|" mute "|" vol "|" api "|" bus "|" ff "|" addr "|" codec "|" port
    }
    name = desc = mute = vol = api = bus = ff = addr = codec = port = mclass = ""; mon = 0
}
/^(Source|Sink) #/                  { flush(); next }
/^\tName: /                         { name = rest($0); next }
/^\tDescription: /                  { desc = rest($0); next }
/^\tMute: /                         { mute = $2; next }
/^\tVolume: /                       { if (vol == "" && match($0, /[0-9]+%/)) vol = substr($0, RSTART, RLENGTH - 1); next }
/^\tMonitor of Sink: /              { if ($0 !~ /n\/a$/) mon = 1; next }
/^\tActive Port: /                  { port = rest($0); next }
/^\t\tdevice\.api = /               { api = val($0); next }
/^\t\tdevice\.bus = /               { bus = val($0); next }
/^\t\tdevice\.form_factor = /       { ff = val($0); next }
/^\t\tdevice\.class = "monitor"/    { mon = 1; next }
/^\t\tapi\.bluez5\.address = /      { addr = val($0); next }
/^\t\tapi\.bluez5\.codec = /        { codec = val($0); next }
/^\t\tmedia\.class = /              { mclass = val($0); next }
END { flush() }
'

PA_CARD_AWK='
function val(s) { sub(/^[^"]*"/, "", s); sub(/"[^"]*$/, "", s); return s }
function rest(s) { return substr(s, index(s, ": ") + 2) }
/^Card #/                           { name = addr = desc = api = ""; inprof = 0; next }
/^\tName: /                         { name = rest($0); next }
/^\t\tapi\.bluez5\.address = /      { addr = val($0); next }
/^\t\tdevice\.description = /       { desc = val($0); next }
/^\t\tdevice\.api = /               { api = val($0); next }
/^\tProfiles:/                      { inprof = 1; next }
/^\tActive Profile: /               { gsub(/\|/, "/", desc); print "C|" name "|" addr "|" desc "|" api "|" rest($0); inprof = 0; next }
/^\t[^\t]/                          { inprof = 0; next }
inprof && /^\t\t[^\t]/ {
    l = substr($0, 3)
    pn = substr(l, 1, index(l, ": ") - 1)
    pd = substr(l, index(l, ": ") + 2)
    snk = 0; src = 0; av = "yes"
    if (match(pd, /sinks: [0-9]+/))      snk = substr(pd, RSTART + 7, RLENGTH - 7)
    if (match(pd, /sources: [0-9]+/))    src = substr(pd, RSTART + 9, RLENGTH - 9)
    if (match(pd, /available: [a-z]+/))  av = substr(pd, RSTART + 11, RLENGTH - 11)
    lbl = pd; sub(/ \(sinks: .*$/, "", lbl)
    cod = ""
    if (match(lbl, /codec [^),]+/)) cod = substr(lbl, RSTART + 6, RLENGTH - 6)
    gsub(/\|/, "/", lbl)
    print "P|" name "|" pn "|" lbl "|" snk "|" src "|" av "|" cod
}
'

PA_SO_AWK='
function val(s) { sub(/^[^"]*"/, "", s); sub(/"[^"]*$/, "", s); return s }
function flush() {
    if (idx != "") { gsub(/\|/, "/", app); gsub(/\|/, "/", bin); gsub(/\|/, "/", media); print idx "|" src "|" app "|" bin "|" media }
    idx = src = app = bin = media = ""
}
/^Source Output #/                       { flush(); idx = substr($0, index($0, "#") + 1); next }
/^\tSource: /                            { src = $2; next }
/^\t\tapplication\.name = /              { app = val($0); next }
/^\t\tapplication\.process\.binary = /   { bin = val($0); next }
/^\t\tmedia\.name = /                    { media = val($0); next }
END { flush() }
'

# Verbindungstyp aus Node-Eigenschaften (REPLY)
classify_node() {   # $1=name $2=device.api $3=device.bus $4=form_factor $5=Beschreibung
    local n="${1,,}" api="${2,,}" bus="${3,,}" ff="${4,,}" d="${5,,}"
    if [[ "$n" == bluez* || "$api" == bluez* || "$bus" == bluetooth ]]; then
        REPLY="bluetooth"
    elif [[ "$bus" == usb || "$n" == alsa_*.usb-* ]]; then
        if [[ "$ff" == webcam || "$d" == *webcam* || "$d" == *camera* || "$d" == *brio* \
              || "$d" =~ (^|[^a-z])c9[0-9][0-9]([^0-9]|$) ]]; then
            REPLY="webcam"
        else
            REPLY="usb"
        fi
    elif [[ "$n" == alsa_* || "$api" == alsa ]]; then
        if [[ "$n" == *hdmi* || "$d" == *hdmi* || "$d" == *displayport* ]]; then
            REPLY="hdmi"
        else
            REPLY="internal"
        fi
    else
        REPLY="virtual"   # Filter, Effekte (EasyEffects, Rauschfilter, Echo-Cancel …)
    fi
}

# Bluetooth-Adresse aus einem Node-/Kartennamen (REPLY, Format AA:BB:…)
mac_from() {
    REPLY=""
    if [[ "$1" =~ ([0-9A-Fa-f]{2}[_:]){5}[0-9A-Fa-f]{2} ]]; then
        REPLY="${BASH_REMATCH[0]//_/:}"
        REPLY="${REPLY^^}"
    fi
}

# Geräteschlüssel: verbindet Mikrofon, Ausgabe und Karte desselben Geräts (REPLY)
device_key() {   # $1=name $2=BT-Adresse
    local n="$1" s
    if [[ -n "$2" ]]; then
        REPLY="bt:${2^^}"
    elif [[ "$n" == alsa_card.* ]]; then
        REPLY="alsa:${n#alsa_card.}"
    elif [[ "$n" == alsa_* ]]; then
        s="${n#*.}"
        REPLY="alsa:${s%.*}"
    else
        REPLY="node:$n"
    fi
}

codec_label() {   # Rohname → Anzeigename (REPLY)
    case "${1,,}" in
        "")                           REPLY="" ;;
        msbc)                         REPLY="mSBC" ;;
        cvsd)                         REPLY="CVSD" ;;
        sbc)                          REPLY="SBC" ;;
        sbc_xq|sbc-xq)                REPLY="SBC-XQ" ;;
        aac*)                         REPLY="AAC" ;;
        ldac)                         REPLY="LDAC" ;;
        aptx)                         REPLY="aptX" ;;
        aptx_hd|aptx-hd|"aptx hd")    REPLY="aptX HD" ;;
        aptx_ll*|aptx-ll*|"aptx ll"*) REPLY="aptX LL" ;;
        faststream*)                  REPLY="FastStream" ;;
        lc3_swb|lc3-swb|"lc3 swb")    REPLY="LC3-SWB" ;;
        lc3*)                         REPLY="LC3" ;;
        opus*)                        REPLY="Opus" ;;
        *)                            REPLY="$1" ;;
    esac
}

codec_khz() {   # Abtastrate des Mikrofons je Codec (REPLY, leer = unbekannt)
    case "$1" in
        CVSD)    REPLY="8 kHz" ;;
        mSBC)    REPLY="16 kHz" ;;
        LC3-SWB) REPLY="32 kHz" ;;
        *)       REPLY="" ;;
    esac
}

mic_rank() {   # Mikrofon-Qualität eines Headset-Codecs (REPLY, höher = besser)
    case "$1" in
        LC3-SWB|LC3)               REPLY=5 ;;
        mSBC)                      REPLY=4 ;;
        FastStream|"aptX LL"|Opus) REPLY=3 ;;
        CVSD)                      REPLY=1 ;;
        *)                         REPLY=2 ;;
    esac
}

src_rank() {   # Bevorzugung beim Vorschlagen (REPLY)
    case "$1" in
        usb)       REPLY=4 ;;
        bluetooth) REPLY=3 ;;
        webcam)    REPLY=2 ;;
        internal)  REPLY=1 ;;
        *)         REPLY=0 ;;
    esac
}

type_label() {   # kurzes, farbiges Label (REPLY)
    case "$1" in
        usb)       REPLY="${GREEN}USB${NC}" ;;
        bluetooth) REPLY="${CYAN}BT${NC}" ;;
        webcam)    REPLY="${CYAN}Webcam${NC}" ;;
        internal)  REPLY="${DIM}Intern${NC}" ;;
        hdmi)      REPLY="${DIM}HDMI${NC}" ;;
        virtual)   REPLY="${DIM}Virtuell${NC}" ;;
        *)         REPLY="${DIM}–${NC}" ;;
    esac
}

type_name() {   # ausgeschrieben (REPLY)
    case "$1" in
        usb)       REPLY="USB-Mikrofon" ;;
        bluetooth) REPLY="Bluetooth-Headset" ;;
        webcam)    REPLY="Webcam-Mikrofon" ;;
        internal)  REPLY="internes Mikrofon" ;;
        hdmi)      REPLY="HDMI" ;;
        virtual)   REPLY="virtuelle Quelle" ;;
        *)         REPLY="kein Mikrofon" ;;
    esac
}

load_nodes() {   # $1 = sources|sinks, $2 = Array-Präfix (SRC|SINK)
    local -n _name="${2}_NAME" _desc="${2}_DESC" _mute="${2}_MUTE" _vol="${2}_VOL" \
             _type="${2}_TYPE" _key="${2}_KEY" _codec="${2}_CODEC" _port="${2}_PORT"
    _name=(); _desc=(); _mute=(); _vol=(); _type=(); _key=(); _codec=(); _port=()
    local name desc mute vol api bus ff addr codec port i=0
    while IFS='|' read -r name desc mute vol api bus ff addr codec port; do
        [[ -z "$name" ]] && continue
        _name[i]="$name"
        _desc[i]="${desc:-$name}"
        _mute[i]="$mute"
        _vol[i]="${vol:-0}"
        classify_node "$name" "$api" "$bus" "$ff" "$desc"
        _type[i]="$REPLY"
        if [[ -z "$addr" && "$REPLY" == bluetooth ]]; then
            mac_from "$name"; addr="$REPLY"
        fi
        device_key "$name" "$addr"
        _key[i]="$REPLY"
        codec_label "$codec"
        _codec[i]="$REPLY"
        _port[i]="$port"
        (( i++ ))
    done < <(pactl list "$1" 2>/dev/null | awk "$PA_NODE_AWK")
}

load_cards() {
    CARD_NAME=(); CARD_ADDR=(); CARD_DESC=(); CARD_ACTIVE=(); CARD_KEY=(); CARD_BEST_MIC=()
    PROF_CARD=(); PROF_NAME=(); PROF_LABEL=(); PROF_SOURCES=(); PROF_AVAIL=(); PROF_CODEC=()
    local -A cidx=()
    local -a pcard=()
    local tag f1 f2 f3 f5 f6 f7 c=0 j=0 addr
    while IFS='|' read -r tag f1 f2 f3 _ f5 f6 f7; do
        if [[ "$tag" == C ]]; then
            addr="$f2"
            if [[ -z "$addr" && "${f1,,}" == bluez* ]]; then mac_from "$f1"; addr="$REPLY"; fi
            CARD_NAME[c]="$f1"; CARD_ADDR[c]="$addr"; CARD_DESC[c]="${f3:-$f1}"; CARD_ACTIVE[c]="$f5"
            device_key "$f1" "$addr"; CARD_KEY[c]="$REPLY"
            cidx["$f1"]=$c
            (( c++ ))
        elif [[ "$tag" == P ]]; then
            pcard[j]="$f1"; PROF_NAME[j]="$f2"; PROF_LABEL[j]="$f3"
            PROF_SOURCES[j]="${f5:-0}"; PROF_AVAIL[j]="$f6"
            codec_label "$f7"; PROF_CODEC[j]="$REPLY"
            (( j++ ))
        fi
    done < <(pactl list cards 2>/dev/null | awk "$PA_CARD_AWK")

    for j in "${!PROF_NAME[@]}"; do
        PROF_CARD[j]="${cidx[${pcard[j]}]:--1}"
    done

    # Bestes (verfügbares) Headset-Profil mit Mikrofon je Karte
    local best best_rank
    for c in "${!CARD_NAME[@]}"; do
        best=""; best_rank=0
        for j in "${!PROF_NAME[@]}"; do
            (( PROF_CARD[j] == c && PROF_SOURCES[j] > 0 )) || continue
            [[ "${PROF_AVAIL[j]}" == no ]] && continue
            mic_rank "${PROF_CODEC[j]}"
            if (( REPLY > best_rank )); then best=$j; best_rank=$REPLY; fi
        done
        CARD_BEST_MIC[c]="$best"
    done
}

profile_index() {   # $1 = Karte, $2 = Profilname → REPLY = Index oder -1
    local j
    REPLY=-1
    for j in "${!PROF_NAME[@]}"; do
        if (( PROF_CARD[j] == $1 )) && [[ "${PROF_NAME[j]}" == "$2" ]]; then REPLY=$j; return; fi
    done
}

card_for_key() {
    local c
    REPLY=-1
    for c in "${!CARD_NAME[@]}"; do
        [[ "${CARD_KEY[c]}" == "$1" ]] && { REPLY=$c; return; }
    done
}

source_for_key() {
    local i
    REPLY=-1
    for i in "${!SRC_NAME[@]}"; do
        [[ "${SRC_KEY[i]}" == "$1" ]] && { REPLY=$i; return; }
    done
}

sink_for_key() {   # bevorzugt Analog vor Digital (IEC958/S/PDIF)
    local i digital=-1 n
    REPLY=-1
    for i in "${!SINK_NAME[@]}"; do
        [[ "${SINK_KEY[i]}" == "$1" ]] || continue
        n="${SINK_NAME[i],,} ${SINK_DESC[i],,}"
        if [[ "$n" == *iec958* || "$n" == *spdif* || "$n" == *s/pdif* || "$n" == *digital* ]]; then
            (( digital < 0 )) && digital=$i
        else
            REPLY=$i; return
        fi
    done
    REPLY=$digital
}

is_skipped() {   # Gerät wurde abgelehnt oder hatte kein Signal
    [[ -n "${DECLINED[$1]:-}" || -n "${NOSIG_TRIED[$1]:-}" ]]
}

detect_all() {
    local info line
    info=$(pactl info 2>/dev/null) || return 1
    SERVER_NAME=""; SERVER_VERSION=""; DEFAULT_SOURCE=""; DEFAULT_SINK=""
    while IFS= read -r line; do
        case "$line" in
            "Server Name: "*)    SERVER_NAME="${line#Server Name: }" ;;
            "Server Version: "*) SERVER_VERSION="${line#Server Version: }" ;;
            "Default Source: "*) DEFAULT_SOURCE="${line#Default Source: }" ;;
            "Default Sink: "*)   DEFAULT_SINK="${line#Default Sink: }" ;;
        esac
    done <<< "$info"

    if [[ "$SERVER_NAME" =~ PipeWire[[:space:]]+([0-9.]+) ]]; then
        AUDIO_SRV="PipeWire v${BASH_REMATCH[1]}"
    elif [[ "$SERVER_NAME" == *PipeWire* ]]; then
        AUDIO_SRV="PipeWire"
    else
        AUDIO_SRV="PulseAudio${SERVER_VERSION:+ v$SERVER_VERSION}"
    fi
    if command -v pgrep >/dev/null && pgrep -x wireplumber >/dev/null 2>&1; then
        AUDIO_SRV+=" + wireplumber"
    fi

    load_nodes sources SRC
    load_nodes sinks SINK
    load_cards

    local i
    CUR_SRC=-1; CUR_SINK=-1
    for i in "${!SRC_NAME[@]}";  do [[ "${SRC_NAME[i]}"  == "$DEFAULT_SOURCE" ]] && CUR_SRC=$i;  done
    for i in "${!SINK_NAME[@]}"; do [[ "${SINK_NAME[i]}" == "$DEFAULT_SINK" ]]   && CUR_SINK=$i; done

    MIC_DESC=""; (( CUR_SRC >= 0 ))  && MIC_DESC="${SRC_DESC[CUR_SRC]}"
    OUT_DESC=""; (( CUR_SINK >= 0 )) && OUT_DESC="${SINK_DESC[CUR_SINK]}"

    # Bluetooth: aktives Gerät (Mikrofon hat Vorrang vor Ausgabe)
    BT_KEY=""; BT_CARD=-1; BT_CODEC=""; BT_ADDR=""; BT_BATTERY=""; BT_ROLE=""
    if (( CUR_SRC >= 0 )) && [[ "${SRC_TYPE[CUR_SRC]}" == bluetooth ]]; then
        BT_KEY="${SRC_KEY[CUR_SRC]}"; BT_CODEC="${SRC_CODEC[CUR_SRC]}"; BT_ROLE="mic"
    elif (( CUR_SINK >= 0 )) && [[ "${SINK_TYPE[CUR_SINK]}" == bluetooth ]]; then
        BT_KEY="${SINK_KEY[CUR_SINK]}"; BT_CODEC="${SINK_CODEC[CUR_SINK]}"; BT_ROLE="out"
    fi
    if [[ -n "$BT_KEY" ]]; then
        card_for_key "$BT_KEY"; BT_CARD=$REPLY
        [[ "$BT_KEY" == bt:* ]] && BT_ADDR="${BT_KEY#bt:}"
        if (( BT_CARD >= 0 )); then
            profile_index "$BT_CARD" "${CARD_ACTIVE[BT_CARD]}"
            # Codec des aktiven Profils ist verlässlicher als die Node-Eigenschaft
            (( REPLY >= 0 )) && [[ -n "${PROF_CODEC[REPLY]}" ]] && BT_CODEC="${PROF_CODEC[REPLY]}"
        fi
        if [[ -n "$BT_ADDR" ]] && command -v bluetoothctl >/dev/null; then
            local bt_info
            bt_info=$("${TIMEOUT_CMD[@]}" bluetoothctl info "$BT_ADDR" 2>/dev/null)
            [[ "$bt_info" =~ Battery\ Percentage:\ 0x[0-9A-Fa-f]+\ \(([0-9]+)\) ]] && BT_BATTERY="${BASH_REMATCH[1]}"
        fi
    fi
    return 0
}

debug_dump() {
    (( DEBUG )) || return 0
    local i j
    say "  ${DIM}[DEBUG] Server: ${SERVER_NAME} ${SERVER_VERSION}${NC}"
    say "  ${DIM}[DEBUG] Default Source: ${DEFAULT_SOURCE}  (Index ${CUR_SRC})${NC}"
    say "  ${DIM}[DEBUG] Default Sink:   ${DEFAULT_SINK}  (Index ${CUR_SINK})${NC}"
    for i in "${!SRC_NAME[@]}"; do
        say "  ${DIM}[DEBUG] SRC  ${SRC_TYPE[i]}  ${SRC_KEY[i]}  ${SRC_NAME[i]}  vol=${SRC_VOL[i]} mute=${SRC_MUTE[i]} codec=${SRC_CODEC[i]}${NC}"
    done
    for i in "${!SINK_NAME[@]}"; do
        say "  ${DIM}[DEBUG] SINK ${SINK_TYPE[i]}  ${SINK_KEY[i]}  ${SINK_NAME[i]}  vol=${SINK_VOL[i]} mute=${SINK_MUTE[i]} port=${SINK_PORT[i]}${NC}"
    done
    for i in "${!CARD_NAME[@]}"; do
        j="${CARD_BEST_MIC[i]}"
        say "  ${DIM}[DEBUG] CARD ${CARD_KEY[i]}  ${CARD_NAME[i]}  aktiv=${CARD_ACTIVE[i]}  bestes-Mic-Profil=${j:+${PROF_NAME[j]}}${NC}"
        for j in "${!PROF_NAME[@]}"; do
            (( PROF_CARD[j] == i )) || continue
            say "  ${DIM}[DEBUG]      ${PROF_NAME[j]}: codec=${PROF_CODEC[j]:-?} sources=${PROF_SOURCES[j]} available=${PROF_AVAIL[j]}${NC}"
        done
    done
    say "  ${DIM}[DEBUG] BT: key=${BT_KEY} card=${BT_CARD} codec=${BT_CODEC} akku=${BT_BATTERY}${NC}"
    say ""
}

# ━━━ ANZEIGE: KOPF ━━━
vol_label() {   # $1 = Lautstärke %, $2 = Mute → REPLY
    if [[ "$2" == yes ]]; then
        REPLY="${BG_RED}${BOLD} STUMM ${NC}"
    elif (( ${1:-0} < 20 )); then
        REPLY="${YELLOW}${1}%${NC}"
    else
        REPLY="${GREEN}${1}%${NC}"
    fi
}

bt_extra() {   # Codec · kHz · Akku (REPLY)
    local s="" j col
    if [[ -n "$BT_CODEC" ]]; then
        col="$GREEN"
        [[ "$BT_CODEC" == CVSD ]] && col="$RED"
        if [[ "$BT_ROLE" == out ]] && (( BT_CARD >= 0 )); then
            # Ausgabe im Musik-Modus: kein Mikrofon verfügbar
            profile_index "$BT_CARD" "${CARD_ACTIVE[BT_CARD]}"; j=$REPLY
            if (( j >= 0 && PROF_SOURCES[j] == 0 )); then col="$YELLOW"; fi
        fi
        s+="  ${DIM}·${NC} Codec: ${col}${BT_CODEC}${NC}"
        codec_khz "$BT_CODEC"
        [[ -n "$REPLY" && "$BT_ROLE" == mic ]] && s+=" ${DIM}${REPLY}${NC}"
    fi
    if [[ -n "$BT_BATTERY" ]]; then
        col="$GREEN"
        (( BT_BATTERY < BATTERY_WARN )) && col="$RED"
        s+="  ${DIM}·${NC} ${I_BAT} ${col}${BT_BATTERY}%${NC}"
    fi
    REPLY="$s"
}

bt_profiles_line() {   # kompakte Profil-Übersicht der aktiven BT-Karte
    (( BT_CARD >= 0 )) || return 0
    local j item headset="" music=""
    for j in "${!PROF_NAME[@]}"; do
        (( PROF_CARD[j] == BT_CARD )) || continue
        [[ "${PROF_NAME[j]}" == off || "${PROF_AVAIL[j]}" == no ]] && continue
        item="${PROF_CODEC[j]:-${PROF_NAME[j]}}"
        if [[ "${PROF_NAME[j]}" == "${CARD_ACTIVE[BT_CARD]}" ]]; then
            item="${NC}${CYAN}${item} (aktiv)${NC}${DIM}"
        fi
        if (( PROF_SOURCES[j] > 0 )); then
            headset+="${headset:+, }${item}"
        else
            music+="${music:+, }${item}"
        fi
    done
    [[ -z "$headset$music" ]] && return 0
    local line="  ${DIM}BT-Profile:"
    [[ -n "$headset" ]] && line+="  ${I_HEADSET}: ${headset}"
    [[ -n "$headset" && -n "$music" ]] && line+="  ${SEP}"
    [[ -n "$music" ]] && line+="  ${I_MUSIC}: ${music}"
    say "${line}${NC}"
}

print_header() {
    local keep="" extra tl c
    (( KEEP_DEVICES )) && keep=" ${DIM}(--keep)${NC}"
    (( ROUTING_LOCKED && !KEEP_DEVICES )) && keep=" ${DIM}(manuell gewählt)${NC}"
    say "  ${BOLD}${I_TITLE}${NC}${keep} ${DIM}v${VERSION}${NC} ─── ${DIM}${AUDIO_SRV}${NC}"

    extra=""
    if (( CUR_SRC >= 0 )); then
        [[ "$BT_ROLE" == mic ]] && { bt_extra; extra="$REPLY"; }
        type_label "${SRC_TYPE[CUR_SRC]}"; tl="$REPLY"
        vol_label "${SRC_VOL[CUR_SRC]}" "${SRC_MUTE[CUR_SRC]}"
        say "  ${I_MIC} Mic: ${BOLD}${MIC_DESC:0:42}${NC} ${DIM}[${NC}${tl}${DIM}]${NC} ${REPLY}${extra}"
    else
        say "  ${I_MIC} Mic: ${RED}kein Mikrofon gefunden${NC}"
    fi

    extra=""
    if (( CUR_SINK >= 0 )); then
        [[ "$BT_ROLE" == out ]] && { bt_extra; extra="$REPLY"; }
        type_label "${SINK_TYPE[CUR_SINK]}"; tl="$REPLY"
        vol_label "${SINK_VOL[CUR_SINK]}" "${SINK_MUTE[CUR_SINK]}"
        say "  ${I_OUT} Out: ${BOLD}${OUT_DESC:0:42}${NC} ${DIM}[${NC}${tl}${DIM}]${NC} ${REPLY}${extra}"
    else
        say "  ${I_OUT} Out: ${RED}keine Ausgabe gefunden${NC}"
    fi

    bt_profiles_line

    # Was beim letzten Durchlauf umgeschaltet wurde
    for c in "${CHANGES[@]}"; do
        say "  ${GREEN}${I_REDO}${NC} ${c}"
    done
    CHANGES=()
    say ""
}

# ━━━ UMSCHALTEN ━━━
switch_to_source() {   # $1 = Index der Quelle; Ausgabe desselben Geräts wird mitgenommen
    local i=$1 j
    say "  ${DIM}Setze Mikrofon → ${SRC_DESC[i]}${NC}"
    if ! pactl set-default-source "${SRC_NAME[i]}" 2>/dev/null; then
        say "  ${RED}${I_FAIL}${NC} Umschalten fehlgeschlagen"
        return 1
    fi
    CHANGES+=("Mikrofon → ${SRC_DESC[i]}")
    sink_for_key "${SRC_KEY[i]}"; j=$REPLY
    if (( j >= 0 )) && [[ "${SINK_NAME[j]}" != "$DEFAULT_SINK" ]]; then
        say "  ${DIM}Setze Ausgabe  → ${SINK_DESC[j]}${NC}"
        pactl set-default-sink "${SINK_NAME[j]}" 2>/dev/null && CHANGES+=("Ausgabe → ${SINK_DESC[j]}")
    fi
    return 0
}

bt_node_name() {   # $1 = sources|sinks, $2 = BT-Adresse → REPLY = Node-Name
    local a="${2,,}" au
    au="${a//:/_}"
    REPLY=$(pactl list "$1" short 2>/dev/null | awk -v a="$a" -v au="$au" '
        { n = tolower($2) }
        n ~ /bluez/ && n !~ /\.monitor$/ && n !~ /capture_internal/ && (index(n, au) || index(n, a)) { print $2; exit }')
}

switch_bt_profile() {   # $1 = Karte, $2 = Profil-Index → setzt Profil + Defaults
    local c=$1 j=$2 t
    local codec="${PROF_CODEC[j]:-${PROF_NAME[j]}}"
    say "  ${DIM}Setze BT-Profil system-weit → ${PROF_NAME[j]} (${codec})…${NC}"
    if ! pactl set-card-profile "${CARD_NAME[c]}" "${PROF_NAME[j]}" 2>/dev/null; then
        say "  ${RED}${I_FAIL}${NC} Profilwechsel fehlgeschlagen"
        return 1
    fi
    CHANGES+=("Bluetooth-Profil → Headset · ${codec}")

    # Warten, bis das Headset-Mikrofon erscheint (statt fester Pause)
    REPLY=""
    if [[ -n "${CARD_ADDR[c]}" ]]; then
        for (( t = 0; t < 30; t++ )); do
            bt_node_name sources "${CARD_ADDR[c]}"
            [[ -n "$REPLY" ]] && break
            sleep 0.2
        done
    fi
    if [[ -z "$REPLY" ]]; then
        say "  ${YELLOW}${I_WARN}${NC} Profil gewechselt, aber das Headset-Mikrofon ist noch nicht erschienen."
        return 0
    fi
    pactl set-default-source "$REPLY" 2>/dev/null && CHANGES+=("Mikrofon → ${CARD_DESC[c]}")
    bt_node_name sinks "${CARD_ADDR[c]}"
    [[ -n "$REPLY" ]] && pactl set-default-sink "$REPLY" 2>/dev/null
    return 0
}

# ━━━ SMART ROUTING ━━━
# Setzt REDETECT=1, wenn etwas umgeschaltet wurde (dann neu erkennen).
smart_routing() {
    local cur_type="none" cur_key="" i c j tn tl best_kind="" best_ref=-1 best_rank
    if (( CUR_SRC >= 0 )); then
        cur_type="${SRC_TYPE[CUR_SRC]}"; cur_key="${SRC_KEY[CUR_SRC]}"
    fi
    if [[ "$cur_type" == virtual ]]; then
        say "  ${DIM}${I_INFO} Virtuelle Quelle aktiv (z.B. Rauschfilter/EasyEffects) – keine automatische Umschaltung.${NC}"
        say ""
        return 0
    fi
    src_rank "$cur_type"; best_rank=$REPLY

    # --- 1) Besseres Mikrofon verfügbar? (USB > BT > Webcam > Intern) ---
    for i in "${!SRC_NAME[@]}"; do
        [[ "${SRC_KEY[i]}" == "$cur_key" ]] && continue
        is_skipped "${SRC_KEY[i]}" && continue
        src_rank "${SRC_TYPE[i]}"
        (( REPLY > best_rank )) || continue
        best_kind="src"; best_ref=$i; best_rank=$REPLY
    done
    # Bluetooth-Headset im Musik-Modus (A2DP): Mikrofon erst nach Profilwechsel
    for c in "${!CARD_NAME[@]}"; do
        [[ "${CARD_KEY[c]}" == bt:* && -n "${CARD_BEST_MIC[c]}" ]] || continue
        [[ "${CARD_KEY[c]}" == "$cur_key" ]] && continue
        is_skipped "${CARD_KEY[c]}" && continue
        source_for_key "${CARD_KEY[c]}"
        (( REPLY >= 0 )) && continue
        (( 3 > best_rank )) || continue
        best_kind="card"; best_ref=$c; best_rank=3
    done

    if [[ "$best_kind" == src ]]; then
        type_name "${SRC_TYPE[best_ref]}"; tn="$REPLY"
        type_name "$cur_type"
        say "  ${GREEN}${I_DOT}${NC} ${tn} erkannt: ${BOLD}${SRC_DESC[best_ref]}${NC}"
        say "    ${DIM}Aktuell: ${REPLY}${NC}"
        if ask_yn "Auf ${tn} umschalten (Mic + Ausgabe)?"; then
            say ""
            switch_to_source "$best_ref" && { REDETECT=1; return 0; }
        else
            DECLINED[${SRC_KEY[best_ref]}]=1
        fi
        say ""
    elif [[ "$best_kind" == card ]]; then
        j="${CARD_BEST_MIC[best_ref]}"
        local codec="${PROF_CODEC[j]:-HFP}"
        if (( CUR_SINK >= 0 )) && [[ "${SINK_KEY[CUR_SINK]}" == "${CARD_KEY[best_ref]}" ]]; then
            # Headset läuft gerade als Ausgabe im Musik-Modus → automatisch mit Countdown
            say "  ${YELLOW}${I_WARN}${NC} ${BOLD}${CARD_DESC[best_ref]}${NC} ist im Musik-Modus (A2DP${BT_CODEC:+, $BT_CODEC}) – kein Mikrofon aktiv."
            if countdown "Wechsle auf Headset · ${codec}" 3; then
                switch_bt_profile "$best_ref" "$j" && { REDETECT=1; return 0; }
            else
                DECLINED[${CARD_KEY[best_ref]}]=1
            fi
        else
            say "  ${CYAN}${I_DOT}${NC} Bluetooth-Headset erkannt: ${BOLD}${CARD_DESC[best_ref]}${NC} ${DIM}(Musik-Modus)${NC}"
            if ask_yn "Auf Bluetooth-Headset umschalten (Headset · ${codec})?"; then
                say ""
                switch_bt_profile "$best_ref" "$j" && { REDETECT=1; return 0; }
            else
                DECLINED[${CARD_KEY[best_ref]}]=1
            fi
        fi
        say ""
    fi

    # --- 2) Bluetooth-Mikrofon: besseren Headset-Codec wählen (z.B. CVSD → mSBC) ---
    if [[ "$cur_type" == bluetooth ]] && (( BT_CARD >= 0 )) && [[ -z "${DECLINED[codec:$cur_key]:-}" ]]; then
        j="${CARD_BEST_MIC[BT_CARD]}"
        if [[ -n "$j" && "${PROF_NAME[j]}" != "${CARD_ACTIVE[BT_CARD]}" ]]; then
            local act_rank target="${PROF_CODEC[j]:-${PROF_NAME[j]}}"
            mic_rank "$BT_CODEC"; act_rank=$REPLY
            mic_rank "${PROF_CODEC[j]}"
            if (( REPLY > act_rank )); then
                if [[ "$BT_CODEC" == CVSD ]]; then
                    say "  ${YELLOW}${I_WARN}${NC} CVSD hat niedrige Qualität (8 kHz). ${target} ist verfügbar."
                else
                    say "  ${YELLOW}${I_WARN}${NC} Headset-Profil nicht optimal (${BT_CODEC:-?}). ${target} ist verfügbar."
                fi
                if countdown "Wechsle zu Headset · ${target}" 3; then
                    switch_bt_profile "$BT_CARD" "$j" && { REDETECT=1; return 0; }
                else
                    DECLINED[codec:$cur_key]=1
                fi
                say ""
            fi
        fi
    fi

    # --- 3) Ausgabe passend zum Headset, wenn sie auf Lautsprecher/HDMI läuft ---
    if [[ "$cur_type" == usb || "$cur_type" == bluetooth ]]; then
        local st="none"
        (( CUR_SINK >= 0 )) && st="${SINK_TYPE[CUR_SINK]}"
        if [[ "$st" == internal || "$st" == hdmi || "$st" == none ]]; then
            sink_for_key "$cur_key"; j=$REPLY
            if (( j >= 0 )); then
                type_label "$cur_type"; tl="$REPLY"
                type_label "$st"
                say "  ${YELLOW}${I_WARN}${NC}  Mikrofon ist ${tl}, aber Ausgabe ist ${REPLY}"
                say "  ${DIM}Korrigiere Ausgabe → ${SINK_DESC[j]}${NC}"
                if pactl set-default-sink "${SINK_NAME[j]}" 2>/dev/null; then
                    CHANGES+=("Ausgabe → ${SINK_DESC[j]} (passend zum Mikrofon)")
                    REDETECT=1
                    return 0
                fi
            fi
        fi
    fi
    return 0
}

# Bestes anderes Mikrofon (für "kein Signal") → REPLY_KIND / REPLY_REF
best_alternative() {
    local i c cur_key="" best_rank=0
    REPLY_KIND=""; REPLY_REF=-1
    (( CUR_SRC >= 0 )) && cur_key="${SRC_KEY[CUR_SRC]}"
    for i in "${!SRC_NAME[@]}"; do
        [[ "${SRC_KEY[i]}" == "$cur_key" || "${SRC_TYPE[i]}" == virtual ]] && continue
        [[ -n "${NOSIG_TRIED[${SRC_KEY[i]}]:-}" ]] && continue
        src_rank "${SRC_TYPE[i]}"
        (( REPLY > best_rank )) || continue
        REPLY_KIND="src"; REPLY_REF=$i; best_rank=$REPLY
    done
    for c in "${!CARD_NAME[@]}"; do
        [[ "${CARD_KEY[c]}" == bt:* && -n "${CARD_BEST_MIC[c]}" ]] || continue
        [[ "${CARD_KEY[c]}" == "$cur_key" || -n "${NOSIG_TRIED[${CARD_KEY[c]}]:-}" ]] && continue
        source_for_key "${CARD_KEY[c]}"
        (( REPLY >= 0 )) && continue
        (( 3 > best_rank )) || continue
        REPLY_KIND="card"; REPLY_REF=$c; best_rank=3
    done
}

# ━━━ STUMM / LAUTSTÄRKE ━━━
check_mic_state() {   # 0 = weiter, 1 = Mikrofon bleibt stumm
    if [[ "${SRC_MUTE[CUR_SRC]}" == yes ]]; then
        say "  ${RED}${BOLD}${I_FAIL} Mikrofon ist stumm!${NC}"
        if ask_yn "Jetzt einschalten?"; then
            if pactl set-source-mute @DEFAULT_SOURCE@ 0 2>/dev/null; then
                SRC_MUTE[CUR_SRC]="no"
                say "  ${GREEN}${I_OK}${NC} Mikrofon eingeschaltet"
                say ""
            else
                add_issue fail mic "Mikrofon ist stumm (Einschalten fehlgeschlagen)" "pactl set-source-mute @DEFAULT_SOURCE@ 0"
                return 1
            fi
        else
            add_issue fail mic "Mikrofon ist stumm" "pactl set-source-mute @DEFAULT_SOURCE@ 0"
            return 1
        fi
    fi
    if (( ${SRC_VOL[CUR_SRC]:-0} < 10 )); then
        say "  ${YELLOW}${I_WARN}${NC} Mikrofon-Lautstärke ist nur ${SRC_VOL[CUR_SRC]}%."
        if ask_yn "Auf 100% setzen?" && pactl set-source-volume @DEFAULT_SOURCE@ 100% 2>/dev/null; then
            SRC_VOL[CUR_SRC]=100
            say "  ${GREEN}${I_OK}${NC} Mikrofon-Lautstärke auf 100%"
        fi
        say ""
    fi
    return 0
}

# ━━━ PEGELANZEIGE ━━━
build_meter() {   # $1 = Zeichen, $2 = Peak-Hold-Zeichen (-1 = keins), $3 = Farbe → METER
    local lvl=$1 hold=$2 i s="$3" zone=0
    for (( i = 0; i < lvl; i++ )); do s+="$BAR_FULL"; done
    s+="$NC"
    for (( i = lvl; i < BAR_W; i++ )); do
        if (( i >= ZONE_START && i <= ZONE_END )); then
            (( zone )) || { s+="$DIM"; zone=1; }
        elif (( zone )); then
            s+="$NC"; zone=0
        fi
        if (( i == hold )); then
            s+="${NC}${BOLD}${BAR_PEAK}${NC}"
            (( zone )) && s+="$DIM"
        elif (( zone )); then
            s+="$BAR_ZONE"
        else
            s+="$BAR_EMPTY"
        fi
    done
    s+="$NC"
    METER="[${s}]"
}

level_color() {   # $1 = Zeichen → REPLY (gelb = zu leise, grün = Zielzone, rot = zu laut)
    if (( $1 < ZONE_START )); then REPLY="$YELLOW"
    elif (( $1 > ZONE_END )); then REPLY="$RED"
    else REPLY="$GREEN"; fi
}

fmt_db() { if [[ "$1" == "-99.0" ]]; then REPLY="-inf"; else REPLY="$1"; fi; }

meter_line() {   # $1 = Label, $2 = Zeichen, $3 = Hold, $4 = dB, $5 = Status, $6 = live
    # Live-Aktualisierungen nur im Terminal (nicht in Pipes/Logs)
    [[ "${6:-}" == live ]] && (( !IS_TTY )) && return 0
    level_color "$2"
    build_meter "$2" "$3" "$REPLY"
    fmt_db "$4"
    printf '\r  %s %s %6s dB  %s%s' "$1" "$METER" "$REPLY" "$5" "$EL"
}

# ━━━ AUFNAHME ━━━
CHUNK_AWK='
{ for (i = 1; i <= NF; i++) { v = $i + 0; if (v < 0) v = -v; if (v > m) m = v; s += v * v; n++; if (v >= 32767) c++ } }
END {
    db = (m > 0) ? 20 * log(m / 32768) / log(10) : -99
    l = int((db - F) / (-F) * W); if (l < 0) l = 0; if (l > W) l = W
    printf "%d %.0f %d %d %.1f %d\n", m, s, n, c, db, l
}'

read_chunk() {   # liest genau einen Block vom Aufnahme-Stream (fd 3)
    # iflag=fullblock: ohne liefert dd aus einer Pipe oft nur Teilblöcke.
    # timeout: hängt das Gerät, kommt nach 5 s ein Fehler statt Stillstand.
    "${TIMEOUT_CMD[@]}" dd bs="$CHUNK_BYTES" count=1 iflag=fullblock of="$CHUNK" <&3 2>/dev/null
    [[ -s "$CHUNK" ]] || return 1
    read -r CH_PEAK CH_SUMSQ CH_N CH_CLIP CH_DB CH_LVL < <(
        od -An -td2 -v "$CHUNK" | awk -v W="$BAR_W" -v F="$DB_FLOOR" "$CHUNK_AWK")
    (( CH_N > 0 ))
}

stop_rec() {
    [[ -n "${REC_PID:-}" ]] && kill "$REC_PID" 2>/dev/null
    exec 3<&-
    [[ -n "${REC_PID:-}" ]] && wait "$REC_PID" 2>/dev/null
    REC_PID=""
}

rec_failed() {
    stop_rec
    local err
    err=$(grep -v '^[[:space:]]*$' "$REC_ERR" 2>/dev/null | head -2 | tr '\n' ' ')
    err="${err% }"
    printf '\n'
    add_issue fail mic "Aufnahme fehlgeschlagen${err:+: ${err}}" "Gerät belegt oder getrennt? ./mic-check.sh --debug"
}

ms_to_db() {   # Summe der Quadrate, Anzahl → RMS in dBFS (REPLY)
    REPLY=$(awk -v s="$1" -v n="$2" \
        'BEGIN { if (n <= 0 || s <= 0) print "-99.0"; else printf "%.1f", 10 * log(s / n / 1073741824) / log(10) }')
}

push_chunk() {   # aktuellen Block an die Aufnahme-Arrays anhängen
    REC_PEAK+=("$CH_PEAK"); REC_SUMSQ+=("$CH_SUMSQ"); REC_N+=("$CH_N")
    REC_CLIP+=("$CH_CLIP"); REC_LVL+=("$CH_LVL"); REC_DBS+=("$CH_DB")
}

# Ein einziger rec-Stream für Rauschboden, Warten und Sprachaufnahme:
# kein Neustart des Geräts zwischen den Phasen, die erste Silbe bleibt erhalten.
measure() {
    local cps=$CHUNKS_PER_SEC i k
    local skip=$(( cps * 3 / 10 )) noise_n=$(( NOISE_SECS * cps ))
    local wait_n=$(( WAIT_SECS * cps )) rec_n=$(( CHECK_SECS * cps ))
    local total=$(( NOISE_SECS + WAIT_SECS + CHECK_SECS + 2 ))
    REC_PEAK=(); REC_SUMSQ=(); REC_N=(); REC_CLIP=(); REC_LVL=(); REC_DBS=()
    local -a w_peak=() w_sumsq=() w_n=() w_clip=() w_lvl=() w_db=()
    NOISE_SUMSQ=0; NOISE_N=0; NOISE_PEAK=0
    : > "$FILE"; : > "$WAIT_FILE"
    rm -f "$REC_FIFO"
    if ! mkfifo "$REC_FIFO"; then
        add_issue fail mic "Interner Fehler (mkfifo)" ""
        return 1
    fi

    # --- Rauschboden ---
    printf '  %s Rauschboden %s(bitte 1 s still sein…)%s: ' "$I_HUSH" "$DIM" "$NC"
    rec -q -c "$CHANNELS" -r "$RATE" -b "$BITS" -e signed-integer -t raw - \
        trim 0 "$total" 2>"$REC_ERR" >"$REC_FIFO" &
    REC_PID=$!
    exec 3<"$REC_FIFO"

    # Die ersten 0.3 s verwerfen (Einschalt-Knacken, v.a. bei Bluetooth)
    for (( i = 0; i < skip; i++ )); do read_chunk || { rec_failed; return 1; }; done
    for (( i = 0; i < noise_n; i++ )); do
        read_chunk || { rec_failed; return 1; }
        (( NOISE_SUMSQ += CH_SUMSQ, NOISE_N += CH_N ))
        (( CH_PEAK > NOISE_PEAK )) && NOISE_PEAK=$CH_PEAK
    done
    ms_to_db "$NOISE_SUMSQ" "$NOISE_N"; NOISE_DB="$REPLY"
    if [[ "$NOISE_DB" == "-99.0" ]]; then
        say "${GREEN}kein Rauschen${NC} ${DIM}(digitale Stille)${NC}"
    elif flt "$NOISE_DB" "$NOISE_GOOD"; then
        say "${GREEN}${NOISE_DB} dB${NC} ${DIM}(sehr gut)${NC}"
    elif flt "$NOISE_DB" "$NOISE_OK"; then
        say "${YELLOW}${NOISE_DB} dB${NC} ${DIM}(akzeptabel)${NC}"
    else
        say "${RED}${NOISE_DB} dB${NC} ${DIM}(hoch)${NC}"
    fi

    # --- Warten auf Sprache (Schwelle relativ zum Rauschboden, ~+10 dB) ---
    local thr=$(( NOISE_PEAK * 3 ))
    (( thr < 400 )) && thr=400
    (( thr > 8000 )) && thr=8000
    # shellcheck disable=SC1111  # deutsche Anführungszeichen
    say "  ${I_SAY} Sprich jetzt, z.B.: ${BOLD}„${READ_PROMPT}“${NC}"
    local triggered=0
    for (( i = 0; i < wait_n; i++ )); do
        read_chunk || { rec_failed; return 1; }
        cat "$CHUNK" >> "$WAIT_FILE"
        w_peak+=("$CH_PEAK"); w_sumsq+=("$CH_SUMSQ"); w_n+=("$CH_N")
        w_clip+=("$CH_CLIP"); w_lvl+=("$CH_LVL"); w_db+=("$CH_DB")
        meter_line "${I_MIC} INPUT " "$CH_LVL" -1 "$CH_DB" \
            "${DIM}warte auf Sprache… $(( (wait_n - i + cps - 1) / cps ))s${NC}" live
        if (( CH_PEAK > thr )); then triggered=1; break; fi
    done

    # Vorlauf (Block vor dem Auslöser + Auslöser) bzw. bei Timeout die letzten
    # CHECK_SECS der Wartezeit als Aufnahme verwenden (z.B. sehr leises Mikro)
    local n_w=${#w_peak[@]} start
    if (( triggered )); then
        start=$(( n_w >= 2 ? n_w - 2 : 0 ))
    else
        start=$(( n_w > rec_n ? n_w - rec_n : 0 ))
    fi
    for (( k = start; k < n_w; k++ )); do
        REC_PEAK+=("${w_peak[k]}"); REC_SUMSQ+=("${w_sumsq[k]}"); REC_N+=("${w_n[k]}")
        REC_CLIP+=("${w_clip[k]}"); REC_LVL+=("${w_lvl[k]}"); REC_DBS+=("${w_db[k]}")
    done
    tail -c $(( (n_w - start) * CHUNK_BYTES )) "$WAIT_FILE" > "$FILE"

    # --- Sprachaufnahme ---
    if (( triggered )); then
        local hold=0
        for k in "${REC_LVL[@]}"; do (( k > hold )) && hold=$k; done
        while (( ${#REC_PEAK[@]} < rec_n )); do
            read_chunk || break
            cat "$CHUNK" >> "$FILE"
            push_chunk
            (( CH_LVL > hold )) && hold=$CH_LVL
            meter_line "${I_MIC} INPUT " "$CH_LVL" "$hold" "$CH_DB" \
                "${RED}${I_REC}${NC} $(( (rec_n - ${#REC_PEAK[@]} + cps - 1) / cps ))s" live
        done
    fi
    stop_rec
    return 0
}

# ━━━ AUSWERTUNG ━━━
analyze() {
    local k maxp=0 clips=0 as=0 an=0 ts=0 tn=0 ms noise_ms=0
    (( NOISE_N > 0 )) && noise_ms=$(( NOISE_SUMSQ / NOISE_N ))
    for k in "${!REC_PEAK[@]}"; do
        (( REC_PEAK[k] > maxp )) && maxp=${REC_PEAK[k]}
        (( clips += REC_CLIP[k], ts += REC_SUMSQ[k], tn += REC_N[k] ))
        (( REC_N[k] > 0 )) || continue
        ms=$(( REC_SUMSQ[k] / REC_N[k] ))
        # Sprach-Blöcke: > Rauschboden + 6 dB und > -50 dBFS RMS
        if (( ms > 4 * noise_ms && ms > 10737 )); then
            (( as += REC_SUMSQ[k], an += REC_N[k] ))
        fi
    done
    (( an == 0 )) && { as=$ts; an=$tn; }
    MAX_PEAK=$maxp
    CLIP_COUNT=$clips
    # SNR = Sprach-RMS minus Rausch-RMS (robuster als Peak/Peak)
    read -r PEAK_DB _ SNR_DB < <(awk -v p="$maxp" -v s="$as" -v n="$an" -v nd="$NOISE_DB" 'BEGIN {
        pk = (p > 0) ? 20 * log(p / 32768) / log(10) : -99
        sp = (n > 0 && s > 0) ? 10 * log(s / n / 1073741824) / log(10) : -99
        snr = sp - nd; if (snr > 99) snr = 99
        printf "%.1f %.1f %.1f\n", pk, sp, snr }')
    db_cells "$PEAK_DB"; PEAK_LVL=$REPLY
}

suggest_gain() {   # GAIN_NEW_PCT für die Zielzone (Lautstärke-% ist kubisch skaliert)
    GAIN_NEW_PCT=""
    local cur="${SRC_VOL[CUR_SRC]:-100}" delta new
    if [[ "$LEVEL_STATE" == clip ]]; then
        delta=$(( LVL_TARGET - 3 ))   # wahrer Peak unbekannt (≥ 0 dB)
    else
        delta=$(awk -v t="$LVL_TARGET" -v p="$PEAK_DB" 'BEGIN { printf "%.1f", t - p }')
    fi
    new=$(awk -v c="$cur" -v d="$delta" -v mx="$MAX_GAIN_PCT" \
        'BEGIN { n = c * 10 ^ (d / 60); if (n > mx) n = mx; if (n < 5) n = 5; printf "%d", n + 0.5 }')
    (( new != cur )) && GAIN_NEW_PCT=$new
}

evaluate_level() {
    HAVE_SIGNAL=0; LEVEL_STATE=""
    local mark hint
    if flt "$PEAK_DB" "$LVL_NO_SIGNAL"; then
        LEVEL_STATE="none"
        SNR_DB=""
        meter_line "${I_MIC} INPUT " "$PEAK_LVL" -1 "$PEAK_DB" "${RED}${I_FAIL} kein Signal${NC}"
        printf '\n'
        fmt_db "$PEAK_DB"
        add_issue fail mic "Kein Signal – das Mikrofon empfängt nichts (Peak ${REPLY} dB)" \
            "Kabel · Mute-Taste am Headset · anderes Gerät → [d]"
        return
    fi
    HAVE_SIGNAL=1
    if (( CLIP_COUNT >= 3 )) || ! flt "$PEAK_DB" "$LVL_CLIP"; then
        LEVEL_STATE="clip"; mark="${YELLOW}${I_WARN} übersteuert${NC}"
    elif flt "$PEAK_DB" "$LVL_QUIET"; then
        LEVEL_STATE="quiet"; mark="${YELLOW}${I_WARN} zu leise${NC}"
    else
        LEVEL_STATE="ok"; mark="${GREEN}${I_OK}${NC}"
    fi
    meter_line "${I_MIC} INPUT " "$PEAK_LVL" -1 "$PEAK_DB" "$mark"
    printf '\n'

    [[ "$LEVEL_STATE" == clip || "$LEVEL_STATE" == quiet ]] || return
    suggest_gain
    if [[ -n "$GAIN_NEW_PCT" ]]; then
        hint="Mic-Gain ${SRC_VOL[CUR_SRC]}% → ${GAIN_NEW_PCT}% → [g]"
    elif [[ "$LEVEL_STATE" == quiet ]]; then
        hint="Mic-Gain ist am Maximum – Mikrofon näher an den Mund"
    else
        hint="Mikrofon weiter weg oder leiser sprechen"
    fi
    if [[ "$LEVEL_STATE" == clip ]]; then
        add_issue warn level "Übersteuert (Peak ${PEAK_DB} dB, ${CLIP_COUNT} Samples geclippt)" "$hint"
    else
        add_issue warn level "Sehr leise (Peak ${PEAK_DB} dB)" "$hint"
    fi
}

evaluate_quality() {
    SNR_RATING=""
    if flt "$SNR_DB" "$SNR_OK"; then
        SNR_RATING="schlecht"
        add_issue warn noise "Hintergrundgeräusche zu laut (SNR ${SNR_DB} dB)" \
            "ruhigerer Ort · Mikro näher · Rauschfilter (z.B. EasyEffects/NoiseTorch)"
    elif flt "$SNR_DB" "$SNR_GOOD"; then
        SNR_RATING="akzeptabel"
    elif flt "$SNR_DB" "$SNR_EXCELLENT"; then
        SNR_RATING="gut"
    else
        SNR_RATING="exzellent"
    fi
}

check_bandwidth() {   # Energie über 4.5 kHz relativ zu 1–4 kHz (CVSD schneidet bei 4 kHz ab)
    BW_STATE=""
    (( RATE >= 16000 )) || return 0
    local -a fmt=(-t raw -r "$RATE" -c "$CHANNELS" -b "$BITS" -e signed-integer)
    local mid hi hint
    mid=$(sox "${fmt[@]}" "$FILE" -n sinc 1000-4000 stats 2>&1 | awk '/^RMS lev dB/ { print $4 }')
    hi=$(sox "${fmt[@]}" "$FILE" -n sinc 4500-7500 stats 2>&1 | awk '/^RMS lev dB/ { print $4 }')
    [[ "$mid" =~ ^-?[0-9.]+$ ]] || return 0
    [[ "$hi" =~ ^-?[0-9.]+$ ]] || hi=-200
    BW_DIFF=$(awk -v h="$hi" -v m="$mid" 'BEGIN { printf "%.0f", h - m }')
    if ! flt "$BW_DIFF" "$BW_MIN_DB"; then
        BW_STATE="wide"
        return 0
    fi
    BW_STATE="narrow"
    hint="Zischlaute (s, sch) sprechen oder Mikrofon prüfen"
    if (( CUR_SRC >= 0 )) && [[ "${SRC_TYPE[CUR_SRC]}" == bluetooth ]]; then
        if [[ "$BT_CODEC" == CVSD ]]; then
            hint="CVSD-Codec begrenzt auf 4 kHz – Headset-Profil mit mSBC wählen"
        else
            hint="Bluetooth-Codec/Profil prüfen"
        fi
    fi
    add_issue warn bw "Schmalband (≤4 kHz) – klingt dumpf wie am Telefon" "$hint"
}

# ━━━ WIEDERGABE ━━━
play_with_meter() {   # $1 = Status während der Wiedergabe → 0 = ok
    local k n=${#REC_LVL[@]} t
    sox -q -t raw -r "$RATE" -c "$CHANNELS" -b "$BITS" -e signed-integer "$FILE" -d 2>"$PLAY_ERR" &
    PLAY_PID=$!
    # Anzeige im Takt der Wiedergabe aus den gespeicherten Aufnahme-Blöcken
    for (( k = 0; k < n; k++ )); do
        meter_line "${I_OUT} OUTPUT" "${REC_LVL[k]}" -1 "${REC_DBS[k]}" "$1" live
        kill -0 "$PLAY_PID" 2>/dev/null || break
        sleep "$CHUNK_SECS"
    done
    # Hängt die Ausgabe, nicht ewig warten
    for (( t = 0; t < 30; t++ )); do
        kill -0 "$PLAY_PID" 2>/dev/null || break
        sleep 0.1
    done
    kill -0 "$PLAY_PID" 2>/dev/null && { kill "$PLAY_PID" 2>/dev/null; echo "Zeitüberschreitung" >> "$PLAY_ERR"; }
    wait "$PLAY_PID"
    k=$?
    PLAY_PID=""
    return $k
}

playback() {
    (( NO_PLAYBACK )) && return 0
    (( HAVE_SIGNAL )) && [[ -s "$FILE" ]] || return 0
    if (( CUR_SINK < 0 )); then
        add_issue fail out "Kein Ausgabegerät gefunden" "Kopfhörer/Headset verbinden"
        return 0
    fi
    if [[ "${SINK_MUTE[CUR_SINK]}" == yes ]]; then
        say "  ${RED}${I_FAIL}${NC} Ausgabe ist stumm – du würdest niemanden hören."
        if ask_yn "Jetzt einschalten?" && pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null; then
            SINK_MUTE[CUR_SINK]="no"
        else
            add_issue fail out "Ausgabe ist stumm" "pactl set-sink-mute @DEFAULT_SINK@ 0"
            return 0
        fi
    fi
    if (( ${SINK_VOL[CUR_SINK]:-0} < 10 )); then
        say "  ${YELLOW}${I_WARN}${NC} Ausgabe-Lautstärke ist nur ${SINK_VOL[CUR_SINK]}%."
        if ask_yn "Auf 50% setzen?" && pactl set-sink-volume @DEFAULT_SINK@ 50% 2>/dev/null; then
            SINK_VOL[CUR_SINK]=50
        fi
    fi

    if ! play_with_meter "${DIM}Wiedergabe…${NC}"; then
        local err
        err=$(grep -v '^[[:space:]]*$' "$PLAY_ERR" 2>/dev/null | head -1)
        meter_line "${I_OUT} OUTPUT" 0 -1 "-99.0" "${RED}${I_FAIL} Wiedergabe fehlgeschlagen${NC}"
        printf '\n'
        add_issue fail out "Wiedergabe fehlgeschlagen${err:+: $err}" "Ausgabegerät prüfen → [d]"
        return 0
    fi

    if (( INTERACTIVE )); then
        local key
        meter_line "${I_OUT} OUTPUT" "$PEAK_LVL" -1 "$PEAK_DB" "${BOLD}Gehört? [J/n]${NC} "
        cur_show
        read -rsn1 key
        drain_keys
        cur_hide
        if [[ "$key" == [nN] ]]; then
            meter_line "${I_OUT} OUTPUT" "$PEAK_LVL" -1 "$PEAK_DB" "${RED}${I_FAIL} nicht gehört${NC}"
            add_issue fail out "Wiedergabe nicht gehört" "Ausgabegerät/Lautstärke prüfen → [d] Gerät wählen"
        else
            meter_line "${I_OUT} OUTPUT" "$PEAK_LVL" -1 "$PEAK_DB" "${GREEN}${I_OK} gehört${NC}"
        fi
    else
        meter_line "${I_OUT} OUTPUT" "$PEAK_LVL" -1 "$PEAK_DB" "${DIM}abgespielt${NC}"
    fi
    printf '\n'
}

replay_recording() {
    if play_with_meter "${DIM}Wiedergabe…${NC}"; then
        meter_line "${I_OUT} OUTPUT" "$PEAK_LVL" -1 "$PEAK_DB" "${DIM}abgespielt${NC}"
    else
        meter_line "${I_OUT} OUTPUT" 0 -1 "-99.0" "${RED}${I_FAIL} Wiedergabe fehlgeschlagen${NC}"
    fi
    printf '\n'
}

# ━━━ WEITERE PRÜFUNGEN ━━━
check_apps() {   # Nehmen laufende Apps vom getesteten Mikrofon auf?
    APPS_OK=(); APPS_BAD=(); APPS_BAD_IDX=()
    (( CUR_SRC >= 0 )) || return 0
    local -A sname=() sdesc=() seen=()
    local idx name rest i so src app bin media label s x
    while IFS=$'\t' read -r idx name rest; do
        [[ -n "$idx" ]] && sname[$idx]="$name"
    done < <(pactl list sources short 2>/dev/null)
    for i in "${!SRC_NAME[@]}"; do sdesc[${SRC_NAME[i]}]="${SRC_DESC[i]}"; done

    while IFS='|' read -r so src app bin media; do
        s="${sname[$src]:-}"
        [[ -z "$s" || "$s" == *.monitor ]] && continue
        label="${app:-$bin}"; label="${label:-Stream #$so}"
        case "${label,,} ${media,,}" in
            *pavucontrol*|*"volume control"*|*peak*) continue ;;
        esac
        if [[ "$s" == "$DEFAULT_SOURCE" ]]; then
            [[ -n "${seen[$label]:-}" ]] || APPS_OK+=("$label")
            seen[$label]=1
        else
            name="${sdesc[$s]:-$s}"
            APPS_BAD+=("${label}|${name:0:40}")
            APPS_BAD_IDX+=("$so")
        fi
    done < <(pactl list source-outputs 2>/dev/null | awk "$PA_SO_AWK")

    for x in "${APPS_BAD[@]}"; do
        # shellcheck disable=SC1111  # deutsche Anführungszeichen
        add_issue warn app "${x%%|*} nimmt von „${x#*|}“ auf – nicht vom getesteten Mikrofon" \
            "→ [a] auf getestetes Mikrofon umleiten"
    done
}

move_apps() {
    local so ok=0
    for so in "${APPS_BAD_IDX[@]}"; do
        pactl move-source-output "$so" "$DEFAULT_SOURCE" 2>/dev/null && (( ++ok ))
    done
    say "  ${GREEN}${I_OK}${NC} ${ok} von ${#APPS_BAD_IDX[@]} App-Stream(s) auf ${BOLD}${MIC_DESC}${NC} umgeleitet"
    APPS_BAD_IDX=()
}

check_echo() {   # internes Mikro + Lautsprecher → Echo-Gefahr
    (( CUR_SRC >= 0 && CUR_SINK >= 0 )) || return 0
    [[ "${SRC_TYPE[CUR_SRC]}" == internal && "${SINK_TYPE[CUR_SINK]}" == internal ]] || return 0
    local port="${SINK_PORT[CUR_SINK],,}"
    [[ "$port" == *headphone* || "$port" == *headset* ]] && return 0
    add_issue info echo "Lautsprecher + internes Mikrofon: Echo möglich" "Kopfhörer oder Headset verwenden"
}

check_battery() {
    if [[ -n "$BT_BATTERY" ]] && (( BT_BATTERY < BATTERY_WARN )); then
        add_issue warn bat "Headset-Akku nur noch ${BT_BATTERY}%" "vor dem Anruf laden"
    fi
    return 0
}

# ━━━ ERGEBNIS ━━━
add_issue() {   # $1 = fail|warn|info, $2 = Kategorie, $3 = Text, $4 = Hinweis
    ISSUES+=("${1}|${2}|${3//|//}|${4//|//}")
}

compute_verdict() {
    local x sev
    VERDICT="OK"
    for x in "${ISSUES[@]}"; do
        sev="${x%%|*}"
        if [[ "$sev" == fail ]]; then VERDICT="FAIL"; return; fi
        [[ "$sev" == warn ]] && VERDICT="WARN"
    done
}

print_report() {
    local line sev kind text hint x col printed=0
    say ""
    if (( HAVE_SIGNAL )); then
        printed=1
        line="  "
        case "$LEVEL_STATE" in
            ok)    line+="${GREEN}${I_OK} Pegel OK${NC}" ;;
            quiet) line+="${YELLOW}${I_WARN} Sehr leise${NC}" ;;
            clip)  line+="${YELLOW}${I_WARN} Übersteuert${NC}" ;;
        esac
        col="$GREEN"
        flt "$SNR_DB" "$SNR_GOOD" && col="$YELLOW"
        flt "$SNR_DB" "$SNR_OK" && col="$RED"
        line+=" ${SEP} SNR: ${col}${SNR_DB}dB${NC} ${DIM}(${SNR_RATING})${NC}"
        fmt_db "$NOISE_DB"
        line+=" ${SEP} Rauschen: ${REPLY}dB"
        case "$BW_STATE" in
            wide)   line+=" ${SEP} Freq: ${GREEN}>4kHz ${I_OK}${NC}" ;;
            narrow) line+=" ${SEP} Freq: ${YELLOW}≤4kHz${NC}" ;;
        esac
        say "$line"
    fi
    if (( ${#APPS_OK[@]} + ${#APPS_BAD[@]} )); then
        line="  Apps am Mikrofon:"
        for x in "${APPS_OK[@]}"; do line+=" ${GREEN}${x} ${I_OK}${NC}"; done
        for x in "${APPS_BAD[@]}"; do line+=" ${YELLOW}${x%%|*} ${I_WARN}${NC}"; done
        say "$line"
        printed=1
    elif (( HAVE_SIGNAL )); then
        local again="nach dem Beitreten erneut prüfen"
        (( INTERACTIVE && !NO_MENU )) && again+=": [r]"
        say "  ${DIM}Apps am Mikrofon: noch keine (${again})${NC}"
    fi

    if (( ${#ISSUES[@]} )); then
        (( printed )) && say ""
        for x in "${ISSUES[@]}"; do
            IFS='|' read -r sev kind text hint <<< "$x"
            case "$sev" in
                fail) line="  ${RED}${I_FAIL}${NC} ${text}" ;;
                warn) line="  ${YELLOW}${I_WARN}${NC} ${text}" ;;
                *)    line="  ${CYAN}${I_INFO}${NC} ${text}" ;;
            esac
            if [[ -n "$hint" ]]; then
                # Kurze Hinweise in dieselbe Zeile, lange darunter
                if (( ${#text} + ${#hint} <= 74 )); then
                    line+="  ${DIM}${hint}${NC}"
                else
                    line+=$'\n'"      ${DIM}${hint}${NC}"
                fi
            fi
            say "$line"
        done
    fi

    say ""
    local logp="${LOG_FILE/#$HOME/\~}"
    case "$VERDICT" in
        OK)
            say "  ══ ${BG_GREEN}${BOLD} ${I_READY} BEREIT FÜR DEN ANRUF ${NC} ${DIM}(log:${logp})${NC} ══" ;;
        WARN)
            local only_level=1
            for x in "${ISSUES[@]}"; do
                IFS='|' read -r sev kind text hint <<< "$x"
                [[ "$sev" == warn && "$kind" != level ]] && only_level=0
            done
            if (( only_level )); then
                say "  ══ ${BG_YELLOW}${BOLD} ${I_WARNB}PEGEL ANPASSEN ${NC} ${DIM}(log:${logp})${NC} ══"
            else
                say "  ══ ${BG_YELLOW}${BOLD} ${I_WARNB}BEREIT MIT EINSCHRÄNKUNGEN ${NC} ${DIM}(log:${logp})${NC} ══"
            fi ;;
        FAIL)
            local what="MIKROFON"
            for x in "${ISSUES[@]}"; do
                IFS='|' read -r sev kind text hint <<< "$x"
                if [[ "$sev" == fail ]]; then [[ "$kind" == out ]] && what="AUDIO"; break; fi
            done
            say "  ══ ${BG_RED}${BOLD} ${I_NOTREADY} ${what} PROBLEM – NICHT ANRUFEN ${NC} ${DIM}(log:${logp})${NC} ══" ;;
    esac
    say ""
}

log_result() {
    local ts freq reasons="" x sev kind text hint mic_pct=""
    printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1
    case "$BW_STATE" in wide) freq="OK" ;; narrow) freq="WARN" ;; *) freq="n/a" ;; esac
    for x in "${ISSUES[@]}"; do
        IFS='|' read -r sev kind text hint <<< "$x"
        [[ "$sev" == info ]] && continue
        reasons+="${reasons:+; }${text}"
    done
    (( CUR_SRC >= 0 )) && mic_pct="${SRC_VOL[CUR_SRC]}"
    local codec="n/a"
    [[ "$BT_ROLE" == mic && -n "$BT_CODEC" ]] && codec="$BT_CODEC"
    # Felder 1–8 wie bisher (kompatibel mit alten Logs), 9–12 neu
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$ts" "$VERDICT" "${MIC_DESC//|//}" "$codec" "${SNR_DB:-n/a}" "${NOISE_DB:-n/a}" \
        "${MAX_PEAK:-0}" "$freq" "${PEAK_DB:-n/a}" "${OUT_DESC//|//}" "$mic_pct" "${reasons//|//}" \
        >> "$LOG_FILE" 2>/dev/null
}

# ━━━ GERÄTELISTE / AUSWAHL ━━━
print_device_table() {   # $1 = 1 → nummeriert (für die Auswahl)
    local numbered=$1 n=0 i c j mark num tl
    PICK_KIND=(); PICK_REF=()
    say "  ${BOLD}Mikrofone${NC}"
    for i in "${!SRC_NAME[@]}"; do
        (( ++n )); PICK_KIND[n]="src"; PICK_REF[n]=$i
        mark=" "; [[ "${SRC_NAME[i]}" == "$DEFAULT_SOURCE" ]] && mark="${GREEN}*${NC}"
        num="    "; (( numbered )) && printf -v num '%3d)' "$n"
        type_label "${SRC_TYPE[i]}"; tl="$REPLY"
        vol_label "${SRC_VOL[i]}" "${SRC_MUTE[i]}"
        say "  ${num} ${mark} ${DIM}[${NC}${tl}${DIM}]${NC} ${SRC_DESC[i]} ${REPLY}"
    done
    for c in "${!CARD_NAME[@]}"; do
        [[ "${CARD_KEY[c]}" == bt:* && -n "${CARD_BEST_MIC[c]}" ]] || continue
        source_for_key "${CARD_KEY[c]}"
        (( REPLY >= 0 )) && continue
        (( ++n )); PICK_KIND[n]="card"; PICK_REF[n]=$c
        j="${CARD_BEST_MIC[c]}"
        num="    "; (( numbered )) && printf -v num '%3d)' "$n"
        type_label bluetooth
        say "  ${num}   ${DIM}[${NC}${REPLY}${DIM}]${NC} ${CARD_DESC[c]} ${DIM}(Musik-Modus → Headset · ${PROF_CODEC[j]:-HFP})${NC}"
    done
    say "  ${BOLD}Ausgaben${NC}"
    for i in "${!SINK_NAME[@]}"; do
        (( ++n )); PICK_KIND[n]="sink"; PICK_REF[n]=$i
        mark=" "; [[ "${SINK_NAME[i]}" == "$DEFAULT_SINK" ]] && mark="${GREEN}*${NC}"
        num="    "; (( numbered )) && printf -v num '%3d)' "$n"
        type_label "${SINK_TYPE[i]}"; tl="$REPLY"
        vol_label "${SINK_VOL[i]}" "${SINK_MUTE[i]}"
        say "  ${num} ${mark} ${DIM}[${NC}${tl}${DIM}]${NC} ${SINK_DESC[i]} ${REPLY}"
    done
}

pick_device() {   # interaktive Geräteauswahl
    local n key="" suggested=-1 r prompt
    say ""
    print_device_table 1
    say ""
    cur_show
    read -r -p "  Mikrofon-Nr. (Enter = behalten): " n
    if [[ "$n" =~ ^[0-9]+$ && "${PICK_KIND[n]:-}" == src ]]; then
        r="${PICK_REF[n]}"
        pactl set-default-source "${SRC_NAME[r]}" 2>/dev/null && {
            CHANGES+=("Mikrofon → ${SRC_DESC[r]}")
            key="${SRC_KEY[r]}"
        }
    elif [[ "$n" =~ ^[0-9]+$ && "${PICK_KIND[n]:-}" == card ]]; then
        r="${PICK_REF[n]}"
        switch_bt_profile "$r" "${CARD_BEST_MIC[r]}"
    elif [[ -n "$n" ]]; then
        say "  ${YELLOW}Keine gültige Mikrofon-Nummer – behalte das aktuelle.${NC}"
    fi

    # Passende Ausgabe zum neu gewählten Mikrofon vorschlagen
    prompt="  Ausgabe-Nr. (Enter = behalten): "
    if [[ -n "$key" ]]; then
        sink_for_key "$key"; suggested=$REPLY
        (( suggested >= 0 )) && prompt="  Ausgabe-Nr. (Enter = ${SINK_DESC[suggested]}): "
    fi
    read -r -p "$prompt" n
    if [[ -z "$n" ]] && (( suggested >= 0 )); then
        pactl set-default-sink "${SINK_NAME[suggested]}" 2>/dev/null && CHANGES+=("Ausgabe → ${SINK_DESC[suggested]}")
    elif [[ "$n" =~ ^[0-9]+$ && "${PICK_KIND[n]:-}" == sink ]]; then
        r="${PICK_REF[n]}"
        pactl set-default-sink "${SINK_NAME[r]}" 2>/dev/null && CHANGES+=("Ausgabe → ${SINK_DESC[r]}")
    elif [[ -n "$n" ]]; then
        say "  ${YELLOW}Keine gültige Ausgabe-Nummer – behalte die aktuelle.${NC}"
    fi
    cur_hide
    # Manuelle Wahl nicht durch automatische Vorschläge überstimmen
    ROUTING_LOCKED=1
}

show_list() {
    detect_all || { say "Fehler: pactl kann den Audio-Server nicht erreichen."; exit 1; }
    say "mic-check v${VERSION} – Geräte-Übersicht ${DIM}(${AUDIO_SRV})${NC}"
    say ""
    print_device_table 0
    local c j line
    for c in "${!CARD_NAME[@]}"; do
        [[ "${CARD_KEY[c]}" == bt:* ]] || continue
        say ""
        say "  ${BOLD}Bluetooth: ${CARD_DESC[c]}${NC} ${DIM}(${CARD_ADDR[c]})${NC}"
        for j in "${!PROF_NAME[@]}"; do
            (( PROF_CARD[j] == c )) || continue
            [[ "${PROF_NAME[j]}" == off ]] && continue
            line="    "
            if [[ "${PROF_NAME[j]}" == "${CARD_ACTIVE[c]}" ]]; then line+="${GREEN}*${NC} "; else line+="  "; fi
            if (( PROF_SOURCES[j] > 0 )); then line+="${I_HEADSET}  "; else line+="${I_MUSIC}  "; fi
            line+="${PROF_NAME[j]}  ${DIM}${PROF_LABEL[j]}${NC}"
            [[ "${PROF_AVAIL[j]}" == no ]] && line+=" ${DIM}– nicht verfügbar${NC}"
            say "$line"
        done
    done
    say ""
}

show_history() {
    say "mic-check v${VERSION} – Test-Verlauf"
    say ""
    if [[ ! -f "$LOG_FILE" ]]; then
        say "  Noch keine Tests gespeichert."
        say "  Log-Datei: ${LOG_FILE}"
        say ""
        return
    fi
    say "  Letzte ${HISTORY_N} Ergebnisse (${LOG_FILE}):"
    say ""
    local ts verdict device codec snr noise peak freq peak_db reasons icon
    while IFS='|' read -r ts verdict device codec snr noise peak freq peak_db _ _ reasons; do
        [[ -z "$ts" ]] && continue
        case "$verdict" in
            OK)   icon="${GREEN}${I_OK}${NC}" ;;
            WARN) icon="${YELLOW}${I_WARN}${NC}" ;;
            FAIL) icon="${RED}${I_FAIL}${NC}" ;;
            *)    icon="?" ;;
        esac
        # Alte Einträge (8 Felder) haben nur den Roh-Peak
        if [[ -z "$peak_db" && "$peak" =~ ^[0-9]+$ ]] && (( peak > 0 )); then
            peak_db=$(awk -v p="$peak" 'BEGIN { printf "%.1f", 20 * log(p / 32768) / log(10) }')
        fi
        printf '  %s  %s %-4s  %-28.28s  Codec:%-6s  SNR:%-5s  Noise:%-6s  Peak:%-6s  Freq:%s\n' \
            "$ts" "$icon" "$verdict" "$device" "$codec" "$snr" "$noise" "${peak_db:-n/a}" "$freq"
        [[ -n "$reasons" ]] && say "      ${DIM}${reasons}${NC}"
    done < <(tail -n "$HISTORY_N" "$LOG_FILE")
    say ""
}

# ━━━ MENÜ ━━━
run_menu() {
    NEXT_ACTION="quit"
    (( INTERACTIVE && !NO_MENU )) || return 0
    local key opts
    while :; do
        opts="[Enter] Ende  [r] Nochmal"
        (( HAVE_SIGNAL )) && [[ -s "$FILE" ]] && opts+="  [p] Anhören"
        [[ -n "$GAIN_NEW_PCT" ]] && opts+="  ${NC}${BOLD}[g] Gain → ${GAIN_NEW_PCT}%${NC}${DIM}"
        (( ${#APPS_BAD_IDX[@]} )) && opts+="  ${NC}${BOLD}[a] Apps umleiten${NC}${DIM}"
        opts+="  [d] Gerät wählen"
        printf '  %s%s%s ' "$DIM" "$opts" "$NC"
        cur_show
        read -rsn1 key
        drain_keys
        printf '\r%s' "$EL"
        case "$key" in
            ""|q|Q) NEXT_ACTION="quit"; return 0 ;;
            r|R)    NEXT_ACTION="repeat"; return 0 ;;
            p|P)    (( HAVE_SIGNAL )) && replay_recording ;;
            g|G)
                if [[ -n "$GAIN_NEW_PCT" ]] && pactl set-source-volume @DEFAULT_SOURCE@ "${GAIN_NEW_PCT}%" 2>/dev/null; then
                    CHANGES+=("Mic-Gain → ${GAIN_NEW_PCT}%")
                    NEXT_ACTION="repeat"; return 0
                fi ;;
            a|A)    (( ${#APPS_BAD_IDX[@]} )) && move_apps ;;
            d|D)    pick_device; NEXT_ACTION="repeat"; return 0 ;;
        esac
    done
}

# Bei "kein Signal" direkt ein anderes Mikrofon anbieten → 0 = umgeschaltet
offer_alternative() {
    [[ "$LEVEL_STATE" == none ]] || return 1
    (( INTERACTIVE && !KEEP_DEVICES && !ROUTING_LOCKED )) || return 1
    (( CUR_SRC >= 0 )) && NOSIG_TRIED[${SRC_KEY[CUR_SRC]}]=1
    best_alternative
    [[ -n "$REPLY_KIND" ]] || return 1
    local name tn kind="$REPLY_KIND" ref="$REPLY_REF"
    if [[ "$kind" == src ]]; then
        name="${SRC_DESC[ref]}"; type_name "${SRC_TYPE[ref]}"; tn="$REPLY"
    else
        name="${CARD_DESC[ref]}"; tn="Bluetooth-Headset"
    fi
    cur_show
    if ask_yn "Stattdessen ${tn} testen: ${name}?"; then
        say ""
        if [[ "$kind" == src ]]; then
            switch_to_source "$ref" || return 1
        else
            switch_bt_profile "$ref" "${CARD_BEST_MIC[ref]}" || return 1
        fi
        return 0
    fi
    return 1
}

# ━━━ EIN DURCHLAUF ━━━
reset_run_state() {
    ISSUES=(); GAIN_NEW_PCT=""; APPS_OK=(); APPS_BAD=(); APPS_BAD_IDX=()
    HAVE_SIGNAL=0; LEVEL_STATE=""; BW_STATE=""
    SNR_DB=""; SNR_RATING=""; NOISE_DB=""; PEAK_DB=""; MAX_PEAK=0; CLIP_COUNT=0
    VERDICT=""
}

finish_run() {
    compute_verdict
    print_report
    log_result
    if offer_alternative; then NEXT_ACTION="repeat"; return; fi
    run_menu
}

run_check() {
    reset_run_state
    if ! detect_all; then
        say "${RED}Fehler: pactl kann den Audio-Server nicht erreichen.${NC}"
        exit 1
    fi
    print_header
    debug_dump

    if (( !KEEP_DEVICES && !ROUTING_LOCKED && INTERACTIVE )); then
        smart_routing
        (( REDETECT )) && return 0
    fi

    if (( CUR_SRC < 0 )); then
        add_issue fail mic "Kein Mikrofon gefunden" "Headset verbinden · ./mic-check.sh --list"
        finish_run
        return 0
    fi
    check_mic_state || { finish_run; return 0; }

    if measure; then
        analyze
        evaluate_level
        if (( HAVE_SIGNAL )); then
            evaluate_quality
            playback
            check_bandwidth
        fi
    fi
    check_apps
    check_echo
    check_battery
    finish_run
}

# ━━━ AUFRÄUMEN ━━━
# shellcheck disable=SC2317  # wird über trap aufgerufen
cleanup() {
    [[ -n "${REC_PID:-}" ]] && kill "$REC_PID" 2>/dev/null
    [[ -n "${PLAY_PID:-}" ]] && kill "$PLAY_PID" 2>/dev/null
    cur_show
    [[ -n "${WORK:-}" && -d "$WORK" && "$WORK" == */mic-check.* ]] && rm -rf -- "$WORK"
}

# ━━━ START ━━━
case "$ACTION" in
    help)    show_help; exit 0 ;;
    version) echo "mic-check v${VERSION}"; exit 0 ;;
esac

setup_ui

if [[ "$ACTION" == history ]]; then
    show_history
    exit 0
fi

# --- Abhängigkeiten ---
missing=()
command -v sox   >/dev/null || missing+=("sox")
command -v rec   >/dev/null || missing+=("rec (Teil von sox)")
command -v pactl >/dev/null || missing+=("pactl (libpulse / pulseaudio-utils)")
if (( ${#missing[@]} )); then
    say "${RED}Fehler: fehlende Programme: ${missing[*]}${NC}"
    say "  Arch/CachyOS:  sudo pacman -S sox libpulse"
    say "  Debian/Ubuntu: sudo apt install sox pulseaudio-utils"
    say "  Fedora:        sudo dnf install sox pulseaudio-utils"
    exit 1
fi
if ! pactl info >/dev/null 2>&1; then
    say "${RED}Fehler: pactl erreicht keinen Audio-Server.${NC}"
    say "  ${DIM}Bei PipeWire muss pipewire-pulse laufen: systemctl --user status pipewire-pulse${NC}"
    exit 1
fi

if [[ "$ACTION" == list ]]; then
    show_list
    exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mic-check.XXXXXX") || exit 1
FILE="$WORK/rec.raw"
WAIT_FILE="$WORK/wait.raw"
CHUNK="$WORK/chunk.raw"
REC_FIFO="$WORK/rec.fifo"
REC_ERR="$WORK/rec.err"
PLAY_ERR="$WORK/play.err"
# shellcheck disable=SC2017  # erst teilen, damit der Block ganze Frames enthält
CHUNK_BYTES=$(( RATE / CHUNKS_PER_SEC * CHANNELS * (BITS / 8) ))
CHUNK_SECS=$(awk -v c="$CHUNKS_PER_SEC" 'BEGIN { printf "%.3f", 1 / c }')
REC_PID=""
PLAY_PID=""
trap cleanup EXIT
trap 'printf "\n"; exit 130' INT TERM

declare -A DECLINED=() NOSIG_TRIED=()
CHANGES=()
ROUTING_LOCKED=0
auto_switches=0

# Hauptschleife statt Neustart per exec: nach einem Umschalten werden die
# Geräte neu erkannt; Optionen und Entscheidungen bleiben erhalten.
while :; do
    REDETECT=0
    NEXT_ACTION="quit"
    (( IS_TTY && !NO_CLEAR )) && clear
    cur_hide
    run_check
    if (( REDETECT )); then
        (( ++auto_switches ))
        if (( auto_switches > MAX_AUTO_SWITCHES )); then
            say ""
            say "${RED}${BOLD}Abbruch: Geräte-Umschaltung wiederholt sich (${MAX_AUTO_SWITCHES}×).${NC}"
            say "  ${DIM}Debug: ./mic-check.sh --debug   ·   Geräte beibehalten: --keep${NC}"
            exit 1
        fi
        say ""
        say "  ${BOLD}${I_REDO} Erkenne Geräte neu…${NC}"
        sleep 0.7
        continue
    fi
    auto_switches=0
    [[ "$NEXT_ACTION" == repeat ]] && continue
    break
done

[[ "$VERDICT" == FAIL ]] && exit 1
exit 0
