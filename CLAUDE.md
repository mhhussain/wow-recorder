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

- Recording backend: native Swift helper using ScreenCaptureKit + VideoToolbox + AVFoundation, driven over stdio by a TypeScript shim that implements the subset of the `noobs` API the Recorder uses. See DECISIONS.md.
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

- Install without native builds (Linux container): `npm ci --ignore-scripts`
- Typecheck: `node node_modules/typescript/bin/tsc --noEmit -p .` (do **not** use `npx tsc`; the `tsc` npm package in dependencies shadows TypeScript's binary)
- Lint: `npm run lint`
- Unit tests: `npm test` (jest)
- Build JS bundles: `npm run build`
- Package (macOS runner only): `npm run package`
- Dev mode (on the Mac): `npm start`

Baseline note: upstream did not typecheck, lint, or pass jest cleanly at fork time (55 tsc errors, 52 lint errors, all jest suites failing to load). Making these real gates is part of the port; see PROGRESS.md for current state.

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
