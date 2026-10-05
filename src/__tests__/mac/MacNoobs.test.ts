import { EventEmitter } from 'events';
import MacNoobs, { MacEncoders } from '../../main/mac/MacNoobs';
import CaptureHelper, {
  DeviceList,
  HelperTransport,
} from '../../main/mac/CaptureHelper';
import { Signal } from '../../main/mac/noobsTypes';
import { AudioSourceType } from '../../main/types';

/**
 * Records commands instead of talking to the Swift helper.
 */
class FakeTransport extends EventEmitter implements HelperTransport {
  public sent: { cmd: string; payload: Record<string, unknown> }[] = [];

  public running = false;

  public starts = 0;

  public devices: DeviceList = {
    displays: [],
    mics: [{ id: 'mic-1', name: 'Studio Mic' }],
    defaultMic: 'mic-1',
    apps: [
      { bundleId: 'com.hnc.Discord', name: 'Discord', pid: 1, wow: false },
      {
        bundleId: 'com.blizzard.worldofwarcraft',
        name: 'World of Warcraft',
        pid: 2,
        wow: true,
      },
    ],
  };

  start() {
    this.running = true;
    this.starts++;
  }

  stop() {
    this.running = false;
  }

  isRunning() {
    return this.running;
  }

  async send(cmd: string, payload: Record<string, unknown> = {}) {
    this.sent.push({ cmd, payload });
    return null;
  }

  listDevicesSync() {
    return this.devices;
  }

  async listDevices() {
    return this.devices;
  }

  commands() {
    return this.sent.map((s) => s.cmd);
  }
}

const tick = () => new Promise((resolve) => setImmediate(resolve));

const setup = () => {
  const transport = new FakeTransport();
  const signals: Signal[] = [];

  const noobs = new MacNoobs({
    transport,
    excludeBundlePrefix: 'org.WarcraftRecorder',
    getDisplays: () => [
      { id: 1, label: 'Display 1 (3440x1440)' },
      { id: 3, label: 'Display 2 (3440x1440)' },
    ],
  });

  noobs.Init('', '', (s) => signals.push(s));
  return { transport, noobs, signals };
};

test('builds the helper config from the scene', () => {
  const { noobs } = setup();

  noobs.SetRecordingCfg('/tmp/buffer', 'mp4');
  noobs.ResetVideoContext(30, 3440, 1440);
  noobs.SetVideoEncoder(MacEncoders.HEVC, { keyint_sec: 1, quality: 0.7 });

  const game = noobs.CreateSource('WCR Game Capture', 'game_capture');
  noobs.AddSourceToScene(game);

  const sys = noobs.CreateSource('WCR Audio Source 1', AudioSourceType.OUTPUT);
  noobs.AddSourceToScene(sys);
  noobs.SetSourceAudioTracks(sys, 0b11);

  const mic = noobs.CreateSource('WCR Audio Source 2', AudioSourceType.INPUT);
  noobs.SetSourceSettings(mic, { device_id: 'mic-1' });
  noobs.SetSourceVolume(mic, 0.5);
  noobs.AddSourceToScene(mic);

  const app = noobs.CreateSource('WCR Audio Source 3', AudioSourceType.PROCESS);
  noobs.AddSourceToScene(app); // No application chosen yet: skipped.

  noobs.SetForceMono(true);
  noobs.SetMuteAudioInputs(true);

  const config = noobs.buildConfig();

  expect(config).toMatchObject({
    outputDir: '/tmp/buffer',
    fps: 30,
    width: 3440,
    height: 1440,
    encoder: MacEncoders.HEVC,
    quality: 0.7,
    video: { kind: 'wow', showCursor: true },
    forceMono: true,
    muteInputs: true,
    excludeBundlePrefix: 'org.WarcraftRecorder',
  });

  expect(config.audio).toEqual([
    {
      name: 'WCR Audio Source 1',
      kind: 'system',
      device: 'default',
      volume: 1,
      tracks: 3,
    },
    {
      name: 'WCR Audio Source 2',
      kind: 'mic',
      device: 'mic-1',
      volume: 0.5,
      tracks: 1,
    },
  ]);

  noobs.SetSourceSettings(app, { window: 'wow' });
  expect(noobs.buildConfig().audio[2]).toMatchObject({
    kind: 'app',
    device: 'wow',
  });
});

test('monitor capture targets the configured display', () => {
  const { noobs } = setup();
  const monitor = noobs.CreateSource('WCR Monitor Capture', 'monitor_capture');
  const props = noobs.GetSourceProperties(monitor);
  const list = props.find((p) => p.name === 'monitor_id');

  expect(list?.type).toBe('list');
  if (list?.type !== 'list') return;
  expect(list.items.map((i) => i.value)).toEqual(['1', '3']);

  noobs.SetSourceSettings(monitor, {
    monitor_id: list.items[1].value,
    capture_cursor: false,
  });

  noobs.AddSourceToScene(monitor);

  expect(noobs.buildConfig().video).toEqual({
    kind: 'display',
    displayId: 3,
    showCursor: false,
  });
});

test('device lists come from the helper', () => {
  const { noobs } = setup();
  const mic = noobs.CreateSource('mic', AudioSourceType.INPUT);
  const app = noobs.CreateSource('app', AudioSourceType.PROCESS);

  const micList = noobs.GetSourceProperties(mic)[0];
  const appList = noobs.GetSourceProperties(app)[0];

  expect(micList.type === 'list' && micList.items.map((i) => i.value)).toEqual([
    'default',
    'mic-1',
  ]);

  // WoW is offered once as a generic entry, not per running client.
  expect(appList.type === 'list' && appList.items.map((i) => i.value)).toEqual([
    'wow',
    'com.hnc.Discord',
  ]);
});

test('source names are made unique like OBS does', () => {
  const { noobs } = setup();
  expect(noobs.CreateSource('A', AudioSourceType.INPUT)).toBe('A');
  expect(noobs.CreateSource('A', AudioSourceType.INPUT)).toBe('A 2');
  expect(noobs.CreateSource('A', AudioSourceType.INPUT)).toBe('A 3');
});

test('state is flushed before recording commands, in order', async () => {
  const { noobs, transport } = setup();
  await tick();
  transport.sent = [];

  noobs.SetRecordingCfg('/tmp/buffer', 'mp4');
  noobs.StartBuffer();
  noobs.StartRecording(12.5);
  noobs.StopRecording();
  await tick();

  expect(transport.commands()).toEqual([
    'configure',
    'startBuffer',
    'convert',
    'stop',
  ]);

  expect(transport.sent[2].payload).toEqual({ offset: 12.5 });
});

test('changes in one tick coalesce into one configure', async () => {
  const { noobs, transport } = setup();
  await tick();
  transport.sent = [];

  noobs.SetForceMono(true);
  noobs.SetAudioSuppression(true);
  noobs.SetMuteAudioInputs(false);
  await tick();

  expect(transport.commands()).toEqual(['configure']);
});

test('deactivate signals carry the last recording', () => {
  const { noobs, transport, signals } = setup();

  transport.emit('signal', { type: 'output', id: 'start', code: 0 });

  transport.emit('signal', {
    type: 'output',
    id: 'deactivate',
    code: 0,
    path: '/tmp/buffer/2026-10-05 12-00-00.mp4',
  });

  expect(noobs.GetLastRecording()).toBe('/tmp/buffer/2026-10-05 12-00-00.mp4');
  expect(signals.map((s) => s.id)).toEqual(['start', 'deactivate']);
});

test('helper missing: start fails fast with an explanation', async () => {
  const { noobs, transport, signals } = setup();
  transport.running = false;

  noobs.StartBuffer();
  await tick();

  expect(signals).toHaveLength(1);
  expect(signals[0]).toMatchObject({ id: 'deactivate', code: -1 });
  expect(signals[0].error).toMatch(/build:native/);
});

test('helper crash while buffering: deactivate, restart, resume', async () => {
  jest.useFakeTimers();

  try {
    const { transport, signals } = setup();
    transport.emit('signal', { type: 'output', id: 'start', code: 0 });

    transport.running = false;
    transport.emit('exit', 1);

    expect(signals.at(-1)).toMatchObject({ id: 'deactivate', code: -1 });

    transport.sent = [];
    jest.advanceTimersByTime(1000);

    expect(transport.starts).toBe(2);
    expect(transport.commands()).toEqual(['configure', 'startBuffer']);
  } finally {
    jest.useRealTimers();
  }
});

test('helper protocol lines are parsed into signals and responses', async () => {
  const helper = new CaptureHelper('/nonexistent');
  const signals: Signal[] = [];
  helper.on('signal', (s) => signals.push(s));

  helper.handleLine(
    '{"event":"signal","type":"output","id":"converted","code":0,"path":"/x.mp4"}',
  );

  helper.handleLine(
    '{"event":"signal","type":"volmeter","id":"WCR Audio Source 1","code":0,"value":0.25}',
  );

  expect(signals).toEqual([
    { type: 'output', id: 'converted', code: 0, path: '/x.mp4' },
    { type: 'volmeter', id: 'WCR Audio Source 1', code: 0, value: 0.25 },
  ]);

  expect(
    CaptureHelper.parseDeviceList('{"mics":[{"id":"a","name":"A"}]}\n'),
  ).toMatchObject({ mics: [{ id: 'a', name: 'A' }], apps: [], displays: [] });
});
