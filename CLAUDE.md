# CLAUDE.md

Guidance for agents working on this repository (`mhhussain/wow-recorder`, branch `macos-port`).

## Start here

1. Read `docs/macos-port/PROGRESS.md` first. It is the single source of truth for resuming: current phase, checklist, last CI result, exact next step, blockers.
2. Then read `docs/macos-port/DECISIONS.md` (append-only decision log) and, if you need background, `docs/macos-port/ANALYSIS.md`.
3. Verify the branch builds and check the latest CI run before changing anything.
4. Do not redo completed phases or reverse a recorded decision without appending a new `DECISIONS.md` entry that explains why.

## Project purpose and fork scope

Warcraft Recorder (upstream `aza547/wow-recorder`) watches the World of Warcraft combat log and records gameplay. Upstream is Windows-only and records through OBS (`noobs`, a libobs Node binding).

This fork is a **personal, macOS-only port** for the owner's machine:

- Target: Apple Silicon (arm64), macOS 27 only. No Intel, no older macOS, no compatibility fallbacks.
- Not merged upstream, not distributed. No notarization, installer, auto-update, or release pipeline. Ad-hoc signed local `.app` or `npm start` from source.
- Windows behavior is not preserved. Windows-only code may be deleted, replaced, or bypassed. No platform abstraction layer.
- Retail is the target. Classic flavors are included only where they come for free.
- MVP: raid encounters and Mythic+ runs auto-record from combat log events with full audio/video (game/system audio + microphone), saved as playable files visible in the existing viewer. PvP, cloud upload, overlays, drawing, and viewer polish are secondary.

## Architecture summary

Electron + React, built on electron-react-boilerplate (ERB). Details in `docs/macos-port/ANALYSIS.md`.

- **Main process** (`src/main/main.ts`): window, tray, IPC handlers, creates `Manager` and initializes the `Recorder`.
- **Manager** (`src/main/Manager.ts`): orchestrates config validation, log handlers, WoW process events (`Poller`), and recorder lifecycle.
- **Log pipeline** (`src/parsing/`): `CombatLogWatcher` tails `WoWCombatLog*.txt` and emits `LogLine` events by type; `RetailLogHandler` / `ClassicLogHandler` / `EraLogHandler` (subclasses of `LogHandler`) drive activities.
- **Activities** (`src/activitys/`): `RaidEncounter`, `ChallengeModeDungeon` (M+), arena/BG/shuffle, `Manual`. `LogHandler.startActivity` converts the always-on buffer into a recording with an offset back in time; `LogHandler.endActivity` waits the overrun, stops, applies min-duration rules, and queues the file to `VideoProcessQueue`.
- **Recorder** (`src/main/Recorder.ts`): wraps the capture backend with a buffer model: `startBuffer()` (continuous in-memory buffer while WoW runs), `startRecording(offset)` (convert buffer starting `offset` seconds ago), `stop()`, `forceStop()`.
- **VideoProcessQueue** (`src/main/VideoProcessQueue.ts`): ffmpeg (stream copy) cut/remux into the storage folder, writes metadata JSON; cloud upload queue.
- **Renderer** (`src/renderer/`): React UI (viewer, settings). Talks to main via `src/main/preload.ts`.

macOS port specifics (updated as work lands; see PROGRESS.md for status):

- Recording backend (D-004): `native/wcr-capture/` Swift helper (ScreenCaptureKit video and system/app audio, AVFoundation mics, six-track mixer, VideoToolbox, 60 s replay buffer, fragmented MP4) talks JSON lines over stdio. `src/main/mac/MacNoobs.ts` implements the `noobs` call surface on top of it (`src/main/mac/noobs.ts` wires it to Electron), so `Recorder.ts` call sites are unchanged. Types formerly from `noobs` live in `src/main/mac/noobsTypes.ts`.
- Process detection: `ps`-based poller instead of `binaries/rust-ps.exe`.

## Key directories and entry points

| Path | What |
| --- | --- |
| `src/main/main.ts` | Electron main entry |
| `src/main/Manager.ts`, `src/main/Recorder.ts` | Orchestration and recording |
| `src/parsing/`, `src/activitys/` | Combat log parsing and activity state |
| `src/main/VideoProcessQueue.ts` | Post-processing with ffmpeg |
| `src/renderer/` | React UI |
| `release/app/package.json` | Native/runtime deps packaged with the app (ERB two-package layout) |
| `.erb/configs/` | Webpack configs |
| `binaries/` | Bundled executables (extraResources) |
| `tests/fixtures/combatlogs/` | Real combat logs (owner-provided); file name describes contents |
| `tests/src/<flavour>/*.py` | Upstream integration test definitions: expected outcome per log file |
| `docs/macos-port/` | Port docs: PROGRESS, DECISIONS, ANALYSIS, MANUAL_TEST |

## Commands

Linux container (cloud agent) and macOS runner both use Node 24 / npm 11.

- Install (Mac): `npm ci` (downloads Electron and the arm64 ffmpeg, rebuilds `uiohook-napi`).
- Install (Linux container, no native builds): `npm ci --ignore-scripts && (cd release/app && npm ci --ignore-scripts) && ln -sfn ../release/app/node_modules src/node_modules`
- Typecheck: `npm run typecheck` (uses `tsconfig.typecheck.json`: bundler resolution for ESM-only typings; webpack and ts-node keep `tsconfig.json`)
- Lint: `npm run lint` (0 errors required; pre-existing warnings allowed, see D-003)
- Unit tests: `npm test` (jest; Electron, electron-store, electron-log, uiohook-napi, archiver, `main/main` and CloudClient are stubbed in `tests/mocks/` and `tests/setup.ts`)
- Native binaries (Mac only): `npm run build:native` builds `binaries/wcr-capture` and copies `binaries/ffmpeg`
- Capture helper checks (Mac only): `binaries/wcr-capture probe`, `binaries/wcr-capture selftest <dir>`
- Packaged-app boot check (Mac only): `WCR_SMOKE_TEST=<dir> release/build/mac-arm64/WarcraftRecorder.app/Contents/MacOS/WarcraftRecorder` (exits 0/1; no permission prompts; see `src/main/smokeTest.ts`)
- Scenario tests: `src/__tests__/scenarios/` replays real combat logs through the real handlers with a mocked recorder. Raid/M+ use excerpts (`tests/fixtures/excerpts`, regenerate with `python3 tests/fixtures/make_excerpts.py`); full-log fidelity tests and PvP tests run when the full logs are present. `src/__tests__/mac/HelperIntegration.test.ts` drives the real helper on macOS.
- Build JS bundles: `npm run build`
- Package (Mac only): `npm run package`
- Dev mode (Mac): `npm run build:native && npm start`

All gates (typecheck, lint, test, build) were red at fork time and are green as of phase 4 (D-003).

## Conventions observed in the repo

- TypeScript strict mode, Prettier (single quotes), ESLint flat config (`eslint.config.mjs`). Prettier violations are lint errors.
- Singletons via `getInstance()` (Recorder, Poller, ConfigService, VideoProcessQueue, DiskClient, CloudClient).
- Logging via `console.info/warn/error` with a `[ClassName]` prefix; electron-log captures it.
- Imports resolve from `src/` as `baseUrl` (e.g. `import Poller from 'utils/Poller'`).
- Native modules live in `release/app/package.json`, never the root `package.json` (ERB rule enforced by `.erb/scripts/check-native-dep.js`).
- Comment style: explanatory block comments on classes and non-obvious methods; keep that density.

## CI and self-hosted runner security rules (mandatory)

The macOS runner is the owner's personal Mac (`runs-on: [self-hosted, macOS, ARM64, wow-mac]`, runner name `macmini`; macOS 27.0.1, Xcode 27.0, SDK 27.0, Node 24.11.1).

- Workflows using the self-hosted runner may trigger **only** on `push` to `macos-port` and on `workflow_dispatch`. Never `pull_request`, `pull_request_target`, or `schedule`.
- Never add steps that read files outside the job workspace, change system settings, install software system-wide, or use `sudo`. Keep tool caches (npm, electron, electron-builder, Swift module cache) inside the workspace.
- If a build needs a new system-level tool, stop and ask the owner.
- Keep workflows efficient; the runner is the owner's machine.
- Check CI results after each push that touches the build (GitHub MCP `actions_list` / `get_job_logs`).

## What has been removed or disabled for macOS (and why)

Kept current as work lands. See DECISIONS.md for reasoning.

- `.github/workflows/node.js.yml`: removed. It was fully commented out, which made every push report a failed workflow.
- `noobs` (Windows libobs binding): removed from `release/app`; replaced by the capture helper and `MacNoobs` shim.
- `tsc` npm package (unrelated to TypeScript, shadowed its binary): removed.
- Window-finding/attach polling in `Recorder` (`[Wow.exe]` window names): replaced; the helper finds and follows the WoW window.
- `src/renderer/CrashStatus.tsx`: deleted (dead file importing a type that no longer exists).
- Native preview and scene editor: shim accepts the calls and does nothing (no macOS preview, D-004).
- `AppUpdater` (electron-updater against upstream's Windows releases): removed.
- `uIOhook.start()` at launch: now `src/main/inputHook.ts`, started only for push to talk, manual hotkey or hotkey binding (needs Accessibility on macOS).
- Windows WoW install search paths and `explorer.exe`: replaced with /Applications discovery and Finder (`shell.showItemInFolder` / `openPath`).

Gotcha: the runner workspace persists, so a change to the CI sparse-checkout patterns only takes effect because the workflow reapplies them (`SPARSE_PATTERNS`, D-010). Check the test summary for unexpected skips.

Gotcha: never run `prettier --write` on whole directories. `RetailLogHandler.ts` and friends disable Prettier for their handler tables via eslint comments, which Prettier itself ignores.

## Fixture handling rules

- Real combat logs live in `tests/fixtures/combatlogs/{retail,classic,era}/`; the file name describes the scenario. They are byte-identical to upstream's `tests/logs/`, and `tests/src/<flavour>/<name>.py` documents the expected outcome for each.
- Commit log files as-is only when under GitHub's 100 MB per-file limit. Otherwise commit trimmed excerpts covering the relevant events.
- Unit tests use small focused excerpts (`tests/fixtures/excerpts/`); full files may back slower integration tests.
- Never commit recordings, large generated binaries, or secrets.

## Checkpoint protocol

- Commit after every completed sub-task and phase, with messages prefixed by phase, e.g. `[phase-3] spike ScreenCaptureKit helper`.
- Update `docs/macos-port/PROGRESS.md` before every checkpoint commit. Push to `origin macos-port` after every commit. Tag phase completions `macos-port-phase-N`.
- Never leave the branch non-compiling at a checkpoint; isolate WIP behind a flag or a labeled WIP commit noted in PROGRESS.md.
- Clearly separate verified (compiled, tested, built in CI) from believed-but-unverified-on-device.
