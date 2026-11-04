# 🎧🎙 mic-check

**Pre-call microphone check for Linux** – in about 10 seconds you know whether your mic, headset and output are ready for the call, and most problems are fixed with a single key.

![Bash](https://img.shields.io/badge/Bash-4.3+-green)
![License](https://img.shields.io/badge/License-MIT-blue)
![Platform](https://img.shields.io/badge/Platform-Linux-orange)

## What it does

1. **Detects audio server** – PipeWire (via pipewire-pulse) or PulseAudio, with version
2. **Detects devices by their properties** – USB, Bluetooth, webcam, internal, HDMI and virtual (filter) devices are recognised from `node.name` / `device.api` / `device.bus`, not from brand names
3. **Suggests the best microphone** – USB > Bluetooth > Webcam > Internal, and switches mic *and* matching output together
4. **Bluetooth profile handling** – headset in music mode (A2DP, no mic) or on CVSD is switched system-wide to the best available headset profile (LC3-SWB / mSBC / …) with a 3-second countdown, any key skips. Unavailable profiles are ignored, and the script waits until the headset mic actually appears
5. **Leaves good setups alone** – a USB mic with Bluetooth headphones keeps its A2DP music quality; virtual sources (EasyEffects, noise filters, echo cancel) are never switched away
6. **Fixes mute & volume** – offers to unmute a muted mic or output and to raise volumes that are near 0 %
7. **Noise floor** – 1-second RMS measurement on the same recording stream
8. **Live level meter** – dB-scaled meter with the target zone shaded and a peak-hold marker; recording starts when you start talking (including the first syllable)
9. **SNR, clipping & bandwidth** – RMS-based signal-to-noise ratio, clipped-sample count, and a 4 kHz cutoff check (typical for CVSD)
10. **Real output check** – plays the recording back and asks *"Gehört? [J/n]"*
11. **App check** – shows which apps (Zoom, browser, …) are recording and whether they use the tested mic; one key moves them over
12. **Echo & battery warnings** – laptop mic + speakers, Bluetooth headset battery below 20 %
13. **One-key fixes** – `[g]` sets the mic gain to the target level and re-tests, `[a]` redirects apps, `[d]` lets you pick any device, `[r]` repeats, `[p]` replays
14. **History log** – every result (including failures, with reasons) goes to `~/.mic-check.log`
15. **Clear verdict** – ✅ Ready / ⚠ Adjust / ❌ Don't call

## Screenshot

```
  🎧🎙 MIC CHECK v1.5.0 ─── PipeWire v1.2.7 + wireplumber
  🎤 Mic: OnePlus Buds Pro 2 [BT] 100%  · Codec: mSBC 16 kHz  · 🔋 64%
  🔊 Out: OnePlus Buds Pro 2 [BT] 79%
  BT-Profile:  🎧🎙 Headset: CVSD, mSBC (aktiv)  │  🎧 Musik: SBC, SBC-XQ, AAC
  ↻ Bluetooth-Profil → Headset · mSBC
  ↻ Mikrofon → OnePlus Buds Pro 2

  🤫 Rauschboden (bitte 1 s still sein…): -65.2 dB (sehr gut)
  💬 Sprich jetzt, z.B.: „Sechs Schweizer Spezialisten testen das Mikrofon.“
  🎤 INPUT  [████████████████████████▒▒▒▒▒░]  -12.0 dB  ✓
  🔊 OUTPUT [████████████████████████▒▒▒▒▒░]  -12.0 dB  ✓ gehört

  ✓ Pegel OK │ SNR: 41.5dB (exzellent) │ Rauschen: -65.2dB │ Freq: >4kHz ✓
  Apps am Mikrofon: ZOOM VoiceEngine ✓ Firefox ⚠

  ⚠ Firefox nimmt von „Family 17h/19h HD Audio Controller Digit“ auf – nicht vom getesteten Mikrofon
      → [a] auf getestetes Mikrofon umleiten

  ══  ⚠  BEREIT MIT EINSCHRÄNKUNGEN  (log:~/.mic-check.log) ══

  [Enter] Ende  [r] Nochmal  [p] Anhören  [a] Apps umleiten  [d] Gerät wählen
```

## Installation

### Dependencies

```bash
# Arch / CachyOS
sudo pacman -S sox libpulse

# Debian / Ubuntu
sudo apt install sox pulseaudio-utils

# Fedora
sudo dnf install sox pulseaudio-utils
```

`pactl` talks to PipeWire through `pipewire-pulse`, which is installed by default on
PipeWire-based distributions (CachyOS, Fedora, Ubuntu 22.10+, …). `bluetoothctl`
(BlueZ) is optional and only used to read the headset battery level.

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

# Keep current devices (no switching at all)
./mic-check.sh --keep

# Skip the playback / "did you hear yourself" step
./mic-check.sh --no-playback

# Exit right after the verdict (no key menu)
./mic-check.sh --no-menu

# List all audio devices and Bluetooth profiles
./mic-check.sh --list

# Show the last 50 test results
./mic-check.sh --history 50
```

## Options

| Option          | Description                                            |
|-----------------|--------------------------------------------------------|
| `--help`        | Show help message                                      |
| `--version`     | Show version number                                    |
| `--keep`        | Keep current devices, don't suggest or switch anything |
| `--no-playback` | Don't play the recording back (no output test)         |
| `--no-menu`     | Exit directly after the verdict                        |
| `--no-clear`    | Don't clear the screen first                           |
| `--ascii`       | No emojis (for terminals with emoji width problems)    |
| `--debug`       | Show device detection details                          |
| `--list`        | List all audio devices and Bluetooth profiles          |
| `--history [N]` | Show the last N test results (default 20)              |

`NO_COLOR=1` disables colors. Unknown options are rejected (exit code 2).

### Keys after the test

| Key       | Action                                                       |
|-----------|--------------------------------------------------------------|
| `Enter`/`q` | Quit                                                       |
| `r`       | Run the test again (e.g. after joining the call, to re-check apps) |
| `p`       | Play the recording again                                     |
| `g`       | Set the mic gain to the suggested value and re-test (shown when too quiet / clipping) |
| `a`       | Move apps that record from another mic to the tested mic     |
| `d`       | Pick microphone and output from a numbered list              |

## How it works

### Phase 1 – System check
- Reads sources, sinks and cards from `pactl` (stable format on PipeWire and PulseAudio, independent of the WirePlumber version)
- Classifies every node by its properties and groups mic, output and card of the same device
- Shows mic and output (name, type, volume, mute) plus Bluetooth codec, sample rate and battery
- **Smart routing** (interactive only, not with `--keep`):
  - better mic available → asks to switch mic + matching output
  - Bluetooth headset is your output but in music mode → countdown, then switches to the best headset profile
  - Bluetooth mic on a worse codec (CVSD) than available (mSBC) → countdown, then switches
  - USB/BT mic but output on laptop speakers/HDMI → output follows the mic automatically
- Switching happens in a loop (no restart of the script): devices are re-detected, options and your "no" answers are kept. A guard stops after 4 automatic switches in a row

### Bluetooth codecs

For **microphone usage**, the headset must use a profile with a microphone (HFP/HSP or LE Audio):

| Codec   | Profile    | Mic? | Quality   | Recommendation |
|---------|------------|------|-----------|----------------|
| LC3-SWB | Handsfree  | ✅   | Very good | Best if supported – 32 kHz super-wideband |
| mSBC    | Handsfree  | ✅   | Good      | **Best for most headsets** – 16 kHz wideband |
| CVSD    | Handsfree  | ✅   | Low       | Fallback – 8 kHz narrowband |
| SBC-XQ  | Headphones | ❌   | High      | Music only, no mic |
| SBC     | Headphones | ❌   | Medium    | Music only, no mic |
| AAC     | Headphones | ❌   | High      | Music only, no mic |

The script reads which profiles have a microphone (`sources: 1`), their codec and whether they are available from `pactl list cards`.

### Phase 2 – Measurement (one recording stream)
- The first 0.3 s are discarded (switch-on click, especially on Bluetooth)
- **Noise floor**: 1 s RMS – rated very good / acceptable / high
- **Speech**: waits up to 5 s until you speak (threshold ~10 dB above the noise floor), keeps the block before the trigger, then records 3 s
- **Level**: peak in dBFS – no signal (< -40 dB), too quiet (< -24 dB), OK, clipping (≥ -1 dB or clipped samples)
- **SNR**: RMS of the speech blocks minus noise RMS – excellent (≥ 30 dB) / good (≥ 20) / acceptable (≥ 12) / poor
- **Bandwidth**: energy at 4.5–7.5 kHz relative to 1–4 kHz (via `sox sinc`); far below → narrowband (≤ 4 kHz), typical for CVSD

### Phase 3 – Playback
- Unmutes / raises the output if needed (asks first)
- Plays the recording with a synchronised meter and asks whether you heard yourself

### Verdict & logging
- Every problem becomes an entry with a hint (and a key, if it can be fixed): ❌ fail, ⚠ warning, ℹ info
- **✅ BEREIT FÜR DEN ANRUF** – no problems
- **⚠ PEGEL ANPASSEN / BEREIT MIT EINSCHRÄNKUNGEN** – works, but something should be adjusted
- **❌ MIKROFON / AUDIO PROBLEM – NICHT ANRUFEN** – no signal, muted, playback not heard, …
- Exit code: 0 for OK/WARN, 1 for FAIL
- Results are appended to `~/.mic-check.log`:
  `timestamp|verdict|mic|codec|snr|noise|peak_raw|freq|peak_db|output|mic_volume|reasons`
  (the first 8 fields are unchanged from earlier versions, so old logs still show in `--history`)

## Configuration

Settings can be overridden in `~/.config/mic-check/config` (a bash file that is sourced), e.g.:

```bash
CHECK_SECS=4             # length of the speech recording
WAIT_SECS=8              # how long to wait for you to start speaking
LVL_TARGET=-12           # target peak for the [g] gain fix (dBFS)
MAX_GAIN_PCT=120         # never raise the mic above this volume
BATTERY_WARN=30          # warn below this headset battery level (%)
READ_PROMPT="Hallo, hört ihr mich gut?"
LOG_FILE="$HOME/.local/state/mic-check.log"
```

All variables are listed at the top of `mic-check.sh`.

## Requirements

- **Linux** with PipeWire (+ pipewire-pulse) or PulseAudio
- **sox** (`rec`) for recording, playback and analysis
- **pactl** (libpulse / pulseaudio-utils)
- **Bash 4.3+** and GNU coreutils
- Optional: **bluetoothctl** for the headset battery level
- A terminal with Unicode and ANSI color support (or use `--ascii` / `NO_COLOR=1`)

## Changelog

### 1.5.0
- Device detection via `pactl` node properties instead of `wpctl status` text and brand names: works with WirePlumber 0.4 and 0.5 and with PulseAudio; AMD/other internal audio is no longer mistaken for Bluetooth
- Restart loop instead of `exec`: flags and decisions survive a device switch; a second switch no longer ends in "Abbruch"
- Bluetooth: switch to headset profile only when the headset should be the mic (USB mic + BT headphones stay in A2DP); correct card with several BT devices; unavailable profiles skipped; waits for the mic node instead of a fixed pause; LC3 recognised
- Recording: one continuous stream with full-block reads (the old loop recorded only ~1.4 s of the 3 s), pre-roll, noise-relative speech trigger, RMS-based noise floor and SNR, clip counter, `sox sinc` bandwidth check
- Verdict includes noise, SNR, bandwidth, output and app problems; failures are logged with reasons
- New: unmute/volume offers, "Gehört?" output check, app stream check and redirect, echo hint, battery warning, gain fix, key menu, device picker, dB meter with target zone, output device in header, `--no-playback`, `--no-menu`, `--no-clear`, `--ascii`, `--history N`, `NO_COLOR`, config file

## License

MIT
