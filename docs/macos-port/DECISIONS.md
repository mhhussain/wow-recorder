# Decisions (append-only)

Each entry: date, context, options considered, choice, reasoning. Never edit past entries; supersede them with a new entry.

---

## D-001 (2026-10-05) Remove the commented-out `node.js.yml` workflow

- Context: `.github/workflows/node.js.yml` is entirely commented out. GitHub treats it as an invalid workflow and reports a failed run on every push, which pollutes CI status for this branch.
- Options: (a) leave it, (b) delete it, (c) rewrite it as the macOS CI workflow.
- Choice: (b) delete now; the macOS CI workflow is added separately as `macos-ci.yml` in phase 3.
- Reasoning: upstream Windows CI is not preserved in this fork, and a red run on every push hides real failures.

## D-002 (2026-10-05) Fixture-to-scenario mapping source

- Context: `tests/fixtures/combatlogs/README.md` says only "Combat log file name is the description of the file." The files are byte-identical to upstream's `tests/logs/`, and upstream's `tests/src/<flavour>/<name>.py` integration definitions state the expected outcome (record or not, expected file name) for each log.
- Choice: use the file names plus the upstream `.py` definitions as the scenario map. Unit tests use small excerpts extracted to `tests/fixtures/excerpts/`; full files back an optional slower integration test.
- Reasoning: the `.py` files are the upstream author's ground truth for these exact logs, which is stronger than inferring from names.

## D-003 (2026-10-05) Quality gates start from a red baseline

- Context: at fork time `tsc --noEmit` reports 55 errors (mostly library typings and missing `release/app` modules), ESLint reports 52 errors (mostly `no-explicit-any` and react-hooks v7 compiler rules in renderer code), and all 7 jest suites fail to load (Electron import, `baseUrl` paths not mapped in jest). Webpack builds with `transpileOnly`, so upstream never type-checks.
- Choice: make typecheck, lint, and unit tests real CI gates by fixing configuration (`skipLibCheck`, jest `moduleDirectories` and an Electron stub, vendored `noobs` types) and downgrading the pre-existing renderer-only lint rule categories to warnings rather than rewriting unrelated renderer code.
- Reasoning: gates must be green to be useful, and rewriting renderer code that the port does not touch is out of scope and risky.

## D-004 (2026-10-05) Recording backend: native ScreenCaptureKit helper (option c)

- Context: upstream records through `noobs`, a Windows-only libobs binding. Full audio/video parity is required: game or system audio, microphones, hardware encoding, the replay-buffer model (`startBuffer` / `convert(offset)` / `stop`), six audio tracks, fragmented MP4.
- Options evaluated:
  - **(a) OBS/libobs on macOS.** Verified that `noobs` calls a `convert` procedure with `offset_seconds` on `replay_buffer` and listens for a `converted` signal; upstream OBS (`plugins/obs-ffmpeg/obs-ffmpeg-mux.c`, master) only registers `save()` and `get_last_replay()`. So this path needs a patched libobs fork built for macOS arm64 (CMake, obs-deps, plugins as bundles), plus porting `noobs` C++ (`windows.h`, `HWND` preview, D3D11 graphics module, WASAPI source IDs), plus packaging and signing libobs.framework and plugins inside Electron. Parity would be good (OBS's mac-capture uses ScreenCaptureKit; mac-videotoolbox exists) but it is the most work on the critical path and every iteration is a long native build on the runner. Not spiked: option (c) reached a green full pipeline first, and (a) is strictly more work for the same capture APIs.
  - **(b) ffmpeg as a spawned process.** Verified on the runner (`macos-ci` run 37261237609): ffmpeg 6.0 `-f avfoundation -list_devices` lists only microphones and app-specific virtual drivers (Jump Desktop, Microsoft Teams); there is no system audio device without installing a loopback driver such as BlackHole, which is a system-level install and fails the parity requirement. It also cannot do per-application audio and would need a separate pre-roll design.
  - **(c) Native helper using ScreenCaptureKit + VideoToolbox + AVFoundation.** Verified on the runner in the same run: compiles against SDK 27 on the first attempt; hardware H.264 and HEVC sessions accept constant-quality rate control; `SCStreamConfiguration` exposes `capturesAudio`, `excludesCurrentProcessAudio`, `captureMicrophone`; the self-test drives the real engine (encoder, six-track mixer, 60 s replay buffer, `convert(offset)`, fragmented-MP4 writer) with synthetic sources and produces files with the expected duration, codecs, six AAC tracks and per-track audio levels, decodable by ffmpeg.
- Choice: **(c)**, as a separate helper process (`wcr-capture`, Swift, JSON lines over stdio) driven by a TypeScript shim that implements the subset of the `noobs` API the existing `Recorder` uses.
- Reasoning: fastest route to full parity with the least change to the app (Recorder call sites and signal handling stay the same); a capture or encoder crash does not take down the Electron main process; buildable with only Xcode (no extra system tools); fully testable headless on the runner except for the permission-gated capture itself.
- Known gaps vs Windows (closest macOS equivalents):
  - Noise suppression (OBS RNNoise/Speex filter) becomes a simple noise gate on microphone sources.
  - Output-device selection for system audio does not exist: macOS captures the system mix (minus this app). Per-application capture is available.
  - No native preview or scene editor (libobs drew into a child HWND); chat overlay not composited. Secondary features.
  - "Game capture" and "window capture" both map to ScreenCaptureKit window capture of the WoW window; "monitor capture" maps to display capture.
  - Force SDR is implicit (capture is always SDR 8-bit 4:2:0).
- Unverified until on-device testing: real capture of the WoW window and audio, TCC attribution of the helper to the app, A/V sync under load.

## D-005 (2026-10-05) ffmpeg for post-processing

- Context: `VideoProcessQueue` cuts and remuxes with ffmpeg; upstream used `ffmpeg.exe` from `noobs`.
- Choice: `ffmpeg-static@5.3.0` as a devDependency; its arm64 macOS binary (verified Mach-O arm64, ffmpeg 6.0) is copied to `binaries/ffmpeg` at build time and shipped via `extraResources`.
- Reasoning: no system install, no Rosetta, stream-copy cutting needs nothing beyond a stock build.

## D-006 (2026-10-05) Classic flavours included

- Context: log parsing and activities for Classic and Era are platform-agnostic TypeScript.
- Choice: keep Classic/Era enabled; the macOS process poller and WoW window matcher recognise Classic clients by install folder and app name/bundle ID prefix. Unverified on device.
- Reasoning: near-zero cost.

## D-007 (2026-10-05) Packaging and signing

- Context: local arm64 `.app` only; no certificate, notarization, installer or auto-update. Apple Silicon will not run code whose signature was broken when electron-builder rewrote the bundle.
- Choice:
  - electron-builder `mac` target `dir` (arm64) producing `release/build/mac-arm64/WarcraftRecorder.app`; `asarUnpack: **/*.node`; Windows `nsis`/`win`/`publish` config removed.
  - `mac.identity: null` (electron-builder does not sign) plus an `afterPack` hook (`.erb/scripts/adhoc-sign.js`) that ad-hoc signs the Mach-O files in Resources (capture helper, ffmpeg, `.node`) and then the bundle with `--deep`, and verifies with `codesign --verify --deep --strict`.
  - No hardened runtime, so no entitlements are needed for microphone or screen capture. Info.plist gets `NSMicrophoneUsageDescription` (required, or macOS kills the process on mic access), `NSAudioCaptureUsageDescription` and `NSScreenCaptureUsageDescription` (harmless if unused), `LSMinimumSystemVersion 27.0`.
  - CI zips the app with `ditto -c -k --keepParent` (keeps framework symlinks and executable bits that a plain directory artifact upload would lose) and uploads it with 7-day retention.
- Consequence: TCC identifies ad-hoc signed apps by code hash, so each new build may need Screen Recording and Microphone re-granted (see MANUAL_TEST.md). A self-signed certificate would make grants stable but requires a keychain change on the owner's Mac; offered as an option, not done.
- Logs: application logs move from inside the bundle to `~/Library/Logs/WarcraftRecorder` (writing into a signed bundle breaks its seal and fails under /Applications).

## D-008 (2026-10-05) CI boot smoke test and helper integration test

- Context: real capture is TCC-gated, but two failure modes are testable without permissions: a mismatch between the TypeScript `configure` JSON and the Swift `EngineConfig`, and a packaged app that crashes on boot.
- Choice:
  - `src/__tests__/mac/HelperIntegration.test.ts` drives the real `binaries/wcr-capture` through `CaptureHelper` and `MacNoobs` with no capture sources (black frames, silent tracks), checks signals, file naming, and the file (1 H.264 + 6 AAC streams, expected duration). Runs on macOS after `npm run build:native`; skipped elsewhere.
  - `WCR_SMOKE_TEST=<dir>` boots the packaged app hidden, with user data and logs under `<dir>`, no Dock icon, tray, permission requests, first-run setup or WoW polling, then exits 0/1 based on uncaught errors, renderer load/crash, rendered content, helper running and encoder listing.
- Side effects on the runner Mac: none requested by the app. AppKit/Chromium may still write small per-app state for the bundle ID `org.WarcraftRecorder` under `~/Library` (for example Saved Application State); the app itself requests no permissions in this mode.

## D-009 (2026-10-05) WoW detection width fix and a buffer fallback at activity start

- Context: the owner's first real Mythic+ run (Murder Row +11, log in `tests/fixtures/combatlogs/retail/mplus_started_then_zoned_out_mac_client.txt`) failed with "Buffer not started" at CHALLENGE_MODE_START. The log pipeline worked; the recorder was not buffering. Upstream drops the activity in that case.
- Root cause (high confidence; `src/__tests__/mac/ProcessList.test.ts` checks the truncation against the real ps on the runner): the Poller ran `ps -axo comm=`. With no terminal on any stdio and no `COLUMNS` (a GUI app, CI), BSD ps cuts its last column at 79 characters. The Retail client path is 95 characters (`/Applications/World of Warcraft/_retail_/World of Warcraft.app/Contents/MacOS/World of Warcraft`), so ps printed `.../Contents/MacOS/W`, WoW was never detected and the buffer never started. Unit tests fed the parser full paths, so they could not catch it.
- Choice:
  - Poller uses `/bin/ps -axww -o comm=` (`-ww` = unlimited width), accepts a bare `World of Warcraft` argv[0], and logs `[Poller] WoW processes {...}` whenever the detected state or the set of WoW-like processes changes, so a future mismatch shows up in the app log.
  - Fallback, a deliberate deviation from upstream: if an activity starts while the buffer is down, `Recorder.convertObsBuffer` attaches the audio sources if none are attached, starts the buffer and records from that point, and emits an error report saying the start is missing. A combat log event proves WoW is running, and a late recording beats a dropped run. The cost is the seconds before the buffer came up; timeline markers in that video are shifted by that amount.
  - An unrequested buffer loss (helper exit, or a failed automatic restart) now emits an error report instead of silently returning the status to "Waiting for WoW".
- Not changed: leaving the instance mid-key does not end the run (upstream behaviour, so zoning out to repair keeps one recording); the run ends on CHALLENGE_MODE_END, a new activity, WoW closing or a force stop.
