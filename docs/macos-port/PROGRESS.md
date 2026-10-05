# macOS Port Progress

Single source of truth for resuming. Update before every checkpoint commit.

## Current state

- **Current phase:** 4 (macOS MVP implementation)
- **Last checkpoint tag:** `macos-port-phase-3` (local only; see blocker B-001 and the tag table below)
- **Latest CI result:** `macos-ci` run 37261237609 (commit 58a5a82) green in 40 s: helper compiles, probe OK, self-test pass (3 recordings verified: durations 5.08/5.07/2.03 s, 6 AAC tracks with expected levels, avc1/hvc1), ffmpeg decodes all.
- **Exact next step:** phase 4: remove `noobs`, add the TypeScript shim (`src/main/mac/`) that drives `wcr-capture`, wire Recorder to it, then the ps poller, log watcher hardening and unit tests.

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
- [ ] Quality gates green (tsc, lint, jest)
- [ ] Unit tests: log parsing and start/stop state machine for raids and M+ using real fixtures and a mocked recorder
- [ ] Log folder discovery and robust log tailing on macOS
- [ ] WoW process detection
- [ ] Recorder backend wired to existing settings (video + audio)
- [ ] Permission handling (screen recording, microphone)
- [ ] Windows-only features disabled or removed

### Phase 5: build
- [ ] electron-builder arm64 `.app`, Info.plist usage strings, ad-hoc signing
- [ ] CI uploads the packaged app as an artifact
- [ ] Run-from-source fallback documented

### Phase 6: verification and handoff
- [ ] Tests and CI green
- [ ] `MANUAL_TEST.md` complete
- [ ] Final status report

### Phase 7 (optional, after MVP)
- [ ] Classic (if not already free), PvP triggers, secondary features

## Last session

- 2026-10-05: phases 1-3 complete. Orientation and agent files; ANALYSIS.md; backend decision with the Swift helper green on the runner. Jest config groundwork in progress (Electron, electron-store and uiohook stubs).

## Open blockers (waiting on owner)

- **B-001: cannot push git tags.** The session's git proxy returns HTTP 403 for `refs/tags/*` (only `macos-port` is pushable), and the GitHub tools offer no tag creation. Phase tags are created locally and listed below with their commit SHAs. To publish them, run on your Mac:
  `git fetch origin macos-port && git tag <tag> <sha> && git push origin <tag>` for each row, or grant the session tag push access. Work continues meanwhile.

## Phase tags

| Tag | Commit | Pushed |
| --- | --- | --- |
| `macos-port-phase-1` | `414af9a` | no (B-001) |
| `macos-port-phase-2` | `874fcf2` | no (B-001) |
| `macos-port-phase-3` | see `git log --grep '\[phase-3\] record backend decision'` | no (B-001) |

## In-flight experiments

- None. E-001 (ScreenCaptureKit helper spike) concluded: adopted as the backend (D-004).

## Verified vs assumed

- Verified on the runner: helper compiles against SDK 27; VideoToolbox H.264/HEVC hardware sessions with constant quality; ScreenCaptureKit audio/mic config surface exists; synthetic end-to-end recording (buffer, convert with offset, six-track mix, fragmented MP4, stop/force-stop) produces correct files; ffmpeg-static arm64 decodes them; ffmpeg avfoundation exposes no system audio device.
- Verified locally: baseline gate failures; jest now loads suites that do not import `noobs`.
- Assumed (not testable in CI because of TCC): real ScreenCaptureKit capture of the WoW window, system/app audio, microphones; TCC attribution of the helper to the app.
- Runner facts: two 3440x1440 displays; mics include a BY-PM700 and Realtek USB audio.
