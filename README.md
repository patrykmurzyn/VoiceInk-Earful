<div align="center">
  <img src="VoiceInk/Assets.xcassets/AppIcon.appiconset/256-mac.png" width="180" height="180" />
  <h1>VoiceInk-Earful</h1>
  <p>A community fork of <a href="https://github.com/Beingpax/VoiceInk">VoiceInk</a> that adds system-audio capture and speaker-labeled dual-source transcription.</p>

  [![License](https://img.shields.io/badge/License-GPL%20v3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
  ![Platform](https://img.shields.io/badge/platform-macOS%2014.4%2B-brightgreen)
  ![Upstream](https://img.shields.io/badge/upstream-Beingpax%2FVoiceInk-lightgrey)
</div>

---

> **This is a fork, not the original project.** For the full VoiceInk experience —
> documentation, screenshots, the official signed/notarized build, and commercial
> licenses — head to [tryvoiceink.com](https://tryvoiceink.com) and the upstream repo at
> [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk). All credit for VoiceInk itself
> goes to [Pax](https://github.com/Beingpax).

This fork builds on VoiceInk to close one specific gap: **VoiceInk only records the
microphone, so anything playing through your speakers — the other side of a call, a
podcast, a video — never reaches the transcription**. VoiceInk-Earful adds two new
capture modes that fix this while keeping everything local on Apple Silicon via
[whisper.cpp](https://github.com/ggerganov/whisper.cpp).

## What this fork adds

Three capture modes selectable in **Settings → Audio Input → Audio Source**:

| Mode | What it records | Notes |
| --- | --- | --- |
| 🎤 Microphone | input device only | Identical to upstream |
| 🔊 System Audio | speakers / app output | Uses [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) (`SCStream` with `capturesAudio = true`) |
| 👥 Mic + System | both, in parallel | Each track is transcribed independently and segments are interleaved by timestamp, prefixed with `[ME]:` (mic) or `[THEM]:` (system) |

Example transcript from **Mic + System** mode while on a call:

```
[THEM]: So how did the deployment go this morning?
[ME]: Pretty smoothly, the rollback path we set up last week paid off.
[THEM]: Did the new metrics show up correctly?
[ME]: Yes, dashboards picked them up within a couple of minutes.
```

When System Audio or Mic + System mode is active, the existing **Pause Media** and
**Mute System Audio While Recording** behaviors are automatically suppressed — silencing
the audio we are trying to capture would be self-defeating — and the corresponding
toggles in *Settings → Experimental* are visually disabled to reflect that.

Everything else from upstream — local Whisper models, hotkeys, paste-at-cursor,
power modes, history, dictionary, AI enhancement — is unchanged.

## Requirements

- macOS 14.4 or later
- Apple Silicon recommended (for local Whisper performance)
- **Screen & System Audio Recording** permission, granted on first use of System Audio
  or Mic + System modes (macOS will prompt; allow in *System Settings → Privacy & Security*)
- A locally-downloaded Whisper model — Mic + System mode currently requires Whisper

## Building

This fork inherits upstream's build system. For a build with no Apple Developer account:

```bash
make local
```

Full details, alternative build targets, and prerequisites are in [`BUILDING.md`](BUILDING.md).

### Optional: stable code signing for development

The default `make local` uses ad-hoc signing, which produces a different code identifier on
every build. macOS TCC then **forgets your Screen Recording grant after every rebuild** —
painful when iterating on ScreenCaptureKit features.

This fork ships a helper that creates a self-signed code-signing identity once, imports it
into your login keychain with code-signing trust, and re-signs the built app with it:

```bash
./tools/sign-local.sh
```

After the first run, every subsequent `make local && ./tools/sign-local.sh` produces a
binary with a stable `Authority` — macOS keeps the TCC grant across rebuilds. The cert
is named `VoiceInk Local Dev` in your login keychain and can be removed any time via
Keychain Access.

## Diff from upstream

The fork lives as four commits on top of `Beingpax/VoiceInk` `main`:

1. **Introduce AudioCaptureSource protocol for the recorder** — non-functional refactor
2. **Add system audio capture via ScreenCaptureKit**
3. **Add mixed mic + system mode with speaker labels**
4. **Add helper script for stable local code signing**

No upstream files are renamed or removed. The new capture sources slot in through a small
`AudioCaptureSource` protocol shared with the existing microphone recorder, so future
rebases against upstream stay tractable.

## License

GPL v3.0, inherited from upstream VoiceInk — see [`LICENSE`](LICENSE). Forks and
distributions are welcome under the same terms.

## Credits

- **VoiceInk** by [Pax](https://github.com/Beingpax) — the entire app this is forked from.
- **whisper.cpp** by [Georgi Gerganov](https://github.com/ggerganov/whisper.cpp) and contributors.
- **FluidAudio**, **ScreenCaptureKit**, and every other upstream dependency listed in the
  [upstream README](https://github.com/Beingpax/VoiceInk#acknowledgments).
