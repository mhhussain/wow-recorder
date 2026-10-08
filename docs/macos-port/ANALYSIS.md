# macOS Port Analysis

Phase 2 analysis of upstream Warcraft Recorder (fork point `9a4b987`, app version 7.13.3) for a macOS 27 / Apple Silicon port. Updated if understanding changes; decisions live in `DECISIONS.md`.

Legend: **[V]** verified by reading code or running it in the container or CI; **[A]** assumption or belief not yet verified on a Mac.

## 1. Architecture

ERB (electron-react-boilerplate) two-package layout:

- Root `package.json`: JS dependencies bundled by webpack (`.erb/configs/*`), dev tooling, electron-builder config.
- `release/app/package.json`: runtime native deps packaged as real `node_modules`: `noobs` (libobs binding), `uiohook-napi` (global keyboard/mouse hook), `atomic-queue`. Webpack treats these as externals. `postinstall` runs `electron-rebuild` against Electron 44.

Processes:

| Process | Entry | Role |
| --- | --- | --- |
| Main | `src/main/main.ts` | Creates `BrowserWindow` (frameless, custom title bar), tray, `Manager`, initializes `Recorder` (OBS) after the window exists (preview needs the native handle), registers most IPC, starts `uIOhook`, `AppUpdater`. |
| Preload | `src/main/preload.ts` | `contextBridge` exposing `window.electron.ipcRenderer` with typed helpers (`createAudioSource`, `getAudioSourceProperties`, `configurePreview`, ...). Imports `noobs` types. |
| Renderer | `src/renderer/index.tsx` | React app: video viewer (`VideoPlayer`, `CategoryPage`), settings pages, status cards. Plays files via the privileged `vod://` protocol (`handleSafeVodRequest`). |

Main-process singletons: `Manager`, `Recorder`, `Poller`, `ConfigService` (electron-store, `config-v3.json`), `VideoProcessQueue`, `DiskClient`, `CloudClient`, `DiskSizeMonitor`.

IPC: `ipcMain.on/handle` in `main.ts`, `Manager.ts`, `Recorder.ts`, storage clients; `send(channel, ...)` pushes state (`updateRecStatus`, `updateMicStatus`, `volmeter`, `redrawPreview`, `refreshState`, ...).

## 2. Combat log pipeline

1. `Manager.applyBaseConfig` creates one log handler per enabled flavour: `RetailLogHandler(retailLogPath)` (data timeout 10 min), `ClassicLogHandler` / `EraLogHandler` (2 min), PTR variants.
2. `LogHandler` constructor creates a `CombatLogWatcher(logPath)` and calls `watch()`.
3. `CombatLogWatcher.watch()` snapshots sizes of existing `WoWCombatLog*.txt` (so a mid-activity launch does not replay old data), then `fs.watch(logDir)`:
   - `rename` events: deletes the per-file state (next change reads the file from byte 0; upstream issue 624).
   - `change` events: queued `process(file)` reads `[lastSize, currentSize)`, splits on `\n`, emits `LogLine` objects keyed by event type, plus `WARCRAFT_RECORDER_LOG_ACTIVITY` (resets the data timeout).
4. Handlers subscribe per event type and push work onto an `AsyncQueue` so lines are processed strictly in order.
5. `LogLine` lazily parses CSV-ish args (quoted strings, `[...]` arrays) and the timestamp (pre-TWW `M/D hh:mm:ss.mmm` and TWW `M/D/YYYY hh:mm:ss.mmmm[-TZ]`; local time, milliseconds dropped).

macOS risks:

- **[A] FSEvents semantics.** Node's `fs.watch` on macOS is FSEvents-backed; libuv maps any event whose flags include Created/Removed/Renamed to `rename`. FSEvents flags are cumulative/coalesced, so writes to a recently created log can be reported as `rename`. Upstream treats `rename` as "reset to byte 0", which can either replay the whole file or, if every event is `rename`, never read. This is a correctness risk for the MVP and must be fixed by making `process()` stat-driven (detect truncation/replacement by size and inode) and ignoring event type. A low-frequency poll fallback is cheap insurance.
- **[V] Partial lines.** A read chunk ending mid-line is split and the fragment parsed as a line; the remainder is lost. Low risk on Windows (WoW flushes whole lines) but trivial to fix with a carry-over buffer, and FSEvents coalescing makes chunk boundaries less predictable.
- **[A] Log location.** macOS Retail logs are commonly `/Applications/World of Warcraft/_retail_/Logs`. User-configurable already.
- **[V] Path validation.** `validateBaseConfig` requires the folder to be named `Logs` and (if `validateLogPaths`) the sibling `../.flavor.info` to name the flavour (`wow` for Retail). **[A]** Whether the macOS install writes `.flavor.info` is unverified; the setting can be disabled.
- **[V] NTFS check.** `getDriveFormat` returns `undefined` off Windows, so the filesystem check is skipped.
- **[V] Advanced combat logging check** reads `../WTF/Config.wtf`; same layout assumed on macOS **[A]**.

## 3. Activity state machine (raids and Mythic+)

Shared static state in `LogHandler`: `activity` (at most one), `overrunning`.

### Start

- `ENCOUNTER_START` (Retail): ignored in manual recording. If the encounter ID is a known dungeon encounter: inside an M+ it adds a boss timeline segment, outside M+ it is ignored. If an M+ is active and the encounter is not a dungeon encounter, the M+ is force-ended (ditched key into raid). Otherwise: optional "current raid only" filter (`recordCurrentRaidEncountersOnly`, default false), difficulty threshold (`minRaidDifficulty`, default LFR), then `LogHandler.handleEncounterStartLine` creates a `RaidEncounter` (or `Beloren`, `CoiledAltar`, `CrownOfTheCosmos` subclasses) only if the difficulty's `partyType` is `raid`.
- `CHALLENGE_MODE_START`: ignored if an M+ is already active (zoning in/out mid-key). Requires known `mapID` in `dungeonsByMapId` and `dungeonTimersByMapId`; `level >= minKeystoneLevel` (default 2). Creates `ChallengeModeDungeon` with an initial trash segment. The constructor also fetches current timers from the cloud API (falls back to local constants).
- `LogHandler.startActivity`: checks the category is enabled (`recordRaids`, `recordDungeons`), computes `offset = (Date.now() - activity.startDate) / 1000` (seconds to cut back into the buffer, compensating for combat log latency), sets `LogHandler.activity`, calls `Recorder.startRecording(offset)`. On failure the activity is cleared.

### End

- `ENCOUNTER_END` (raid): result from arg 5; on a kill sets `overrun = raidOverrun` (default 15 s). `activity.end(date, result)` then `endActivity()`.
- `ENCOUNTER_END` inside M+: closes the boss segment, opens a trash segment.
- `CHALLENGE_MODE_END`: result arg 2, `CMDuration` arg 4 (ms). Timed/completed sets `overrun = dungeonOverrun` (default 5 s). Abandoned or depleted runs have result 0 and are kept, labelled `(Abandoned)`; `upgradeLevel` comes from `CMDuration` against timers (`+1..+3`, 0 if no duration).
- Force end: data timeout (no log data for 10 min Retail), WoW process exit (`Manager.onWowStopped`), the UI force-stop button, a new `ARENA_MATCH_START`, a non-dungeon `ENCOUNTER_START` during M+. Force end uses `overrun = 0` and `result = false`.
- `endActivity()`: clears `activity`, sets `overrunning`, waits `overrun` seconds, queues `Recorder.stop()`, immediately queues `Recorder.startBuffer()` if WoW is still running, awaits the stop, takes `getAndClearLastFile()`.

### Keep or discard

- No file from the recorder: discard with error report.
- Raids: discard if `duration < minEncounterDuration` (default 15 s). Duration is `end - start + overrun` from log timestamps.
- `getMetadata()` throws (discard) when required data is missing, e.g. no player GUID (raid resets with too little data, upstream `raid_reset` scenario).
- Kept videos go to `VideoProcessQueue.queueVideo` with `offset 0` and the activity duration; the queue cuts with ffmpeg stream copy (`-ss`, `-t`, `-map 0`, `-avoid_negative_ts make_zero`, `+faststart`) into the storage folder, writes `<name>.json` metadata, generates nothing else locally (no thumbnails), and optionally uploads.

### Fixture coverage (from `tests/src/retail/*.py`)

| Fixture | Expected |
| --- | --- |
| `raid_wipe` | `Alexsmite - Sepulcher of the First Ones, Lihuvim, Principal Architect [HC] (Wipe)` |
| `raid_unknown_encounter` | `Alexsmite - Void Lord Top Dog [HC] (Wipe)` |
| `raid_reset` | no video |
| `raid_holy_priest_angel_death` | `... Void Lord Top Dog [HC] (Wipe)`, 21 deaths |
| `beloren_boss_hp`, `coiled_altar_boss_hp` | wipes with boss HP 45 / 17 |
| `mythic_plus` | `Arcanedemon - The Stonevault +10 (Abandoned)` |
| `mythic_plus_drop_go` | `Vutar - Dawn of the Infinite +20 (+1)` then `+21 (Abandoned)` |
| `mythic_plus_repair` | `Vutar - Dawn of the Infinite +18 (+3)`, 4 bosses |
| `mythic_plus_no_boss` | `Arcanedemon - The Stonevault +10 (Abandoned)` after force stop |
| `mythic_plus_ditch_into_raid` | M+ `(Abandoned)` then raid `(Wipe)` |
| `zone_changes` | no video |

Upstream ran these as live integration tests (rewriting timestamps to "now" and sleeping between events). The port runs them as unit tests against the real handlers with a mocked recorder, so expectations involving real-time sleeps (for example the minimum-duration rule) are evaluated against original log timestamps instead.

## 4. Recording backend (upstream)

`Recorder` (`src/main/Recorder.ts`, 1944 lines) wraps `noobs` 0.0.205 (`aza547/noobs`):

- **[V] Windows-only.** The npm package ships prebuilt Windows libobs (`obs.dll`, `libobs-d3d11.dll`, `win-capture`, `win-wasapi`, NVENC/QSV/AMF plugins, `ffmpeg.exe`) and its install script runs `node-gyp rebuild` linking `bin/64bit/obs.lib`. `index.js` prepends `dist/bin` to `PATH` with `;`. The C++ includes `<windows.h>` and uses `HWND` for the preview child window. It cannot install or load on macOS.
- **[V] Depends on a patched OBS.** `startRecording(offset)` calls a `convert` procedure with `offset_seconds` on the `replay_buffer` output and listens for a `converted` signal. Neither exists in upstream OBS's replay buffer, so libobs is a fork.
- Buffer model: `replay_buffer` with `max_time_sec 60`, `max_size_mb 1024`, file name format `%CCYY-%MM-%DD %hh-%mm-%ss`, fragmented MP4 (`frag_keyframe+empty_moov+delay_moov`). `convert` writes the in-memory buffer from `offset` seconds ago to disk and continues recording into the same file.
- Video: one scene with one capture source (`game_capture` / `window_capture` / `monitor_capture`), an optional chat overlay `image_source`, canvas = output resolution (`ResetVideoContext(fps, w, h)`, NV12, BT.709 partial range).
- Encoder: one video encoder, `keyint_sec 1` (cut accuracy without re-encode). x264 uses CRF, hardware encoders CQP: Ultra 22, High 26, Moderate 30, Low 34 (AV1 20/24/28/32).
- Audio: six mixes, six `ffmpeg_aac` encoders at 128 kbps, so every file carries six AAC tracks. Each source has a 6-bit track mask (default track 1). Sources: `wasapi_output_capture` (device loopback), `wasapi_input_capture` (mic), `wasapi_process_output_capture` (per-executable). Volume per source. Force mono and noise suppression (`noise_suppress_filter_v2`) apply to mic sources only. Push-to-talk mutes all input sources (`SetMuteAudioInputs`) via `uiohook-napi` key/mouse listeners with a release delay. Volmeter callbacks send a linear peak (0..1) per source while audio settings are open.
- Signals consumed: `start` (buffer running, `obsState = Recording`), `converted` (current file path, enables instant replay once `moov`/`moof`/`mdat` are present), `deactivate` (stopped), plus `source` (size change, redraw preview) and `volmeter`.
- Preview: libobs draws into a native child window positioned over the React layout (`InitPreview(hwnd)`, `ConfigurePreview(x, y, w, h)`); the scene editor drags/scales/crops the game and overlay sources via `GetSourcePos`/`SetSourcePos`.
- `ffmpeg` for post-processing is `node_modules/noobs/dist/bin/ffmpeg.exe`.

### Call surface the Recorder needs

`Init`, `Shutdown`, `SetBuffering`, `SetFragmentation`, `SetRecordingCfg`, `ResetVideoContext`, `ListVideoEncoders`, `SetVideoEncoder`, `StartBuffer`, `StartRecording(offset)`, `StopRecording`, `ForceStopRecording`, `GetLastRecording`, `CreateSource`, `DeleteSource`, `Get/SetSourceSettings`, `GetSourceProperties` (device, window, monitor lists), `AddSourceToScene`, `RemoveSourceFromScene`, `Get/SetSourcePos`, `SetSourceVolume`, `SetSourceAudioTracks`, `SetMuteAudioInputs`, `SetForceMono`, `SetAudioSuppression`, `SetVolmeterEnabled`, preview functions. This is the seam for a replacement backend.

## 5. Recording settings and macOS equivalents

| Setting (config key) | Windows implementation | macOS 27 equivalent |
| --- | --- | --- |
| Output resolution (`obsOutputResolution`) | OBS canvas size | Capture scaled to output size (ScreenCaptureKit `width`/`height`, aspect preserved, letterboxed) |
| FPS (`obsFPS`, 15..60) | OBS video context | Fixed-rate frame pacer feeding the encoder (repeat last frame when the screen is static) |
| Encoder (`obsRecEncoder`) | x264, NVENC, AMF, QSV | VideoToolbox hardware H.264 and HEVC. No software x264 (not needed on Apple Silicon) |
| Quality (`obsQuality`) | CRF/CQP 22/26/30/34 | VideoToolbox constant quality (`kVTCompressionPropertyKey_Quality`), mapped per preset; tunable **[A]** |
| Keyframe interval | `keyint_sec 1` | `MaxKeyFrameIntervalDuration 1 s`, no B-frames |
| Capture mode (`obsCaptureMode`) game/window | Hook / window capture of `Wow.exe` | ScreenCaptureKit capture of the WoW window (auto-detected by app). Game and window modes behave the same |
| Capture mode monitor (`monitorIndex`) | DXGI monitor capture | ScreenCaptureKit display capture by `CGDirectDisplayID` (Electron `display.id` is the same ID) |
| Capture cursor (`captureCursor`) | source setting | `showsCursor` |
| Force SDR (`forceSdr`) | HDR tonemap | Capture in SDR 8-bit 4:2:0 (always SDR) |
| Output audio source (`wasapi_output_capture`) | Loopback of a chosen output device | ScreenCaptureKit system audio (all apps except this one). Device choice is meaningless on macOS; one "System audio" entry |
| Process audio source (`wasapi_process_output_capture`) | Per-executable loopback | ScreenCaptureKit audio filtered to a chosen application (e.g. World of Warcraft) |
| Input audio source (`wasapi_input_capture`) | WASAPI mic | AVFoundation capture of a chosen microphone (multiple supported) |
| Volume, six-track routing | OBS mixer, 6 AAC tracks | Helper mixer producing six 48 kHz stereo mixes, AAC 128 kbps, six tracks per file |
| Force mono (`obsForceMono`) | OBS flag on mics | Downmix mic sources to mono |
| Audio suppression (`obsAudioSuppression`) | RNNoise/Speex filter on mics | Closest cheap equivalent is a noise gate on mic sources; true ML suppression is a gap **[A]** |
| Push to talk (`pushToTalk*`) | uiohook + mute inputs | Same uiohook code; requires Accessibility permission on macOS |
| Chat overlay (`chatOverlay*`) | OBS image source | Secondary; not in MVP |
| Preview and scene editor | libobs native child window | Not in MVP (no native window compositing). Candidate later: low-rate preview frames from the helper |
| Buffer folder (`bufferStoragePath` / `.temp`) | replay buffer output dir | Same folder, same `YYYY-MM-DD hh-mm-ss.mp4` naming (required by `takeOwnershipBufferDir`) |

## 6. Windows-specific dependencies on the MVP path

| Item | Where | Impact on macOS | Plan |
| --- | --- | --- | --- |
| `noobs` native module | `release/app/package.json`, `Recorder.ts`, `preload.ts`, `AudioSourceControls.tsx` | `npm install` fails (node-gyp links `obs.lib`); app cannot record | Remove; vendor its TS types; replace with a macOS backend behind the same call surface |
| `ffmpeg.exe` from noobs | `VideoProcessQueue.ts` | No post-processing, no saved videos | Bundle an arm64 `ffmpeg` |
| `binaries/rust-ps.exe` | `Poller.ts` | No WoW detection, buffer never starts | `ps`-based poller |
| `fs.watch` semantics | `CombatLogWatcher.ts` | Missed or replayed log data **[A]** | Stat-driven reads, partial-line carry-over, poll fallback |
| WoW window names `[Wow.exe]: ...` | `Recorder.windowMatch` | No window match | Match by app (bundle ID / name) in the helper |
| `explorer.exe /select` | `util.openSystemExplorer` | Open-folder buttons do nothing | `shell.showItemInFolder` |
| First-time setup paths `C:\...` | `util.runFirstTimeSetupActionsNoObs`, `constants.wowInstallSearchPaths` | No auto-detection | Add `/Applications/World of Warcraft` |
| `uIOhook.start()` | `main.ts` | Needs Accessibility; may throw or prompt on every launch **[A]** | Guard; start only when push-to-talk or manual hotkey is enabled |
| `AppUpdater` (electron-updater, publishes `aza547/wow-recorder`) | `main.ts` | Would check upstream releases | Remove |
| electron-builder config | root `package.json` | Only `win`/`nsis` targets; `asarUnpack "**\\**"` is a Windows glob | Add `mac` arm64 `dir`/`zip` target, ad-hoc signing, Info.plist usage strings |
| `powerMonitor` suspend/resume comments | `Manager.ts` | Works on macOS as is | Keep |
| `getDriveFormat` (PowerShell) | `util.ts` | Already no-op off Windows | Keep |
| Frameless window with custom controls | `main.ts`, renderer title bar | Works; no traffic lights | Keep (cosmetic) |

## 7. Features that can be disabled for the MVP

Preview and scene editor, chat overlay, cloud upload and cloud storage UI (works over HTTPS but is not needed; leave code in place, unconfigured), kill video compilation, auto-update, run-on-startup (works via `setLoginItemSettings`, untested), PvP categories (code is platform-agnostic and remains enabled by default, but is not an MVP acceptance criterion), Classic/Era (see below).

## 8. Classic support

Log parsing and activities for Classic and Era are platform-agnostic TypeScript and come for free. What is flavour-specific on macOS: process detection (folder names `_classic_`, `_classic_era_`, `_classic_ptr_` in the executable path **[A]**) and window detection (Classic app name/bundle ID **[A]**). Both are a few lines in the new poller and helper. Conclusion: include Classic at near-zero cost, unverified on device.

## 9. Ranked port blockers

Effort: S = under half a day of focused work, M = about a day, L = several days, each assuming CI round-trips on the runner.

| Rank | Blocker | Effort | Notes |
| --- | --- | --- | --- |
| 1 | No macOS recording backend (`noobs` is Windows-only and needs a patched libobs) | L | Decision in phase 3. Must match buffer semantics (`convert(offset)`), six-track audio, fragmented MP4, signals |
| 2 | System audio and microphone capture with permissions | M | ScreenCaptureKit audio + AVFoundation mics; TCC prompts attach to the responsible app; ad-hoc re-signing can reset grants **[A]** |
| 3 | `npm install` fails on macOS due to `noobs` | S | Remove dependency, vendor types |
| 4 | No WoW process detection (`rust-ps.exe`) | S | `ps` polling |
| 5 | No ffmpeg for post-processing | S | Bundle arm64 ffmpeg |
| 6 | Log tailing correctness on FSEvents | S | Stat-driven reader with tests |
| 7 | Packaging and signing for arm64 | M | electron-builder mac config, helper and ffmpeg signed inside the bundle |
| 8 | Quality gates red at baseline | S | tsc/lint/jest config fixes so CI is meaningful |
| 9 | `uiohook-napi` Accessibility behavior | S | Lazy start, guard errors |
| 10 | Preview / scene editor / overlay | M | Post-MVP |
