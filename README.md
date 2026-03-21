# 🎧 mic-check

**Pre-call microphone check for Linux** – quickly verify your mic is working and sounds good before joining a call.

![Bash](https://img.shields.io/badge/Bash-5.x-green)
![License](https://img.shields.io/badge/License-MIT-blue)
![Platform](https://img.shields.io/badge/Platform-Linux-orange)

## What it does

1. **Detects audio server** – shows PipeWire or PulseAudio with version info
2. **Detects audio devices** – USB, Bluetooth, and internal microphones/speakers
3. **Shows Bluetooth codec/profile** – active codec (mSBC, CVSD, SBC, AAC), warns if suboptimal for mic use
4. **Smart routing** – suggests switching to the best available device (USB > BT > Internal)
5. **Auto-fix mismatches** – if your mic is USB but output is internal, it corrects automatically
6. **Noise floor measurement** – 1-second silence test to check ambient noise level
7. **Live VU-meter** – 3-second recording with real-time peak level display
8. **Playback test** – plays back your recording so you can hear yourself
9. **Clear verdict** – ✅ Ready / ⚠ Adjust level / ❌ Problem

## Screenshot

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  🎧 PRE-CALL MIC CHECK  v1.4.1
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Audio:     PipeWire (+ PulseAudio-Compat) v1.0.7 + wireplumber

  Mikrofon:  85. OnePlus Buds Pro 2 Handsfree [vol: 1.00]
             ✓ 100%  via BT

  Ausgabe:   84. OnePlus Buds Pro 2 Handsfree [vol: 0.60]
             ✓ 60%  via BT

  Bluetooth-Profil:
    Profil:  Handsfree (HFP)
    Codec:   mSBC
    Verfügbare Profile:
      • handsfree-headunit-msbc  ← aktiv
      • handsfree-headunit-cvsd
      • a2dp-sink-sbc-xq
      • a2dp-sink-sbc
      • a2dp-sink-aac

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  🔇 Rauschboden-Messung – Bitte 1s still sein...
  Noise Floor: -52.3 dB (sehr gut)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  🎙  Pegeltest – Sprich 3s lang...

  INPUT  [████████████░░░░░░░░░░░░░░░░░░░░░░░]  -12.3 dB

  ✓ PEGEL OK

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ✓ BEREIT FÜR DEN ANRUF
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

## How it works

### Phase 1 – System Check
- Detects audio server (PipeWire vs PulseAudio) and session manager
- Reads device tree from `wpctl status`
- Identifies default source (mic) and sink (output)
- Detects USB and Bluetooth devices by name patterns
- Shows Bluetooth codec/profile and warns about suboptimal choices
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

The script detects which profile is active and warns if a Headphones (A2DP) profile is in use while testing the microphone.

### Phase 1.5 – Noise Floor
- Records 1 second of silence
- Measures ambient noise level in dB
- Rates: very good / acceptable / too high

### Phase 2 – Live Level Test
- Records 3 seconds via `sox` (`rec`)
- Displays real-time VU-meter with peak levels in dB
- Evaluates: no signal / too quiet / OK / clipping

### Phase 3 – Playback
- Plays back the recording through your speakers/headphones
- Shows output VU-meter during playback
- You can judge your own audio quality

### Verdict
- **✅ BEREIT FÜR DEN ANRUF** – Ready for the call
- **⚠ FUNKTIONIERT, ABER PEGEL ANPASSEN** – Works, but adjust level
- **❌ MIKROFON PROBLEM – NICHT ANRUFEN** – Mic problem, don't call

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
