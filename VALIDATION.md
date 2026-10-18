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

### Silent audio-device handoffs — build 3

The two untranscribed user recordings had been stopped by `AVAudioEngineConfigurationChange`; the old failure callback explicitly disabled automatic processing. Build 3 replaces that path with independent input/output reconnection. Default-input, default-output and system-tap format changes are observed. The affected track is drained/checkpointed before reconnecting with the current format; the other track remains active. Notification bursts are coalesced for 200 ms. Temporarily missing devices retry at 250 ms, 500 ms, 1 s, 2 s and then at most every 5 s, without changing recording state, opening the window, setting an alert, or issuing a notification. The session origin uses monotonic uptime and never resets during reconnection, including switches before the first 30-second checkpoint. Old graph callbacks are rejected by per-graph/session generation; late checkpoint callbacks are bound to their recording UUID. Stop cancels retries before tearing down graphs. Prolonged hardware outages are retained as post-meeting diagnostics rather than hidden or presented as routine switch popups. Genuine write/storage failures still stop safely and now attempt automatic processing of saved audio when enabled; explicit quit/sleep deferral is unchanged.

Passed: release compilation without warnings, 20 repeated core regression runs, permission-free simulated route handoffs through the real TrackSink/ring/resampler/checkpoint writer and AAC/Markdown exporter. The integration check exercises 48 kHz, 44.1 kHz and 16 kHz input formats, 100-event output-change bursts, an unavailable microphone followed by successful retry, independent track continuity, non-overlapping offsets and preserved export gaps. The packaged handoff check took 0.95 s and peaked at 21,938,176 bytes RSS (approximately 21 MiB); this measures the simulation, not a live hardware recording. The packaged real-speech import/ring/checkpoint/export check also passes. Its initial sandboxed run could not access the macOS codec service; repeating with normal codec-service access passed. No microphone or system-tap capture was initiated for these checks, and no user audio was used as a test fixture. Existing interrupted recordings have not been changed by this fix.

The packaged speech worker also processed the public 21.44-second fixture offline through diarization and transcription, completing 1/1 checkpoint with 3 passages and 2 speaker labels. Core ML emitted an E5RT tensor-shape diagnostic during that check, but the worker completed successfully. Build 3 was installed at `/Applications/Hushnote.app`, byte-verified against `dist/`, strict/deep signature-verified and opened successfully. The previous installed bundle is recoverable under `.cache/previous-builds/installed.EsBY6x/Hushnote.app`.

Live Bluetooth/USB/internal-device handoffs still need an end-to-end hardware trial. A physical device handoff can briefly withhold samples; the implementation preserves that elapsed gap instead of claiming it can recover audio macOS did not deliver. This update does not claim sample-perfect gapless hardware switching.

### Forgotten-recording reminder

Quiet is inferred from loudness (RMS of the 16 kHz audio, threshold about -44 dBFS, one reading per 250 ms drain), with 1 s of sustained sound required and a 2 s gap rule, so chimes and key clicks do not count. The policy is a pure state machine with core checks for: no reminder before 10 quiet minutes, one reminder (not repeated), withdrawal when sound resumes, auto-stop 20 minutes after an unanswered reminder (30 minutes after the meeting ended), no automatic stop across 9 hours of continuous audio (hourly nudges only), snooze on "Keep recording", and both settings. `--audio-check` also feeds the real speech fixture and 5 s of digital silence through the real sink: speech registers, silence does not. Metering added 0.08 s of user CPU across an 11 s run.

Not yet verified: the notification banner and its buttons, and the first-use permission prompt, which need a live session in the installed app. Thresholds (10 / 20 / 30 minutes, -44 dBFS) are reasoned defaults, not tuned on real meetings; a room with constant loud background noise would never read as quiet and would only receive the hourly nudge.

### Choosable summary engines

Core checks cover the privacy rules (loopback-only counts as local, including rejecting `127.0.0.1.example.com`, which an early version wrongly accepted), per-engine consent, settings that survive missing, unknown and future fields, and the response formats of OpenAI Responses, OpenAI-compatible chat completions and the Anthropic Messages API, including refusals, truncation and error bodies.

With the packaged app and `--summary-check`:
- **Model file:** the bundled Qwen file chosen as a custom model, prompted through its own chat template (`-cnv -st --jinja`): 2.2 s, correct dates and decisions. It attributed one action item to the wrong person, a small-model limitation.
- **ChatGPT:** one live summary through the user's ChatGPT plan via Codex 0.160.1: 9.6 s, accurate, timestamped.
- **OpenAI, Anthropic and an OpenAI-compatible server:** tested against a local stand-in server that recorded each request. Paths, auth headers, `anthropic-version`, the server-side fallback header and `fallbacks: "default"`, `max_tokens`, `store: false`, and the system and source prompts were all as intended. A rejected key returned "Anthropic rejected the API key." No real OpenAI or Anthropic API call was made (no keys were used).

Settings were reviewed as renders in light and dark. Not yet verified live: the in-app **Continue with ChatGPT** browser sign-in (this Mac was already signed in), Keychain prompts after an update, and real Ollama or LM Studio servers (neither is installed here).

### Review fixes after 0.1.4

1. **Redirects could bypass summary consent.** The HTTP session followed redirects, so a server on this Mac could have answered with a redirect and had the transcript (and any key header) re-sent to a host the user never approved. Reproduced on the released 0.1.4 with two local stand-in servers: the redirect target received the full request (899 bytes, transcript included). Redirects are no longer followed for any HTTP engine; the same test now returns an explanatory error and the target sees nothing.
2. **Engine tests and cancellation shared one global process slot.** Cancelling stopped the newer process and left the older one running untracked, so a model could stay in memory. Cancellation is now tied to each run's own task and terminates exactly that process; the global slot is gone. Engine tests refuse to start while recording, starting or processing, and a recording cancels a test in progress. The sign-in cancels only its own process. `--cancel-check` runs two model processes at once and checks that cancelling one leaves exactly the other, and cancelling it leaves none (passes; I did not run it against the old code).
3. **Audio-write failures still triggered processing.** The health-error stop used the default. Stops that carry a warning now never process unless a caller explicitly asks, so a future call site can't miss it.
4. **Old notification buttons could stop a newer recording.** Notifications now carry the recording they belong to; an action for any other recording, or none, is ignored (core check). Quiet and long-recording reminders are withdrawn for every recording when one ends, and leftovers from an earlier launch are cleared at start.

Not verified live: notification behaviour in the installed app (banner, buttons, withdrawal), which needs a real recording.

### Second review round

- **Processing could overlap an engine test.** Starting a test and then processing left both running, which I reproduced. Processing and recording now cancel a running engine test and wait until its model process has exited before they start. A new `--overlap-check` starts a test, then an operation, and asserts no model process is running when the operation begins: it failed on the code as it stood (1 process still running) and passes after the fix, three runs in a row, with no stray processes afterwards.
- **A failed final save still allowed processing.** On a normal stop a failed save only set the error message and execution continued into processing, which reads the saved manifest. Processing now requires a successful save; this is a core check (`saved: false` never starts).

### Third review round

A cancelled operation could still start after waiting for an engine test to end (reproduced with `Task.isCancelled == true` inside the operation). `perform` now checks for cancellation after the wait and before starting. `--overlap-check` gained this case: it failed on the code as it stood ("A cancelled operation still started") and passes after the fix, three runs in a row.

## Still requires a consented live test

No macOS microphone/system-audio permissions were accepted by the agent, and no private meeting was recorded. Start a short test recording in Hushnote, respond to the macOS prompts, play meeting audio, speak briefly, stop and review both tracks. This is needed to verify the actual tap, simultaneous microphone capture, current output device, routing, and permission behavior on this Mac.

Zoom, Google Meet, Teams, Slack, Discord, Telegram, WhatsApp and FaceTime have not each been exercised in live calls. Sleep/device-change recovery is implemented but not yet verified during a real meeting. Full-screen sharing may include system privacy indicators and the menu-bar icon; universal invisibility is not claimed.

Google Drive folder selection/link mapping is implemented through Drive for desktop. No folder was selected and no file was uploaded to the user's Drive during development. A user-provided link alone cannot authorize a filesystem write or map every Drive folder automatically.

The app is a first development build, not a notarized public release. Automatic meeting detection, persistent voice identity across meetings, custom app-level audio encryption and fully automated Drive-link resolution are not included. See README.md for the implemented workflow and build commands.
