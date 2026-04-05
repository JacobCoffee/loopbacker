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
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="macOS 14+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-FSL--1.1--MIT-blue" alt="FSL-1.1-MIT"></a>
</p>

---

<p align="center">
  <img src="docs/screenshot.png" alt="Loopbacker screenshot" width="800">
</p>

Loopbacker creates a virtual audio device on macOS that captures audio from any app and makes it available as a mic input. Route desktop audio into Discord, OBS, Zoom, or any recording app. It also has a full audio effects chain for broadcast voice processing, and a soundboard for playing audio clips through the virtual device.

## Features

**Audio Routing**

- Virtual stereo loopback device (48kHz / 32-bit float)
- Route any input device to the virtual output
- Monitor output (hear yourself through speakers)
- Per-channel routing with visual cable connections
- 8 independent virtual loopback devices
- Scenes system for saving/loading routing configs

**Effects Chain** (9 real-time DSP effects, all processed on the audio thread)

- Noise Gate -- soft expander with configurable threshold
- 5-band Parametric EQ -- draggable frequency response curve, highpass/peaking/shelf filters
- Compressor -- linked stereo detection, adjustable ratio/threshold/makeup
- De-Esser -- bandpass sidechain targeting 4-8kHz sibilance
- Chorus -- modulated delay line with stereo LFO
- Pitch Shift -- -12 to +12 semitones, dual-head overlap-add
- Reverb -- Freeverb algorithm (8 comb filters + 4 allpass diffusers)
- Delay -- echo with feedback + soft-clip safety
- Limiter -- brick-wall peak limiter, always last in chain

12 factory presets: Broadcast Masculine Voice, Podcast Clean, Radio Announcer, Chipmunk, Deep Voice, Robot, Telephone, Cathedral, Dreamy, Space Station, and more. Save your own presets, import/export as JSON to share with others.

The EQ settings match [jtrv's EasyEffects Masculine NPR Voice preset](https://gist.github.com/jtrv/47542c8be6345951802eebcf9dc7da31) -- the same signal chain used by podcasters and streamers on Linux, ported to native macOS with zero dependencies.

**Soundboard**

- Play audio files (MP3, WAV, M4A, AIFF, FLAC, CAF) through the virtual device
- Add individual files or scan an entire folder
- Drag and drop audio files onto the grid
- Multiple simultaneous sounds (CoreAudio mixes them on the device)
- Global volume control
- Sounds appear in Discord/Zoom/OBS as if they're your mic

**UI**

- Three tabs: Routing, Effects, Soundboard
- Snaking pipeline view with animated cable connections
- Adaptive light/dark theme with in-app toggle
- Menu bar quick access panel

## How it works

```
Mic / App Output                        Discord / OBS / Zoom
       |                                       ^
       | capture                               | reads as mic input
       v                                       |
   [ Effects Chain ]                           |
   Gate > EQ > Comp > DeEss >                 |
   Chorus > Pitch > Reverb > Delay > Limiter  |
       |                                       |
       v                                       |
   +---+---------------------------------------+---+
   |              Lock-free Ring Buffer             |
   +------------------------------------------------+
                  Loopbacker Virtual Device
```

A CoreAudio HAL plugin provides the virtual device. The SwiftUI app handles routing, effects processing, and driver installation. All DSP runs on the real-time audio thread with no allocations or locks.

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

1. Open **Loopbacker.app** and click **Install Driver** (requires admin).
2. Add your microphone as a source in the **Routing** tab.
3. Connect source channels to output channels by clicking the connector dots.
4. In your chat/recording app, select **Loopbacker** as the input device.
5. Switch to the **Effects** tab to enable broadcast voice processing.
6. Switch to the **Soundboard** tab to play audio clips through the virtual device.

## Project structure

```
loopbacker/
├── Driver/          CoreAudio HAL plugin (C++17, CMake)
│   └── src/         Lock-free ring buffer, driver vtable, device management
├── App/             SwiftUI companion app (Swift 5.9)
│   └── Sources/
│       ├── Models/      AudioSource, AudioRoute, EffectsPreset, SoundboardItem
│       ├── Services/    AudioRouter, AudioEffectsChain, SoundboardPlayer
│       └── Views/       ContentView, EffectsView, SoundboardView, ...
├── scripts/         Install/uninstall helpers
└── docs/            Architecture docs
```

## Requirements

- macOS 14+ (Sonoma or later)
- Apple Silicon or Intel (universal binary)
- CMake 3.20+

## License

[FSL-1.1-MIT](LICENSE) -- free to use for any non-competing purpose, converts to MIT after 2 years.
