# macOS Port Progress

Single source of truth for resuming. Update before every checkpoint commit.

## Current state

- **Current phase:** 2 (detailed analysis)
- **Last checkpoint tag:** `macos-port-phase-1` (local only; see blocker B-001 and the tag table below)
- **Latest CI result:** no macOS CI workflow yet. Runner smoke test (run 37172369803) green: macOS 27.0.1, Xcode 27.0, SDK 27.0, Node 24.11.1, arm64.
- **Exact next step:** write `docs/macos-port/ANALYSIS.md` (phase 2).

## Phase checklist

### Phase 1: orientation and agent files
- [x] Branch `macos-port` checked out; fixtures commit pulled
- [x] Read core code: Recorder, Manager, Poller, CombatLogWatcher, LogHandler, RetailLogHandler, activities, VideoProcessQueue, main, util, configUtils, `noobs` package internals
- [x] Baseline quality gates measured (all red, see DECISIONS D-003)
- [x] `CLAUDE.md`, `AGENTS.md`, `PROGRESS.md`, `DECISIONS.md`
- [x] Removed broken `node.js.yml` (D-001)

### Phase 2: detailed analysis
- [ ] `ANALYSIS.md`

### Phase 3: recording backend decision
- [ ] Options evaluated (OBS / ffmpeg / ScreenCaptureKit helper)
- [ ] macOS CI workflow on self-hosted runner
- [ ] Spike verified on runner (SDK capabilities, encode pipeline self-test, ffmpeg avfoundation device list)
- [ ] Decision recorded

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

- 2026-10-05: phase 1 complete. Orientation, baseline measurements, agent files.

## Open blockers (waiting on owner)

- **B-001: cannot push git tags.** The session's git proxy returns HTTP 403 for `refs/tags/*` (only `macos-port` is pushable), and the GitHub tools offer no tag creation. Phase tags are created locally and listed below with their commit SHAs. To publish them, run on your Mac:
  `git fetch origin macos-port && git tag <tag> <sha> && git push origin <tag>` for each row, or grant the session tag push access. Work continues meanwhile.

## Phase tags

| Tag | Commit | Pushed |
| --- | --- | --- |
| `macos-port-phase-1` | `414af9a` | no (B-001) |

## In-flight experiments

- None.

## Verified vs assumed

- Verified: runner toolchain versions (smoke test log). Baseline gate failures (local container run).
- Assumed: nothing claimed about on-device behavior yet.
