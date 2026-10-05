/**
 * End-to-end check of the TypeScript shim against the real Swift helper:
 * spawn binaries/wcr-capture through CaptureHelper, drive it with MacNoobs
 * exactly as Recorder does, and check the file it writes. No capture
 * sources are configured (black frames, silent tracks), so no privacy
 * permission is needed. Runs on macOS once `npm run build:native` has built
 * the helper; skipped elsewhere.
 */
import fs from 'fs';
import os from 'os';
import path from 'path';
import { execFileSync } from 'child_process';
import CaptureHelper from '../../main/mac/CaptureHelper';
import MacNoobs, { MacEncoders } from '../../main/mac/MacNoobs';
import { Signal } from '../../main/mac/noobsTypes';

const binary = path.join(__dirname, '../../../binaries/wcr-capture');
const ffmpeg = path.join(__dirname, '../../../binaries/ffmpeg');
const available = process.platform === 'darwin' && fs.existsSync(binary);

const waitForSignal = (signals: Signal[], id: string, ms = 20000) =>
  new Promise<Signal>((resolve, reject) => {
    const deadline = Date.now() + ms;

    const check = () => {
      const index = signals.findIndex((s) => s.id === id);

      if (index >= 0) {
        resolve(signals.splice(index, 1)[0]);
      } else if (Date.now() > deadline) {
        reject(new Error(`No ${id} signal`));
      } else {
        setTimeout(check, 50);
      }
    };

    check();
  });

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

(available ? describe : describe.skip)('capture helper integration', () => {
  let noobs: MacNoobs;
  const signals: Signal[] = [];
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wcr-helper-'));

  beforeAll(() => {
    noobs = new MacNoobs({
      transport: new CaptureHelper(binary),
      excludeBundlePrefix: 'org.WarcraftRecorder',
      getDisplays: () => [],
    });

    noobs.Init('', '', (s) => signals.push(s));
  });

  afterAll(async () => {
    noobs.Shutdown();
    await sleep(500);
  });

  test('buffer, convert with offset, stop produces a recording', async () => {
    // Mirror Recorder.configureBase.
    noobs.ResetVideoContext(30, 1280, 720);
    noobs.SetRecordingCfg(dir, 'mp4');
    noobs.SetVideoEncoder(MacEncoders.H264, { keyint_sec: 1, quality: 0.6 });

    noobs.StartBuffer();
    expect(await waitForSignal(signals, 'start')).toMatchObject({ code: 0 });

    await sleep(3000);
    noobs.StartRecording(2);
    const converted = await waitForSignal(signals, 'converted');
    expect(converted.path).toMatch(/\d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}\.mp4$/);

    await sleep(2000);
    noobs.StopRecording();
    const deactivate = await waitForSignal(signals, 'deactivate');

    expect(deactivate.code).toBe(0);
    expect(noobs.GetLastRecording()).toBe(converted.path);
    expect(fs.statSync(converted.path as string).size).toBeGreaterThan(0);

    if (fs.existsSync(ffmpeg)) {
      // ffmpeg prints stream info to stderr and exits non-zero without an
      // output file; capture it either way.
      let info = '';

      try {
        execFileSync(ffmpeg, ['-hide_banner', '-i', converted.path as string]);
      } catch (error) {
        info = String((error as { stderr?: Buffer }).stderr ?? '');
      }

      expect(info.match(/Video: h264/g)).toHaveLength(1);
      expect(info.match(/Audio: aac/g)).toHaveLength(6);

      const seconds = info.match(/Duration: 00:00:(\d+\.\d+)/);
      expect(seconds).not.toBeNull();
      // ~2 s of buffer plus ~2 s of recording, keyframe aligned.
      expect(Number(seconds?.[1])).toBeGreaterThan(3);
      expect(Number(seconds?.[1])).toBeLessThan(6);
    }
  }, 60000);

  test('stop without a recording reports no file', async () => {
    noobs.StartBuffer();
    await waitForSignal(signals, 'start');
    await sleep(500);
    noobs.StopRecording();
    await waitForSignal(signals, 'deactivate');
    expect(noobs.GetLastRecording()).toBe('');
  }, 30000);

  test('device listing works without permissions', async () => {
    await noobs.RefreshDevices();
    const mic = noobs.CreateSource('mic', 'wasapi_input_capture');
    const props = noobs.GetSourceProperties(mic)[0];
    expect(props.type).toBe('list');
    noobs.DeleteSource(mic);
  });
});
