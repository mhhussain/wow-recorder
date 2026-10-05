# Manual Test: Warcraft Recorder on macOS

Step-by-step verification on the owner's Apple Silicon Mac (macOS 27). CI verifies everything except real capture, which is gated by macOS privacy permissions and needs you. Work top to bottom; each section says what "pass" looks like. Report results by updating the checklist at the end (or telling the agent which step failed and attaching logs, see section 9).

Unverified assumptions this test settles are marked **[verify]**.

## 1. Get the app

Pick one.

**A. From the runner's workspace (fastest, no quarantine).** The runner is this Mac, so the last CI build is already on disk:

```bash
ditto ~/code/actions-runner/_work/wow-recorder/wow-recorder/release/build/mac-arm64/WarcraftRecorder.app ~/Applications/WarcraftRecorder.app
```

**B. From the CI artifact.** GitHub > Actions > `macos-ci` > latest green run on `macos-port` > Artifacts > `WarcraftRecorder-macos-arm64-<sha>`. The download is a zip containing `WarcraftRecorder-macos-arm64.zip`:

```bash
cd ~/Downloads
unzip WarcraftRecorder-macos-arm64-*.zip        # the artifact wrapper
ditto -x -k WarcraftRecorder-macos-arm64.zip ~/Applications/
xattr -dr com.apple.quarantine ~/Applications/WarcraftRecorder.app
```

The `xattr` step is needed because the app is ad-hoc signed, not notarized; without it Gatekeeper reports the app as damaged or blocks it.

**C. Run from source (fallback).**

```bash
git clone -b macos-port https://github.com/mhhussain/wow-recorder.git
cd wow-recorder
npm ci
npm run build:native     # builds binaries/wcr-capture, copies binaries/ffmpeg
npm start
```

In dev mode macOS attributes privacy permissions to the app you launched from (Terminal, iTerm, VS Code), not to Warcraft Recorder, so grant Screen Recording and Microphone to that app instead. Logs go to `~/Library/Logs/Electron`, config to `~/Library/Application Support/Electron`.

Keep the installed app at one path (for example `~/Applications`). Moving it can invalidate permission grants.

## 2. First launch and permissions

1. Open `~/Applications/WarcraftRecorder.app`.
2. **Microphone:** a system prompt appears if a microphone source is configured (it is by default). Click Allow.
3. **Screen & System Audio Recording:** a system prompt appears, or the app shows an error report saying the permission is missing. Open System Settings > Privacy & Security > Screen & System Audio Recording, enable WarcraftRecorder, then quit and reopen the app (macOS only applies this permission on relaunch).
4. **Accessibility** is only needed for push to talk or the manual record hotkey. If you enable either, allow WarcraftRecorder in System Settings > Privacy & Security > Accessibility.

Pass: after relaunch there are no permission error reports and the status shows "Waiting for WoW" (or similar).

### After installing a new build

Each build is ad-hoc signed with a new code hash. **[verify]** macOS may keep showing the app as allowed while silently denying capture, or prompt again. If capture fails after an update (error report about Screen Recording, or videos with black frames or no audio), reset and re-grant:

```bash
tccutil reset ScreenCapture org.WarcraftRecorder
tccutil reset Microphone org.WarcraftRecorder
tccutil reset Accessibility org.WarcraftRecorder   # only if you use push to talk / hotkeys
```

Then relaunch and grant again as above. macOS 15 and later may also periodically re-confirm screen recording access with a system prompt; allow it.

Optional, to make grants survive rebuilds: create a self-signed code-signing certificate in Keychain Access (Certificate Assistant > Create a Certificate, type Code Signing) and ask the agent to sign with it instead of ad hoc. This is a keychain change on your Mac, so it is your call.

## 3. Configure

Settings (gear in the side menu):

1. **Storage.** Disk Storage Folder defaults to `~/Movies/Warcraft Recorder` (it must be empty or already managed by Warcraft Recorder). The buffer lives in `.temp` inside it.
2. **Retail.** Enable Retail and set Retail Log Path to `/Applications/World of Warcraft/_retail_/Logs` (auto-detected on first run if WoW is installed there). **[verify]** If the app rejects the path, turn off "Validate Log Paths".
3. **In WoW:** System > Network > enable Advanced Combat Logging, and turn on combat logging (`/combatlog`, or an auto-logging addon). Warcraft Recorder only reacts to what WoW writes to `WoWCombatLog-*.txt`.
4. **Video.**
   - Capture Mode: Window or Game (both capture the WoW window on macOS) or Monitor (a whole display).
   - Canvas Resolution: match your display's aspect (your displays are 3440x1440; pick 3440x1440, or 2560x1080 for smaller files). Other aspects are letterboxed.
   - FPS: 60 (or 30).
   - Video Encoder: Apple VideoToolbox H.264 (most compatible) or HEVC (smaller; required above 4K).
   - Quality: Moderate to start.
   - There is no live preview on macOS; the preview area stays empty.
5. **Audio.** Defaults: one Speaker source (all system audio except Warcraft Recorder itself) and one Microphone (system default). To record only the game, remove the Speaker and add an Application source set to "World of Warcraft (any client)". Each source can be routed to tracks 1 to 6; the in-app player plays track 1.

## 4. Smoke test without WoW (recommended first)

Pretend WoW is running so the recorder arms, then use the test button.

```bash
osascript -e 'quit app "WarcraftRecorder"'
launchctl setenv WCR_FAKE_WOW retail
open ~/Applications/WarcraftRecorder.app
```

1. Retail must be enabled with a valid log path (section 3); the test feeds the Retail log handler.
2. Set Capture Mode to Monitor (there is no WoW window to capture). Status should show "Ready to record".
3. Play some audio (a YouTube video) and talk into the microphone.
4. Side menu > Test > pick Raids. The test injects a fake 20 s boss kill ("Hogger") into the log pipeline; the status switches to Recording.
5. About 40 seconds after clicking (20 s encounter plus the 15 s kill overrun, plus processing) a video appears under Raids.

Pass: the video plays in the viewer with picture, the audio you played and your voice. Then clean up:

```bash
launchctl unsetenv WCR_FAKE_WOW
```

## 5. Real raid encounter

1. Launch WoW (Retail) with combat logging on. Status changes to "Ready to record" within a few seconds (the buffer is running). If it stays at "Waiting for WoW", WoW was not detected: recordings will still be made, but they start late and an error report says so. Send the `[Poller] WoW processes` lines from the log (section 9).
2. Pull a raid boss (LFR is fine). Status changes to Recording when the combat log shows ENCOUNTER_START (can lag the pull by a few seconds; the recording still starts from the pull because it cuts back into the buffer).
3. Kill or wipe. After ENCOUNTER_END plus the overrun (15 s on a kill, 3 s on a wipe) the video is saved.

Pass:
- The video appears under Raids named like `<Character> - <Raid>, <Boss> [<Difficulty>] (Kill|Wipe)`.
- It starts at or a moment before the pull and ends after the kill/wipe.
- Picture is the WoW window at the chosen resolution; game audio and your voice are present.
- Death markers appear on the timeline.
- Encounters shorter than the minimum duration (15 s default) are discarded by design.

## 6. Real Mythic+ run

1. Insert a keystone (at or above the minimum keystone level, default 2).
2. Recording starts at CHALLENGE_MODE_START and continues across bosses and zone-ins.
3. On completion the video saves after a 5 s overrun; an abandoned or depleted key saves as `(Abandoned)` when you leave.

Pass: the video appears under Mythic+ named `<Character> - <Dungeon> +<level> (+N|Abandoned)`, with boss segments on the timeline, game audio and microphone present throughout.

## 7. Check the audio tracks in a saved file

```bash
FF=~/Applications/WarcraftRecorder.app/Contents/Resources/binaries/ffmpeg
VIDEO=~/Movies/Warcraft\ Recorder/<file>.mp4
"$FF" -hide_banner -i "$VIDEO"          # expect 1 video stream and 6 AAC audio streams
```

To confirm game audio and microphone separately, route the Microphone source to tracks 1 and 2 (Audio settings), record again, then:

```bash
"$FF" -i "$VIDEO" -map 0:a:0 -c copy track1-all.m4a     # game + mic
"$FF" -i "$VIDEO" -map 0:a:1 -c copy track2-mic.m4a     # mic only
open track1-all.m4a track2-mic.m4a
```

## 8. Things to try if something is off

| Symptom | Check |
| --- | --- |
| Status never leaves "Waiting for WoW" | WoW must be the Retail client under `_retail_` (or Classic under `_classic_*`). The log has a `[Poller] WoW processes {...}` line each time detection changes; `candidates` lists WoW-like processes that were not recognised. Send that line. |
| Error report "The recorder was not running when this activity started" | Same cause as above (WoW not detected), or the capture helper had just restarted (an earlier "Recording stopped unexpectedly" report). The video is kept but misses its first seconds. |
| Error report about Screen Recording | Section 2, reset and re-grant, relaunch. |
| Video is black | Screen Recording not effective (section 2), or WoW window not found: logs show `WoW window not found yet`. Try Monitor capture. |
| No game audio | Screen Recording covers system audio; reset and re-grant. If using an Application source, pick "World of Warcraft (any client)". |
| No microphone | System Settings > Privacy & Security > Microphone; check the selected device in Audio settings. |
| Recording never starts in a raid | Combat logging must be on; check that `WoWCombatLog-*.txt` grows in the Logs folder. Check "Record raids" and the minimum difficulty. |
| Helper self-test | `~/Applications/WarcraftRecorder.app/Contents/Resources/binaries/wcr-capture selftest /tmp/wcr-selftest` must print `"selftest":"pass"` (needs no permissions). |

## 9. Collect logs

- App log (includes the capture helper's output, prefixed `[wcr-capture]`): `~/Library/Logs/WarcraftRecorder/` (dev mode: `~/Library/Logs/Electron/`). The in-app "open logs" and diagnostics buttons point there.
- Config: `~/Library/Application Support/WarcraftRecorder/config-v3.json`.
- Permission state: `wcr-capture probe` prints `"permissions"`. Note this reflects the permission of whatever launched it (Terminal when run by hand).

Attach the newest log file (and the probe output if relevant) when reporting a failure. To print just the relevant lines of the newest log:

```bash
grep -E "\[(Manager|Recorder|MacNoobs|Poller|wcr-capture|LogHandler)\]" "$(ls -t ~/Library/Logs/WarcraftRecorder/*.log | head -1)" | tail -300
```

The app starts a new log file each launch, so if you relaunched after the failure, use the second newest file (`head -2 | tail -1`).

## Results checklist

| Step | Result | Notes |
| --- | --- | --- |
| 2. Permissions granted, no error reports | | |
| 4. Fake-WoW test recording with system audio + mic | | |
| 5. Raid encounter recorded and playable | | |
| 6. Mythic+ run recorded and playable | | |
| 7. Six audio tracks; game and mic both present | | |
| Permissions after installing a second build | | |
