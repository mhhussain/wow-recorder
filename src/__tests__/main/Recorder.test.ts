/**
 * Recorder buffer handling against a fake capture backend: what happens
 * when an activity starts while the buffer is down, and when the buffer
 * drops without anyone asking.
 */
import Recorder from '../../main/Recorder';
import { ERecordingState } from '../../main/obsEnums';
import { Signal } from '../../main/mac/noobsTypes';
import { send } from 'main/main';

type FakeState = {
  cb?: (s: Signal) => void;
  calls: string[];
  sources: string[];
};

jest.mock('../../main/mac/noobs', () => {
  const state: FakeState = { calls: [], sources: [] };

  const impl: Record<string | symbol, unknown> = {
    fake: state,
    Init: (_a: string, _b: string, cb: (s: Signal) => void) => {
      state.cb = cb;
    },
    StartBuffer: () => {
      state.calls.push('StartBuffer');
      setImmediate(() => state.cb?.({ type: 'output', id: 'start', code: 0 }));
    },
    StartRecording: (offset: number) => {
      state.calls.push(`StartRecording ${offset}`);
    },
    CreateSource: (name: string) => {
      state.sources.push(name);
      return name;
    },
    GetSourceSettings: () => ({}),
    GetSourceProperties: () => [
      {
        name: 'device_id',
        type: 'list',
        items: [{ name: 'Default', value: 'default' }],
      },
    ],
  };

  // Every other noobs call is a no-op.
  const noobs = new Proxy(impl, {
    get: (target, prop) => (prop in target ? target[prop] : () => undefined),
  });

  return { __esModule: true, default: noobs };
});

const fake = require('../../main/mac/noobs').default.fake as FakeState;

const errorReports = () =>
  (send as jest.Mock).mock.calls
    .filter(([channel]) => channel === 'updateErrorReport')
    .map(([, report]) => String(report.reason));

// The Recorder's interval and timeout guards would keep Jest alive; the
// fake backend answers via setImmediate, which stays real.
jest.useFakeTimers({
  doNotFake: ['setImmediate', 'nextTick', 'queueMicrotask'],
});

describe('Recorder buffer', () => {
  const recorder = Recorder.getInstance();

  beforeAll(() => {
    recorder.initializeObs();
  });

  beforeEach(() => {
    fake.calls.splice(0);
    fake.sources.splice(0);
    (send as jest.Mock).mockClear();
  });

  test('an activity starting while the buffer is down starts it and records', async () => {
    expect(recorder.obsState).toBe(ERecordingState.None);

    await recorder.startRecording(4.4);

    expect(fake.calls).toEqual(['StartBuffer', 'StartRecording 4']);
    expect(recorder.obsState).toBe(ERecordingState.Recording);
    // The audio sources were attached, since WoW start never did it.
    expect(fake.sources.length).toBeGreaterThan(0);
    expect(errorReports()).toEqual([
      expect.stringContaining('was not running when this activity started'),
    ]);
  });

  test('with the buffer running, recording just converts it', async () => {
    await recorder.startRecording(2);
    expect(fake.calls).toEqual(['StartRecording 2']);
    expect(errorReports()).toEqual([]);
  });

  test('an unrequested buffer loss is reported', () => {
    fake.cb?.({
      type: 'output',
      id: 'deactivate',
      code: -1,
      error: 'Capture helper exited unexpectedly',
    });

    expect(recorder.obsState).toBe(ERecordingState.None);
    expect(errorReports()).toEqual([
      'Recording stopped unexpectedly: Capture helper exited unexpectedly',
    ]);
  });

  test('a requested stop is not reported', () => {
    fake.cb?.({ type: 'output', id: 'deactivate', code: 0, path: '' });
    expect(errorReports()).toEqual([]);
  });
});
