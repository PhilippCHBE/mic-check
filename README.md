# 🎧🎙 mic-check

**Pre-call microphone check for Linux** – quickly verify your mic is working and sounds good before joining a call.

![Bash](https://img.shields.io/badge/Bash-5.x-green)
![License](https://img.shields.io/badge/License-MIT-blue)
![Platform](https://img.shields.io/badge/Platform-Linux-orange)

## What it does

1. **Detects audio server** – shows PipeWire or PulseAudio with version info
2. **Detects audio devices** – USB, Bluetooth, and internal microphones/speakers
3. **Shows Bluetooth codec/profile** – active codec (mSBC, CVSD, SBC, AAC), warns if suboptimal
4. **Auto-switches BT to Handsfree mSBC** – 3-second countdown to switch system-wide via `pactl`, press space to skip
5. **Smart routing** – suggests switching to the best available device (USB > BT > Internal)
6. **Auto-fix mismatches** – if your mic is USB but output is internal, it corrects automatically
7. **Noise floor measurement** – 1-second silence test to check ambient noise level
8. **Live VU-meter** – 3-second recording with real-time peak level display
9. **Signal-to-noise ratio (SNR)** – calculates and rates SNR from noise floor vs speech level
10. **Frequency response check** – detects 4kHz cutoff (CVSD codec limitation)
11. **Playback test** – plays back your recording so you can hear yourself
12. **History log** – saves all test results to `~/.mic-check.log` for tracking over time
13. **Clear verdict** – ✅ Ready / ⚠ Adjust level / ❌ Problem

## Screenshot

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  🎧🎙 PRE-CALL MIC CHECK  v1.4.3
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Audio:     PipeWire (+ PulseAudio-Compat) v1.6.2 + wireplumber

  Mikrofon:  109. OnePlus Buds Pro 2 [vol: 1.00]
             ✓ 100%  via BT

  Ausgabe:   104. OnePlus Buds Pro 2 [vol: 0.47]
             ✓ 47%  via BT

  Bluetooth-Profil:
    Profil:  Headset (HSP/HFP)
    Codec:   CVSD
    Verfügbare Profile:
      • a2dp-sink-sbc
      • a2dp-sink-sbc_xq
      • a2dp-sink
      • headset-head-unit-cvsd ← aktiv
      • headset-head-unit

    ⚠ CVSD hat niedrige Qualität (8kHz). mSBC wäre besser.

    ⏳ Wechsle zu headset-head-unit in 3s – [Leertaste] zum Überspringen
    ✓ Profil umgeschaltet auf headset-head-unit (system-weit)
    ↻ Starte Mic-Check neu...
```

## Installation

### Dependencies

```bash
# Arch / CachyOS
sudo pacman -S sox

# The script uses wpctl (WirePlumber), which is pre-installed on most
# PipeWire-based systems (CachyOS, Fedora, Ubuntu 22.10+, etc.)
```

### Setup

```bash
# Clone the repository
git clone https://github.com/PhilippCHBE/mic-check.git
cd mic-check

# Make executable
chmod +x mic-check.sh

# Optional: create alias
echo 'alias miccheck="~/mic-check/mic-check.sh"' >> ~/.bashrc
source ~/.bashrc
```

## Usage

```bash
# Basic mic check
./mic-check.sh

# Keep current devices (skip switch suggestions)
./mic-check.sh --keep

# Debug mode (show device detection details)
./mic-check.sh --debug

# List all audio devices
./mic-check.sh --list

# Show test history
./mic-check.sh --history

# Show version
./mic-check.sh --version

# Show help
./mic-check.sh --help
```

## Options

| Option      | Description                                      |
|-------------|--------------------------------------------------|
| `--help`    | Show help message                                |
| `--version` | Show version number                              |
| `--keep`    | Keep current devices, don't suggest switching    |
| `--debug`   | Show debug info for device detection             |
| `--list`    | List all audio devices via `wpctl status`        |
| `--history` | Show last 20 test results from log file          |

## How it works

### Phase 1 – System Check
- Detects audio server (PipeWire vs PulseAudio) and session manager
- Reads device tree from `wpctl status`
- Identifies default source (mic) and sink (output)
- Detects USB and Bluetooth devices by name patterns
- Shows Bluetooth codec/profile and warns about suboptimal choices
- **Auto-switches BT to Handsfree mSBC** with 3s countdown (space to skip), system-wide via `pactl`
- Shows volume levels and mute status
- Offers to switch to better devices if available

### Bluetooth Codecs

For **microphone usage**, your BT headset must use a **Handsfree (HFP)** profile:

| Codec  | Profile    | Mic? | Quality | Recommendation |
|--------|------------|------|---------|----------------|
| mSBC   | Handsfree  | ✅   | Good    | **Best for calls** – 16kHz wideband |
| CVSD   | Handsfree  | ✅   | Low     | Fallback – 8kHz narrowband |
| SBC-XQ | Headphones | ❌   | High    | Music only, no mic |
| SBC    | Headphones | ❌   | Medium  | Music only, no mic |
| AAC    | Headphones | ❌   | High    | Music only, no mic |

The script detects which profile is active and **automatically switches system-wide** to Handsfree mSBC with a 3-second countdown. Press space to skip.

### Phase 1.5 – Noise Floor
- Records 1 second of silence
- Measures ambient noise level in dB
- Rates: very good / acceptable / too high

### Phase 2 – Live Level Test
- Records 3 seconds via `sox` (`rec`)
- Displays real-time VU-meter with peak levels in dB
- Evaluates: no signal / too quiet / OK / clipping

### Phase 2.5 – Signal Analysis
- **Signal-to-Noise Ratio (SNR)**: Calculates SNR from noise floor vs speech peak, rated as excellent (≥40dB) / good (≥25dB) / acceptable (≥15dB) / poor (<15dB)
- **Frequency Response Check**: Analyzes energy in 3 bands (300–1kHz, 1–4kHz, 4–8kHz) to detect if the mic cuts off above 4kHz – a telltale sign of CVSD codec limitation

### Phase 3 – Playback
- Plays back the recording through your speakers/headphones
- Shows output VU-meter during playback
- You can judge your own audio quality

### Verdict & Logging
- **✅ BEREIT FÜR DEN ANRUF** – Ready for the call
- **⚠ FUNKTIONIERT, ABER PEGEL ANPASSEN** – Works, but adjust level
- **❌ MIKROFON PROBLEM – NICHT ANRUFEN** – Mic problem, don't call
- Results are saved to `~/.mic-check.log` with timestamp, device, codec, SNR, noise floor, peak level, and frequency check result
- View history with `./mic-check.sh --history`

## Device Priority

The script prefers devices in this order:
1. **USB** – most reliable for calls
2. **Bluetooth** – good with proper codec (mSBC preferred)
3. **Internal** – laptop mic as fallback

## Requirements

- **Linux** with PipeWire + WirePlumber (or PulseAudio)
- **sox** for recording and playback
- **Bash 4+**
- A terminal with Unicode and ANSI color support

## License

MIT
