# Hushnote

A native Apple Silicon Mac meeting recorder. Capture system audio and an optional microphone, process speech locally, review speaker-labelled transcripts, and save one Markdown note directly to a chosen folder. No meeting attendee, login, video frames, or cloud inference.

## Run

Open `dist/Hushnote.app` (or the installed copy in Applications). Hushnote appears in the Dock while idle or processing; clicking its Dock icon reopens the window. Closing the window keeps the app running. **Option–Command–R** starts/stops recording from anywhere. When recording starts, the window and running-app Dock icon hide; the Dock icon returns when recording stops without reopening the window. A shortcut you have pinned to the Dock, macOS privacy indicators and the menu-bar icon may remain visible; universal invisibility during whole-screen sharing is not promised.

1. Open Settings. Download the speech models once if they are not already installed. Optionally install the 1.12 GB summary model. Downloads require internet; meeting processing does not.
2. Choose a destination folder. Notes are saved at its root. Project names appear in filenames and YAML metadata.
3. Set a meeting title/project. Enable the microphone to include your own voice; system audio alone usually contains only the other participants. Use headphones to avoid microphone echo.
4. Start recording and respond to macOS permission prompts yourself. Stop using the shortcut or menu bar.
5. Review notes, rename speakers, edit the summary, then Export .md. Timestamps in the notes jump to that point in the transcript. Audio exports are compact 48 kbps AAC; PCM recovery checkpoints remain in the app's local storage.

Google Drive works through **Google Drive for desktop**. Paste a folder link for reference and choose the corresponding local synced folder once. Hushnote writes normal files there while offline; Drive handles uploading/syncing when connected. A web folder link alone is not filesystem access. Hushnote does not use Google APIs, OAuth, or a cloud processing service.

## Memory and reliability

- Native AppKit/SwiftUI shell, with no Electron or embedded browser.
- Audio callbacks copy Float32 audio into preallocated single-producer/single-consumer C rings. Four seconds of mono input per source; overflow is counted and stops the session with a warning.
- Audio is resampled and written on a utility queue, drained every 250 ms (about four wakeups per second per track), as approximately 30-second 16 kHz mono PCM CAF checkpoints. Audio memory does not grow with meeting duration.
- Recording health is polled every 2 s without blocking on disk writes; free space every 30 s. Nothing in the UI republishes on a timer while recording, and the menu-bar menu is refreshed only when opened.
- The meeting list reads only manifest headers. A meeting's transcript loads when it is opened, so memory does not grow with meeting history. Edits apply immediately and are written once typing pauses, off the main thread and in order.
- Diarization and transcription run in separate worker processes, sequentially. The recorder never links the speech SDK. Each worker exits before the next model loads.
- A new recording takes priority over ongoing processing. Starting with the button, menu bar or shortcut cancels processing, waits for its worker to exit, then begins capture. Earlier meeting checkpoints remain resumable.
- Parakeet TDT v2 English, via FluidAudio/Core ML and CPU + Apple Neural Engine. This is a different Parakeet variant from Handy's Unified model. ASR concurrency is one.
- Optional Qwen 2.5 1.5B Q4_K_M summaries run via bundled llama.cpp on the GPU (Metal), falling back to four CPU threads if the GPU run fails. Metal keeps the weights file-backed instead of repacking them into ~1.1 GB of anonymous memory. Context is capped at 4096 tokens; long transcripts are summarized in ~9 KB sections and combined.
- Without the summary model, notes explicitly contain selected transcript excerpts rather than pretending to be a generative summary.
- Completed transcription checkpoints persist atomically. Interrupted sessions can be resumed. Output-route changes reconnect system capture; microphone reconfiguration or sleep safely ends the session and records a warning.
- Export uses streaming conversion and never loads a whole meeting into an audio array. Existing exported notes are preserved with a new filename.

Actual memory measurements and validation results are recorded in `VALIDATION.md`. Targets are not guarantees. Very long transcripts and Core ML compilation still require additional memory.

## Requirements and data

Apple Silicon, macOS 14.2+, system audio permission, and optional microphone permission. No Accessibility, camera, calendar, or screen capture permission is requested. Protected or otherwise unavailable audio cannot be guaranteed to be capturable.

App data: `~/Library/Application Support/Hushnote/`. `Models/` contains model files. `Sessions/<id>/` contains audio checkpoints and an atomic `session.json`. Audio and notes use ordinary local files, not custom application encryption. Your Mac's filesystem/FileVault protection applies. Google Drive can sync only the destination you deliberately choose.

Speaker names are editable per meeting. Automatic voice identity across meetings and automatic meeting detection are future work. Simultaneous speech and speakerphone echo can reduce speaker accuracy. Summaries are AI-generated and should be reviewed against the timestamped transcript.

This is a development build, signed ad hoc locally. Distribution to other Macs requires Developer ID signing and notarization; this checkout does not contain signing credentials.

## Build and verify

Swift 6.1+ command-line tools and internet for fetching dependencies:

```sh
bash scripts/fetch-summary-runtime.sh
swift run --jobs 4 HushnoteChecks
bash scripts/build.sh
```

The summary runtime is pinned to llama.cpp b11429 and verified against the publisher's SHA-256. The app verifies the Qwen model's SHA-256 before installing it. `Package.resolved` pins FluidAudio 0.17.7.

For a real audio integration check without recording anything:

```sh
dist/Hushnote.app/Contents/MacOS/Hushnote --audio-check /absolute/path/to/short-audio.wav /absolute/path/to/check-output
```

The worker also exposes `prepare <model-root>`, `fixture <audio-under-35s> <output-directory>`, `diarize <session.json> <model-root>`, `transcribe <session.json> <model-root>` and `inspect <session.json>`. `prepare` downloads models; `diarize`/`transcribe` load only local files and fail locally if missing. Checks use a native executable because this Mac has command-line tools without XCTest.

## Design assets

`design/` holds the source artwork: `Hushnote_AppIcon.svg` and `Hushnote_Logo.svg`. Regenerate the derived files after the artwork changes:

```sh
swift scripts/make-icon.swift            # Resources/AppIcon.icns, 16–1024 px on the macOS 824/1024 icon grid
python3 scripts/make-logo-geometry.py    # Sources/Hushnote/LogoGeometry.swift
```

The app draws the logo as native vector geometry. In the sidebar the H follows the theme's ink colour (cream in dark mode, as in the artwork) and the pill stays vermilion. The menu-bar icon uses the same mark with the pill knocked out when idle, filled while processing, and red while recording. The theme's ink, cream and signal colours are the artwork's exact `#1C1B18`, `#F5EFE5` and `#F74D21`.

## Implementation

Hushnote's capture, model lifecycle, UI and export are implemented independently, using Apple's public Core Audio APIs and FluidAudio's open-source Core ML runtime.

## Dependencies and model notices

- FluidAudio 0.17.7 — Apache 2.0; its dependencies retain their own notices.
- Parakeet TDT 0.6B v2 — NVIDIA, CC BY 4.0; Core ML conversion by FluidInference. Model: https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml
- Speaker models — https://huggingface.co/FluidInference/speaker-diarization-coreml ; preserve upstream model notices when distributing model bundles.
- llama.cpp b11429 — MIT: https://github.com/ggml-org/llama.cpp
- Qwen 2.5 1.5B Instruct — Apache 2.0: https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF

Models are fetched as separate assets rather than included in the app bundle.
