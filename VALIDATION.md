# Development build validation — 2026-10-15

Host: Apple M2 Pro, 16 GB unified memory, macOS 26.6.1. Swift 6.1.2 command-line tools. Native arm64 release app, ad-hoc signed locally. No Xcode installation or Handy dependency is required to run it.

## Passed

- Release compilation and strict/deep code-signature verification.
- Core regression executable: session JSON round-trip; YAML title quoting; Markdown audio URL escaping; timestamp and speaker rename retention; path traversal rejection; conservative overlap labelling; transcript excerpts; fixed-size C ring overflow accounting, stereo downmix and wraparound.
- Real audio import, 16 kHz PCM conversion and tail handling, capture ring/resampler, a recording longer than 30 seconds crossing checkpoint rollover, AAC compression, Markdown export and relative audio links. The capture-consumer test repeats an actual public speech fixture; it does not access the microphone or system tap.
- Local Pyannote/WeSpeaker speaker separation on the public 21.44-second recorded speech fixture shipped with FluidAudio. Produced speaker turns with no application error. Multi-person meetings have not been accuracy-benchmarked.
- Local Parakeet TDT v2 transcription on the same fixture. Produced an intelligible timestamped transcript. Unknown tail speech remains conservatively labelled Meeting audio.
- The packaged worker loads the installed local models. The microphone-track path labels speech You and uses word timestamps rather than dating all speech to the beginning of a 30-second chunk.
- Re-processing a completed transcript retains checkpoints and avoids loading ASR models again.
- New recording commands are enabled during processing and cancel/join the prior operation before starting capture, preserving the single-model lifecycle. This handoff is implemented and code-reviewed; its final capture step still requires the live permission test below.
- Summary model SHA-256 verification and actual local Qwen generation through the bundled llama.cpp runtime. Test output summarized the source request without executing any instructions contained in that source.
- Packaged llama.cpp version and dylib lookup verified. Third-party licenses are included. Packaged worker resource lookup points to Contents/Helpers, with a relative link to the signed Resources bundle.
- The app launches and exposes its native title, project, recording, microphone, import and settings controls. Full screenshot-driven UI inspection was interrupted by crashes in SkyComputerUseService, not Hushnote; no Hushnote crash report was found.

## Observed memory

These are measurements on this Mac, not fixed ceilings. Core ML model compilation and system caches can behave differently on another machine. Inference checks occurred while development tooling was also running.

| Check | Observed resident memory |
| --- | --- |
| Native app after launch | approximately 74 MiB; fell further while idle |
| Capture-consumer + import/export command | approximately 19 MiB peak |
| Speaker separation command | approximately 180 MiB peak |
| Parakeet transcription command | approximately 457 MiB peak |
| Local summary command, including its child runtime | approximately 1.75 GiB peak |

Command peaks come from macOS `/usr/bin/time -l` maximum resident set size (bytes converted to MiB/GiB). App observations come from `ps` RSS. The capture-consumer figure is not a measurement of a live Core Audio tap, microphone engine or complete GUI recording session. The speaker, ASR and summary processes run sequentially and exit after each stage; their model allocations are not deliberately kept resident together.

The signed app is approximately 38 MB. Installed model files total approximately 1.5 GB on disk. Internet is used for explicit model setup only; the tested inference entry points load local files.

## Redesign and optimisation pass — 2026-10-15

Same host. The pre-change build is kept at `.cache/previous-builds/Hushnote-20261015-122249.app`, and the pre-change sources at `.cache/original-2026-10-15/`.

| Check | Before | After |
| --- | --- | --- |
| Summary of one 9 KB section (llama-completion alone, identical output) | 27.1 s, 1,144 MiB footprint (CPU) | 3.6 s, 205 MiB footprint (Metal) |
| Summary of a ~55 KB synthetic transcript, `--summary-check` end to end | 411 s, 2,134 MiB peak RSS | 27 s, 1,328 MiB peak RSS |
| Audio writer wakeups while recording | 25 per second per track | 4 per second per track |
| Main-thread work while recording | menu rebuilt and all views republished every second; health check waited on the disk-writer queue | none on a timer; health read without locks on the writer; menu refreshed only when opened |
| Editing a title, speaker or note | full manifest encoded and written on every keystroke, on the main thread | applied in memory; one ordered background write after typing pauses |
| Meeting list | every transcript decoded at launch, on the main thread, and kept in memory | headers decoded in the background; one meeting loaded when opened |

The end-to-end "before" run briefly overlapped a compile, so read the speed-up as roughly 14–15x. The synthetic transcript is generated text, not a meeting recording. The CPU path repacks Q4_K weights into anonymous memory, which is why its footprint is close to the model size. Metal reads them from the mapped file. If the Metal run fails, the app retries on CPU.

Passed after the change: the core regression executable (now including header-only listing and parsing of loose model Markdown), the real-audio `--audio-check` (19 MiB peak; the simulated producer now feeds at 8x real time instead of ~25x, matching the 250 ms drain), packaged diarize/transcribe on the public fixture with progress streamed through a pipe (first line 0.9 s after launch, same 3 passages and 2 speakers as before), packaged Metal summary generation, and release signing. The worker code is unchanged apart from its progress output. This run peaked at 253 MiB for speaker separation and 497 MiB for transcription.

The redesigned views were reviewed as offscreen renders in light and dark (`swift build && .build/debug/Hushnote --snapshot <dir>`; this harness is compiled only into debug builds). The redesigned GUI was not launched against a live recording in this pass, because an earlier Hushnote instance was running and holds the ⌥⌘R shortcut.

### Review fix: stale notes after quick meeting switching

Leaving a meeting queued its manifest save on a background queue, while opening a meeting read the manifest directly from disk. Returning to a meeting before its save landed could load the pre-edit notes, and the next edit would save over the queued write, losing the earlier edits. `ManifestWriter` (now in HushnoteCore) is the single path for manifests: reads and recovery run on the same serial queue as saves, after every queued write. A new core check covers it. In a 1,000-trial repro on a 98 KB manifest, a read issued while a save was queued was stale 1000/1000 times on the old direct path and 0/1000 through the writer. The repro reads immediately, which is the worst case. In the app, the window lasts as long as the queued writes take.

### Brand assets

The app icon and logo come from `design/`. The bundle now ships `AppIcon.icns` (10 sizes, 16–1024 px), referenced by `CFBundleIconFile`. Measured bounds put the icon body on the macOS grid at every size, with 100–101 px margins at 1024 px and 2 px at 16 px. On macOS 26.6.1, Launch Services returns it at full size without the plate macOS adds to non-conforming legacy icons. The sidebar logo and the three menu-bar states (idle, processing, recording) were reviewed as renders on light and dark grounds. The logo generator reproduces the committed geometry exactly. Core checks pass and the rebuilt app's signature verifies.

### Dock visibility and fresh installation

The new icon was present in `dist/` but the installed Applications copy predated it. Separately, `LSUIElement=true` and `.accessory` activation deliberately excluded the app from the Dock. Build 2 now launches as a regular foreground application with `LSUIElement=false`. The Dock remains available after closing the window; clicking the icon reopens it. On recording start, the window is ordered out and activation switches to accessory; on stop, regular activation is restored without explicitly reopening or activating the window. A user-pinned Dock shortcut may remain. Added native About, Hide and Quit application-menu commands for the regular-app presentation.

Passed: release build, core regression checks including save ordering, strict/deep signature verification, extraction of all ten icon sizes, byte-for-byte comparison of the installed executable and icon to the fresh build and source icon. The installed `/Applications/Hushnote.app` was launched and its live window inspected. The application menu exposes About/Hide/Quit; the About panel visibly displays the new icon and version 0.1.0 (2). Launch Services reports the installed process as `type="Foreground"`, version 2. Older idle instances were stopped; previous app bundles were preserved under `.cache/previous-builds/installed.*`. The Dock accessibility inspection timed out, so the actual Dock tile was not visually inspected. Recording-triggered activation transitions remain code-reviewed rather than live-capture tested; no recording or capture-permission prompt was initiated for this update.

### Release 0.1.0 packaging

Built from a clean tree at the tagged commit. The bundle was scanned for the builder's user name, home directory, repository path and hostname before packaging: none present. The one place the build path appeared (SwiftPM's resource-bundle fallback in the worker) is overwritten with an inert string by `scripts/build.sh`, which also refuses to package a bundle that still contains the home or repository path. The zip is made without extended attributes. From the unzipped copy: the signature verifies, 28 files and 16 symlinks match the build, `--audio-check` passes, and the packaged worker produces the same 3 transcript passages and 2 speakers as before. The release is marked pre-release because live system-audio and microphone capture is still unverified.

## Still requires a consented live test

No macOS microphone/system-audio permissions were accepted by the agent, and no private meeting was recorded. Start a short test recording in Hushnote, respond to the macOS prompts, play meeting audio, speak briefly, stop and review both tracks. This is needed to verify the actual tap, simultaneous microphone capture, current output device, routing, and permission behavior on this Mac.

Zoom, Google Meet, Teams, Slack, Discord, Telegram, WhatsApp and FaceTime have not each been exercised in live calls. Sleep/device-change recovery is implemented but not yet verified during a real meeting. Full-screen sharing may include system privacy indicators and the menu-bar icon; universal invisibility is not claimed.

Google Drive folder selection/link mapping is implemented through Drive for desktop. No folder was selected and no file was uploaded to the user's Drive during development. A user-provided link alone cannot authorize a filesystem write or map every Drive folder automatically.

The app is a first development build, not a notarized public release. Automatic meeting detection, persistent voice identity across meetings, custom app-level audio encryption and fully automated Drive-link resolution are not included. See README.md for the implemented workflow and build commands.
