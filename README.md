<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/logo-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/assets/logo-light.svg">
    <img src="docs/assets/logo-dark.svg" alt="Loopbacker" width="180">
  </picture>
</p>

<h1 align="center">Loopbacker</h1>

<p align="center">
  Virtual audio loopback + broadcast voice processing for macOS.
</p>

<p align="center">
  <a href="https://github.com/JacobCoffee/loopbacker/actions/workflows/ci.yml"><img src="https://github.com/JacobCoffee/loopbacker/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/JacobCoffee/loopbacker/releases"><img src="https://img.shields.io/github/v/release/JacobCoffee/loopbacker?include_prereleases" alt="Release"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2026%2B-blue" alt="macOS 26+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-FSL--1.1--MIT-blue" alt="FSL-1.1-MIT"></a>
</p>

---

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/routing-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="docs/screenshots/routing-light.png">
    <img src="docs/screenshots/routing-dark.png" alt="Loopbacker routing canvas: a MOTU M2 source cabled into the virtual mic, with live meters" width="800">
  </picture>
</p>

Loopbacker creates a virtual audio device on macOS that captures audio from any app and makes it available as a mic input. Route desktop audio into Discord, OBS, Zoom, or any recording app. It also has a full audio effects chain for broadcast voice processing, and a soundboard for playing audio clips through the virtual device.

## Features

**Audio Routing**

- Virtual loopback devices (48kHz / 32-bit float), 2–16 channels per device
- Route any channel of any input device to any virtual mic channel; add mic channels in pairs with ⊕
- Monitor output (hear yourself through speakers)
- Per-channel routing with visual cable connections
- 3 independent virtual loopback devices: the virtual mic, a second device for multichannel output routing, and Stream Mix (a separate virtual mic target -- see **Stream Mix** below)
- Output routing: send one channel pair of a multichannel device to your speakers while apps record the other channels
- Scenes system for saving/loading routing configs, applied as a diff so routes shared between scenes (e.g. the same mic) never drop
- Automation rules switch scenes on their own — app launched/quit/frontmost, or a device connected/removed — with a fallback scene and a manual-override pause
- Per-source fallback device list: rebinds to the next available device if the active one disappears, and switches back when it returns, with a notification
- Open at Login: starts in the menu bar with routing live, no window (menu bar panel or **More** menu)

**Noise Suppression**

- On-device noise removal for mic inputs, run inline on the audio thread, with three engines:
  - [CEVA's DPDFNet2](https://github.com/ceva-ip/DPDFNet) 48 kHz neural model through BNNS Graph: strongest cleanup (fans, keyboards, chatter), 60 ms of latency
  - [aask1357's FastEnhancer-M](https://github.com/aask1357/fastenhancer) 48 kHz neural model, also through BNNS Graph: matches DPDFNet's cleanup, 21 ms of latency, similar CPU
  - [Xiph's RNNoise](https://github.com/xiph/rnnoise): lighter cleanup (steady hiss and hum), 30 ms of latency, about a third of DPDFNet's CPU
- The Effects section compares them with CPU measured on your Mac and recommends one; switching frees the other engine's memory
- Runs before the effects chain, independent of its bypass and presets; toggle it from the Effects section or the menu bar
- Per-mic opt-out in each source's Options
- Max Reduction control (-60 to -6 dB) to keep some room tone instead of dead silence
- Latency is constant at any buffer size
- Applies to mic → virtual mic, Stream Mix, and monitor routes, not app captures

**Effects Chain** (10 real-time DSP stages, hosted plugins, all processed on the audio thread)

Built-in stages, in any order you drag them into:

- Noise Gate -- level-triggered or voice-activity-keyed (so word endings and breaths don't chatter), with hold/attack/release and a lookahead
- Parametric EQ -- up to 16 bands (highpass/lowshelf/peaking/highshelf/lowpass/notch), draggable frequency response curve, selectable filter slopes
- Compressor -- linked stereo detection, adjustable ratio/threshold/makeup
- Leveler -- auto-gain that holds your voice at a target LUFS (ITU-R BS.1770 K-weighting), only adjusting while you're talking so it doesn't pump room noise during pauses
- De-Esser -- split-band (Linkwitz-Riley crossover) or wideband sibilance control
- Chorus -- modulated delay line with stereo LFO
- Pitch Shift -- -12 to +12 semitones, phase-vocoder with independent formant preservation
- Reverb -- 8-line feedback delay network (Hadamard-mixed, per-line LFO modulation)
- Delay -- echo with feedback + soft-clip safety
- Limiter -- true-peak brickwall limiter with lookahead

Reorder, bypass, or A/B any stage individually; drop in third-party plugins (see **Plugins** below)
anywhere in the chain. Runs only on mic (voice) routes -- virtual mic, Stream Mix, and monitor --
never on app-capture routes, which get their own ducking and leveling instead (in the Effects
page's App Audio section). Toggling a stage crossfades instead of clicking, and the whole chain's A/B bypass
loudness-matches so comparisons are about tone, not volume.

17 factory presets across four categories -- Business (Meeting – Natural, Presentation/Webinar, Open
Office, Laptop Mic Rescue), Gaming (Headset, Speakers), Streaming (Stream/Broadcast, Podcast, Late
Night), and Creative (Chipmunk, Deep Voice, Robot, Telephone, Radio Announcer, Cathedral, Dreamy,
Space Station). Each business/gaming/streaming preset also dials in noise suppression to match, and
Speakers – Gaming turns on echo cancellation. Save your own presets, import/export as JSON to share with others.

**Auto Setup** records a few seconds of you talking and silence, measures your noise floor,
speech loudness, peaks, sibilance, and spectral tilt, and tunes the current preset's built-in
stages to match -- without touching its node order or any hosted plugins. **Mic Check** plays
back raw vs. processed audio through your speakers for an A/B listen, waveforms included.

<p align="center">
  <img src="docs/screenshots/effects-dark.png" alt="Effects section: vertical insert chain beside the parametric EQ editor" width="720">
</p>

**Plugins**

- Audio Units -- v2 effects load in-process through their classic C API (no extra permission
  prompt); v3 effects load out-of-process over XPC. Both appear in the effect browser's "Audio
  Units" tab alongside their native editor UI, when they have one
- REAPER JSFX -- drop a `.jsfx` script into `~/Library/Application Support/REAPER/Effects` (REAPER
  itself, or anything installed through ReaPack) or `~/Library/Application Support/Loopbacker/JSFX`
  (your own), and it shows up in the "JSFX" tab, sliders and `@gfx` UI included. Runs on the vendored
  ysfx/EEL2 JIT compiler, the same engine REAPER itself uses
- Airwindows -- ~500 of [baconpaul's airwin2rack](https://github.com/baconpaul/airwin2rack) effects
  bundled in, searchable in the "Airwindows" tab; turn the whole library off in Settings › General if
  you don't want it cluttering the picker

Any plugin inserts anywhere in the chain alongside the built-in stages, drag-reorderable the same way.
If a plugin crashes Loopbacker, it loads bypassed (with a "crashed last time -- click to retry" notice
on its stage) the next time you launch, instead of crashing the app again on every relaunch; click to
retry it once you've sorted out the plugin.

**Echo Cancellation**

- Removes your speakers' own output from your mic (WebRTC's AEC3), so playing back a call's audio
  on speakers -- instead of headphones -- doesn't echo back to the other side
- Needs System Audio Recording permission (macOS asks the first time it's turned on) to capture what
  your speakers are playing as the reference signal
- Per-source opt-out; off by default
- A live "echo removed" indicator in the Effects section while a call-shaped signal is present

**Stream Mix**

- A second virtual mic ("Loopbacker Stream"), independent of your main virtual mic -- route a source
  into one, the other, or both, with its own channel count and routing
- Built for a stream mix that folds in music or alerts for OBS without touching what Discord/Zoom hear
  on your main virtual mic
- Off by default; enable it from the toggle in the Routing canvas header
- Shares the same voice effects chain and noise suppression as your main virtual mic when they're fed
  by the same source

**Hotkeys and Automation**

- Global push-to-talk, push-to-mute, or toggle-mute hotkey (no Accessibility permission needed), with
  a muted overlay showing your mute state and the hotkey itself
- Auto-switch the effects preset by frontmost or running app -- e.g. a louder "Stream/Broadcast" preset
  while OBS is frontmost, reverting when it quits
- Shortcuts app support (mute/unmute, apply a preset, load a scene), and a `loopbacker://` URL scheme
  so other apps and web pages can trigger the same actions. URL commands other than mute are off
  until you turn on Settings › General › "Allow Other Apps to Control Loopbacker"

**Loudness Meter** (ITU-R BS.1770-4 / EBU R128)

- Momentary (400 ms), short-term (3 s), and gated integrated loudness, plus true peak, on the virtual mic's output
- Target presets: Voice/Podcast (-16 LUFS), Broadcast EBU R128 (-23 LUFS), or a custom target
- "Too quiet / on target / too loud" readout in the menu bar panel and the Routing page, with a reset-integrated button
- Measuring only -- pair with the Effects limiter/compressor for gain control

**Soundboard**

- Play audio files (MP3, WAV, M4A, AIFF, FLAC, CAF) through the virtual device
- Add individual files or scan an entire folder
- Drag and drop audio files onto the grid
- Multiple simultaneous sounds (CoreAudio mixes them on the device)
- Per-pad trim (waveform editor), fade in/out, play mode (one-shot/loop/hold-to-play), choke groups, restart-vs-layer retrigger, and output target (virtual mic only, or mic + speakers)
- Loudness-matched pads: each clip's integrated loudness is measured on import and gain-matched so pads play at a consistent level, independent of per-pad volume
- Global volume control
- Sounds appear in Discord/Zoom/OBS as if they're your mic

<p align="center">
  <img src="docs/screenshots/soundboard-light.png" alt="Soundboard section: a grid of sound pads" width="720">
</p>

**UI**

- macOS 26 Liquid Glass design, light and dark, with an in-app appearance override
- Sidebar with Routing, Effects, Soundboard, and Scenes (⌘1–⌘4), plus every source's live level and on/off switch
- Routing canvas where cables glow with the signal running through them, or a keyboard- and VoiceOver-navigable connection matrix (toggle in the Routing toolbar; each cell is a labeled, togglable connection, canvas ports offer VoiceOver "Connect to…"/"Disconnect from…" actions, and a Virtual Mic/Stream Mix picker switches which target's columns the matrix edits once Stream Mix is enabled)
- Effects shown as a vertical insert chain, like a channel strip
- Menu bar panel with live meters, per-source switches, Reconnect, and Test Tone
- Audio menu with keyboard shortcuts: Reconnect (⌘R), Stop All Routing (⇧⌘.), Test Tone (⌥⌘T)
- Background auto-update (Sparkle, EdDSA-signed): checks silently, never pops a window in front
  of you -- "Update available" shows in the menu bar panel and the app menu, and installs on your
  click or on quit. Driver updates are offered the same way but always need your click, since
  installing one needs admin and briefly drops audio

<p align="center">
  <img src="docs/screenshots/menubar-dark.png" alt="Menu bar panel with engine status, per-source meters and switches, Reconnect, and Test Tone" width="300">
</p>

## How it works

```
Mic / App Output                        Discord / OBS / Zoom
       |                                       ^
       | capture                               | reads as mic input
   [ Noise Suppression ]  (mic routes only)    |
   [ Echo Cancellation ]                       |
   [ Effects Chain ]      user-ordered stages  |
   [ Mic Gate ]                                |
       |                                       |
       v                                       |
   +---+---------------------------------------+---+
   |              Lock-free Ring Buffer             |
   +------------------------------------------------+
            Loopbacker virtual mic / Stream Mix
```

A CoreAudio HAL plugin provides the virtual devices. The SwiftUI app handles routing, effects processing, and driver installation. The effects chain, noise suppression, and echo cancellation run on the real-time audio thread with no allocations or locks; the noise and AEC3 models execute through preallocated, wired buffers. See [`docs/architecture/ARCHITECTURE.md`](docs/architecture/ARCHITECTURE.md) for how the chain, hosted plugins, and routing fit together.

## Install

### From source

Requires Xcode command-line tools and CMake (`brew install cmake`).

```bash
make all          # Build driver + app
make install      # Install driver (sudo) + app to /Applications
```

### From release

Download from [Releases](https://github.com/JacobCoffee/loopbacker/releases).

## Uninstall

```bash
make uninstall    # Remove driver + app
```

## Usage

1. Open **Loopbacker.app** and click **Install Driver** at the bottom of the sidebar (requires admin).
2. Add your microphone as a source with **+** in the toolbar or next to **Sources** in the sidebar.
3. In **Routing**, click a source channel's port, then an output channel's port, to connect them.
4. In your chat/recording app, select **Loopbacker** as the input device.
5. Open **Effects** (⌘2) to enable broadcast voice processing.
6. Open **Soundboard** (⌘3) to play audio clips through the virtual device, or **Scenes** (⌘4) to save and switch setups.

### Multichannel example: timecode alongside monitoring

1. In **Routing → Output Routing**, add **Loopbacker 2**, set **Channels** to 4, **Monitor** to 1–2, and **Output** to your speakers.
2. In DaVinci Resolve (or any app), output to **Loopbacker 2** and put the timecode on channel 3.
3. Point your timecode-to-MIDI tool at **Loopbacker 2**, channel 3. You hear channels 1–2; channel 3 never reaches the speakers.

### Using your REAPER JSFX scripts or Audio Units

1. Open **Effects** (⌘2), click **+** to open the effect browser, and pick the **Audio Units** or
   **JSFX** tab.
2. **Audio Units**: every effect Audio Unit installed on your Mac that can run a stereo voice pair
   at 48 kHz shows up automatically -- no setup needed.
3. **JSFX**: drop your `.jsfx` scripts into `~/Library/Application Support/Loopbacker/JSFX` (or
   install them into REAPER/ReaPack as usual -- Loopbacker reads REAPER's own
   `~/Library/Application Support/REAPER/Effects` folder too), then reopen the effect browser to
   pick them up.
4. Click an effect to insert it into the chain at the position you clicked **+** from; drag it
   anywhere else in the chain afterward. Plugins with their own editor window or `@gfx` UI show an
   **Edit** button on their stage.

## Project structure

```
loopbacker/
├── Driver/          CoreAudio HAL plugin (C++17, CMake)
│   └── src/         Lock-free ring buffer, driver vtable, device management
├── App/             SwiftUI companion app (Swift 6 language mode, macOS 26)
│   ├── CRNNoise/    Vendored RNNoise (C)
│   ├── CWebRTCAEC/  Vendored WebRTC AEC3 + abseil (echo cancellation)
│   ├── CYSFX/       Vendored ysfx/EEL2 (REAPER JSFX hosting)
│   ├── CAirwindows/ Vendored Airwindows effects (airwin2rack)
│   └── Sources/
│       ├── Models/      AudioSource, AudioRoute, EffectsPreset, FXNodeConfig, FactoryPresets, SoundboardItem
│       ├── Services/    AudioRouter, NoiseSuppressor, LoudnessMeter, SoundboardPlayer
│       │   ├── FX/      FXChain, FXEngine, FXNodeFactory, built-in DSP stages, Hosted/ (AU/JSFX/Airwindows)
│       │   ├── Comms/   EchoCanceller, SystemAudioTap
│       │   └── Control/ GlobalHotkeyManager, PresetAutoSwitcher, LoopbackerURLCommand
│       └── Views/       ContentView, EffectsView, SoundboardView, ...
├── scripts/         Install/uninstall helpers, model conversion, denoiser quality eval
└── docs/            Architecture docs
```

## Requirements

- macOS 26+ (Tahoe or later)
- Apple silicon (Intel Macs aren't supported)
- CMake 3.20+

## License

[FSL-1.1-MIT](LICENSE) -- free to use for any non-competing purpose, converts to MIT after 2 years.

The bundled noise suppression models are converted from upstream sources: `DPDFNet2_48k.mlmodelc` from [CEVA's DPDFNet](https://github.com/ceva-ip/DPDFNet) ([Apache-2.0](App/Loopbacker/Resources/DPDFNet-LICENSE.txt), `scripts/convert-dpdfnet.py`) and `FastEnhancer_M_48k.mlmodelc` from [aask1357's FastEnhancer](https://github.com/aask1357/fastenhancer) ([MIT](App/Loopbacker/Resources/FastEnhancer-LICENSE.txt), `scripts/convert-fastenhancer.py m`); both need [uv](https://docs.astral.sh/uv/) to rebuild.

[RNNoise](https://github.com/xiph/rnnoise) (v0.2, default model) is vendored in `App/Loopbacker/CRNNoise` under the [BSD-3-Clause license](App/Loopbacker/Resources/RNNoise-LICENSE.txt).

Echo cancellation vendors [webrtc-audio-processing](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing) (the freedesktop/PulseAudio fork of Chromium's WebRTC audio processing module, tag `v2.1`) in `App/Loopbacker/CWebRTCAEC` under [BSD-3-Clause](App/Loopbacker/CWebRTCAEC/LICENSE-webrtc-audio-processing.txt), plus the `abseil-cpp` subset it pulls in under [Apache-2.0](App/Loopbacker/CWebRTCAEC/LICENSE-abseil.txt).

REAPER JSFX hosting vendors [JoepVanlier/ysfx](https://github.com/JoepVanlier/ysfx) in `App/Loopbacker/CYSFX` under [Apache-2.0](App/Loopbacker/Resources/YSFX-LICENSE.txt), plus Cockos WDL (EEL2, LICE, SWELL) under a [zlib-style license](App/Loopbacker/Resources/WDL-LICENSE.txt).

The bundled Airwindows library vendors [baconpaul/airwin2rack](https://github.com/baconpaul/airwin2rack) (~500 effects) in `App/Loopbacker/CAirwindows` under [MIT](App/Loopbacker/CAirwindows/LICENSE.md).
