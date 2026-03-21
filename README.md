# 🎧 mic-check

**Pre-call microphone check for Linux** – quickly verify your mic is working and sounds good before joining a call.

![Bash](https://img.shields.io/badge/Bash-5.x-green)
![License](https://img.shields.io/badge/License-MIT-blue)
![Platform](https://img.shields.io/badge/Platform-Linux-orange)

## What it does

1. **Detects audio devices** – USB, Bluetooth, and internal microphones/speakers
2. **Smart routing** – suggests switching to the best available device (USB > BT > Internal)
3. **Auto-fix mismatches** – if your mic is USB but output is internal, it corrects automatically
4. **Live VU-meter** – 3-second recording with real-time peak level display
5. **Playback test** – plays back your recording so you can hear yourself
6. **Clear verdict** – ✅ Ready / ⚠ Adjust level / ❌ Problem

## Screenshot

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  🎧 PRE-CALL MIC CHECK  v1.4.0
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Mikrofon:  147. USB Headset Mono [vol: 1.00]
             ✓ 100%  via USB

  Ausgabe:   148. USB Headset Stereo [vol: 0.75]
             ✓ 75%  via USB

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
git clone https://github.com/YOUR_USER/mic-check.git
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
- Reads device tree from `wpctl status`
- Identifies default source (mic) and sink (output)
- Detects USB and Bluetooth devices by name patterns
- Shows volume levels and mute status
- Offers to switch to better devices if available

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
