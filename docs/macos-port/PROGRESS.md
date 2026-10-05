# macOS Port Progress

Single source of truth for resuming. Update before every checkpoint commit.

## Current state

- **Current phase:** 6 (verification and handoff): waiting on the owner's on-device test (MANUAL_TEST.md)
- **Last checkpoint tag:** `macos-port-phase-5` (local only; see blocker B-001 and the tag table below)
- **Latest CI result:** run 37264154520 (commit 0601506) green in 84 s: typecheck, lint, 52 unit tests (17 full-log tests skipped by design), helper build + probe + self-test, webpack build, package, signature/Info.plist/binary checks, artifact `WarcraftRecorder-macos-arm64-0601506…` (161 MB zip, artifact 11325498319, expires after 7 days).
- **Exact next step:** confirm the CI run with the shim-to-helper integration test and the packaged-app boot smoke test is green (if the runner cannot host a hidden Electron window, record that and drop or gate the smoke step). Then wait for the owner's MANUAL_TEST.md results.

## Phase checklist

### Phase 1: orientation and agent files
- [x] Branch `macos-port` checked out; fixtures commit pulled
- [x] Read core code: Recorder, Manager, Poller, CombatLogWatcher, LogHandler, RetailLogHandler, activities, VideoProcessQueue, main, util, configUtils, `noobs` package internals
- [x] Baseline quality gates measured (all red, see DECISIONS D-003)
- [x] `CLAUDE.md`, `AGENTS.md`, `PROGRESS.md`, `DECISIONS.md`
- [x] Removed broken `node.js.yml` (D-001)

### Phase 2: detailed analysis
- [x] `ANALYSIS.md`

### Phase 3: recording backend decision
- [x] Options evaluated (OBS / ffmpeg / ScreenCaptureKit helper)
- [x] macOS CI workflow on self-hosted runner (`macos-ci.yml`)
- [x] Spike verified on runner (SDK capabilities, encode pipeline self-test, ffmpeg avfoundation device list)
- [x] Decision recorded (D-004, D-005, D-006)

### Phase 4: macOS MVP implementation
- [x] Quality gates green (tsc 0 errors, lint 0 errors, 70 jest tests locally; same gates in CI)
- [x] `noobs` removed; `MacNoobs` shim + `CaptureHelper` client wired into Recorder (fail-fast start errors, VideoToolbox encoders and quality mapping); shim unit tests
- [x] Log folder discovery (first run checks /Applications and ~/Applications for `World of Warcraft/_retail_|_classic_/Logs`; default storage ~/Movies/Warcraft Recorder; missing `.flavor.info` accepted)
- [x] Robust log tailing on macOS (stat-driven reads, inode/truncation detection, partial-line carry-over, 1 s poll backstop; tests)
- [x] WoW process detection (`ps` poller, flavour by install folder, WCR_FAKE_WOW for testing; tests)
- [x] Recorder backend wired to existing settings (resolution, FPS, encoder, quality, capture mode, monitor, cursor, audio sources with device/volume/tracks, force mono, suppression, push to talk)
- [x] Permission handling: mic requested via Electron at startup when a mic source exists; Screen Recording requested via the helper (CGRequestScreenCaptureAccess) and explained in the UI error report; backend start failures surface immediately
- [x] Windows-only features disabled or removed: AppUpdater, explorer.exe, rust-ps.exe, Windows search paths, unconditional uiohook start (now lazy and guarded, needs Accessibility), tray icon sized for the menu bar

### Phase 5: build
- [x] electron-builder arm64 `.app`, Info.plist usage strings, ad-hoc signing (D-007; verified in CI: codesign valid, DR satisfied)
- [x] CI uploads the packaged app as an artifact (ditto zip, 7-day retention)
- [x] Run-from-source fallback documented (MANUAL_TEST.md section 1C)

### Phase 6: verification and handoff
- [x] Tests and CI green
- [x] `MANUAL_TEST.md` complete
- [ ] On-device verification by the owner (MANUAL_TEST.md results checklist)
- [x] Final status report (end of session 1, below)

### Phase 7 (optional, after MVP)
- [x] Classic and Era: free (D-006); scenario tests pass for Classic raid, MoP challenge mode, Era raid
- [ ] PvP triggers: code is unchanged and platform-agnostic (arena/BG/shuffle activity unit tests pass); no PvP scenario tests on the fixture logs yet
- [ ] Secondary features: preview/scene editor, chat overlay, cloud (untouched), viewer polish

## Last session

- 2026-10-05 (session 1): phases 1-5 complete, phase 6 waiting on the owner.
  - Backend: Swift ScreenCaptureKit helper (`native/wcr-capture`) + `MacNoobs` shim replacing `noobs`; Recorder call sites unchanged.
  - macOS plumbing: ps poller, FSEvents-safe log watcher, permissions, lazy input hook, /Applications discovery, logs in ~/Library/Logs, Finder.
  - Tests: 70 jest tests incl. 18 scenario tests on real log excerpts (raids, M+, Classic, Era) and full-log fidelity tests.
  - CI: one workflow, 84 s warm, produces a signed arm64 app artifact.
  - Found and fixed along the way: Electron 44 ABI unknown to node-abi 4.31 (CI npm ci), FSEvents watcher leak hanging Jest on macOS, logs written inside the signed bundle, upstream tests stale (wrong constructor arity, hardcoded year).

## Open blockers (waiting on owner)

- **B-001: cannot push git tags.** The session's git proxy returns HTTP 403 for `refs/tags/*` (only `macos-port` is pushable), and the GitHub tools offer no tag creation. Phase tags are created locally and listed below with their commit SHAs. To publish them, run on your Mac:
  `git fetch origin macos-port && git tag <tag> <sha> && git push origin <tag>` for each row, or grant the session tag push access. Work continues meanwhile.

## Phase tags

| Tag | Commit | Pushed |
| --- | --- | --- |
| `macos-port-phase-1` | `414af9a` | no (B-001) |
| `macos-port-phase-2` | `874fcf2` | no (B-001) |
| `macos-port-phase-3` | `c3884ea` | no (B-001) |
| `macos-port-phase-4` | `d4bf5f0` | no (B-001) |
| `macos-port-phase-5` | `0601506` | no (B-001) |

## In-flight experiments

- None. E-001 (ScreenCaptureKit helper spike) concluded: adopted as the backend (D-004).

## Verified vs assumed

- **Verified on the runner (CI):** helper compiles against SDK 27; VideoToolbox H.264/HEVC hardware sessions with constant quality; ScreenCaptureKit audio/mic config surface exists; synthetic end-to-end recording through the real engine and command protocol (buffer, convert with offset, convert before first frame, six-track mix with expected per-track levels, fragmented MP4, stop, force stop) produces correct files that ffmpeg decodes; ffmpeg avfoundation exposes no system audio device; log watcher tests on FSEvents; packaged app signature valid, Info.plist strings present, bundled helper and ffmpeg execute.
- **Verified by unit tests (real combat logs, mocked recorder):** raid/M+/Classic/Era start, stop, keep/discard and naming match upstream's integration expectations; excerpts are faithful to the full logs; Poller flavour detection; shim config mapping, command ordering, crash recovery.
- **Not verified (needs the owner, TCC-gated):** real ScreenCaptureKit capture of the WoW window and display; system, app and microphone audio in real recordings; TCC attribution of the helper process to WarcraftRecorder.app; permission behaviour across ad-hoc rebuilds; A/V sync under load; whether the Mac WoW client writes `.flavor.info`; WoW bundle ID/app name assumptions (`com.blizzard.worldofwarcraft*`, "World of Warcraft*"); the app UI end to end (never launched in CI to avoid permission prompts on the owner's desktop).
- **Known gaps (by design, D-004):** no live preview/scene editor, no chat overlay compositing, noise suppression is a noise gate, no output-device selection for system audio.
- Runner facts: two 3440x1440 displays; mics include a BY-PM700 and Realtek USB audio.
