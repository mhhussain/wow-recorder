/**
 * Recording start/stop state machine, driven by excerpts of real combat logs
 * (tests/fixtures/excerpts, built by tests/fixtures/make_excerpts.py) through
 * the real log handlers and activities. The recorder and the video processing
 * queue are mocked; expected outcomes are the upstream integration test
 * expectations in tests/src/<flavour>/<name>.py.
 */
import fs from 'fs';
import os from 'os';
import path from 'path';
import LogHandler from '../../parsing/LogHandler';
import RetailLogHandler from '../../parsing/RetailLogHandler';
import ClassicLogHandler from '../../parsing/ClassicLogHandler';
import EraLogHandler from '../../parsing/EraLogHandler';
import ConfigService from '../../config/ConfigService';
import Recorder from '../../main/Recorder';
import VideoProcessQueue from '../../main/VideoProcessQueue';
import { VideoQueueItem } from '../../main/types';

jest.mock('../../main/Recorder', () => {
  const calls: { method: string; arg?: number }[] = [];

  const recorder = {
    calls,
    startRecording: jest.fn(async (offset: number) => {
      calls.push({ method: 'startRecording', arg: offset });
    }),
    stop: jest.fn(async () => {
      calls.push({ method: 'stop' });
    }),
    startBuffer: jest.fn(async () => {
      calls.push({ method: 'startBuffer' });
    }),
    forceStop: jest.fn(async () => {}),
    getAndClearLastFile: jest.fn(() => '/buffer/2026-10-05 12-00-00.mp4'),
  };

  return { __esModule: true, default: { getInstance: () => recorder } };
});

jest.mock('../../main/VideoProcessQueue', () => {
  const queued: unknown[] = [];

  const queue = {
    queued,
    queueVideo: jest.fn((item: unknown) => queued.push(item)),
  };

  return { __esModule: true, default: { getInstance: () => queue } };
});

jest.mock('../../utils/Poller', () => ({
  __esModule: true,
  default: { getInstance: () => ({ isWowRunning: () => true }) },
}));

type MockRecorder = {
  calls: { method: string; arg?: number }[];
};

type MockQueue = { queued: VideoQueueItem[] };

const recorder = Recorder.getInstance() as unknown as MockRecorder;
const queue = VideoProcessQueue.getInstance() as unknown as MockQueue;
const fixtures = path.join(__dirname, '../../../tests/fixtures');

type Flavour = 'retail' | 'classic' | 'era';

/**
 * Feed a log through a fresh handler and return the videos it produced.
 */
const play = async (flavour: Flavour, name: string, file = 'excerpts') => {
  const logDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wcr-scenario-'));

  let handler: LogHandler;
  if (flavour === 'retail') handler = new RetailLogHandler(logDir);
  else if (flavour === 'classic') handler = new ClassicLogHandler(logDir);
  else handler = new EraLogHandler(logDir);

  const text = fs.readFileSync(
    path.join(fixtures, file, flavour, `${name}.txt`),
    'utf-8',
  );

  text
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => l)
    .forEach((l) => handler.combatLogWatcher.handleLogLine(l));

  // Activities wait out their overrun on a real timer (3 s even for raid
  // wipes); advance fake time until every queued line is processed.
  let drained = false;
  handler['logProcessQueue'].drain().then(() => {
    drained = true;
  });

  while (!drained) {
    await jest.advanceTimersByTimeAsync(1000);
  }

  // Some endings run outside the line queue (Classic arena team wipes call
  // endArena without awaiting it); let their overrun elapse too.
  for (let i = 0; i < 60 && LogHandler.overrunning; i++) {
    await jest.advanceTimersByTimeAsync(1000);
  }

  handler.destroy();

  return queue.queued.splice(0);
};

beforeAll(() => {
  const cfg = ConfigService.getInstance();
  // Overruns are real-time waits; they do not affect what is recorded.
  cfg.set('raidOverrun', 0);
  cfg.set('dungeonOverrun', 0);
  cfg.set('recordCurrentRaidEncountersOnly', false);
  LogHandler.setStateChangeCallback(() => {});
});

beforeEach(() => {
  jest.useFakeTimers();
  LogHandler.activity = undefined;
  LogHandler.overrunning = false;
  recorder.calls.splice(0);
  queue.queued.splice(0);
});

afterEach(() => {
  jest.useRealTimers();
});

const names = (videos: VideoQueueItem[]) => videos.map((v) => v.suffix);

const method = (m: string) => recorder.calls.filter((c) => c.method === m);

describe('retail raids', () => {
  test('wipe records one video', async () => {
    const videos = await play('retail', 'raid_wipe');

    expect(names(videos)).toEqual([
      'Alexsmite - Sepulcher of the First Ones, Lihuvim, Principal Architect [HC] (Wipe)',
    ]);

    const [video] = videos;
    expect(video.metadata.category).toBe('Raids');
    expect(video.metadata.result).toBe(false);
    expect(video.duration).toBeGreaterThan(15);
    expect(video.offset).toBe(0);
    expect(video.source).toBe('/buffer/2026-10-05 12-00-00.mp4');

    // Converted the buffer once, stopped once, and re-armed the buffer
    // because WoW is still running.
    expect(method('startRecording')).toHaveLength(1);
    expect(method('stop')).toHaveLength(1);
    expect(method('startBuffer')).toHaveLength(1);
    expect(LogHandler.activity).toBeUndefined();
  });

  test('reset is started but discarded', async () => {
    const videos = await play('retail', 'raid_reset');
    expect(videos).toEqual([]);
    expect(method('startRecording')).toHaveLength(1);
    expect(method('stop')).toHaveLength(1);
  });

  test('unknown encounter uses the log name', async () => {
    const videos = await play('retail', 'raid_unknown_encounter');
    expect(names(videos)).toEqual([
      'Alexsmite - Void Lord Top Dog [HC] (Wipe)',
    ]);
  });

  test('holy priest Restitution counts as a death', async () => {
    const videos = await play('retail', 'raid_holy_priest_angel_death');
    expect(names(videos)).toEqual([
      'Alexsmite - Void Lord Top Dog [HC] (Wipe)',
    ]);
    expect(videos[0].metadata.deaths).toHaveLength(21);
  });

  test("Belo'ren mythic wipe", async () => {
    const videos = await play('retail', 'beloren_boss_hp');
    expect(names(videos)).toEqual([
      "Vutar - Belo'ren, Child of Al'ar [M] (Wipe)",
    ]);
  });

  test('Coiled Altar heroic wipe', async () => {
    const videos = await play('retail', 'coiled_altar_boss_hp');
    expect(names(videos)).toEqual(['Vutar - The Coiled Altar [HC] (Wipe)']);
  });

  test('minimum duration discards short encounters', async () => {
    ConfigService.getInstance().set('minEncounterDuration', 100000);

    try {
      const videos = await play('retail', 'raid_wipe');
      expect(videos).toEqual([]);
      expect(method('stop')).toHaveLength(1);
    } finally {
      ConfigService.getInstance().set('minEncounterDuration', 15);
    }
  });

  test('raids can be disabled', async () => {
    ConfigService.getInstance().set('recordRaids', false);

    try {
      const videos = await play('retail', 'raid_wipe');
      expect(videos).toEqual([]);
      expect(method('startRecording')).toHaveLength(0);
    } finally {
      ConfigService.getInstance().set('recordRaids', true);
    }
  });
});

describe('retail mythic+', () => {
  test('abandoned run', async () => {
    const videos = await play('retail', 'mythic_plus');
    expect(names(videos)).toEqual([
      'Arcanedemon - The Stonevault +10 (Abandoned)',
    ]);
    expect(videos[0].metadata.category).toBe('Mythic+');
    expect(videos[0].metadata.keystoneLevel).toBe(10);
  });

  test('abandoned key then a timed lower key', async () => {
    const videos = await play('retail', 'mythic_plus_drop_go');

    // Chronological. Upstream's expectation lists newest first.
    expect(names(videos)).toEqual([
      'Vutar - Dawn of the Infinite +21 (Abandoned)',
      'Vutar - Dawn of the Infinite +20 (+1)',
    ]);

    expect(method('startRecording')).toHaveLength(2);
  });

  test('zoning out and back in keeps one recording', async () => {
    const videos = await play('retail', 'mythic_plus_repair');
    expect(names(videos)).toEqual(['Vutar - Dawn of the Infinite +18 (+3)']);

    const bosses = (videos[0].metadata.challengeModeTimeline ?? []).filter(
      (s) => s.segmentType === 'Boss',
    );

    expect(bosses).toHaveLength(4);
    expect(method('startRecording')).toHaveLength(1);
  });

  test('force stop ends a run with no boss pulls', async () => {
    const videos = await play('retail', 'mythic_plus_no_boss');
    expect(names(videos)).toEqual([
      'Arcanedemon - The Stonevault +10 (Abandoned)',
    ]);
  });

  test('ditching a key into a raid records both', async () => {
    const videos = await play('retail', 'mythic_plus_ditch_into_raid');

    expect(names(videos)).toEqual([
      'Arcanedemon - The Stonevault +10 (Abandoned)',
      'Alexsmite - Sepulcher of the First Ones, Lihuvim, Principal Architect [HC] (Wipe)',
    ]);
  });

  test('keys below the minimum level are not recorded', async () => {
    ConfigService.getInstance().set('minKeystoneLevel', 11);

    try {
      const videos = await play('retail', 'mythic_plus');
      expect(videos).toEqual([]);
      expect(method('startRecording')).toHaveLength(0);
    } finally {
      ConfigService.getInstance().set('minKeystoneLevel', 2);
    }
  });
});

describe('retail other', () => {
  test('zone changes alone record nothing', async () => {
    const videos = await play('retail', 'zone_changes');
    expect(videos).toEqual([]);
    expect(method('startRecording')).toHaveLength(0);
  });
});

describe('classic and era', () => {
  test('classic raid kill', async () => {
    const videos = await play('classic', 'raid');
    expect(names(videos)).toEqual([
      "Alexpals - Naxxramas, Anub'Rekhan [25N] (Kill)",
    ]);
  });

  test('classic MoP challenge mode', async () => {
    const videos = await play('classic', 'mop_challenge_mode');
    expect(names(videos)).toEqual(['Desiredcell - Scholomance +0 (+3)']);
  });

  test('era raid kill', async () => {
    const videos = await play('era', 'raid');
    expect(names(videos)).toEqual([
      'Flakeshock - Mekgineer Thermaplugg [10N] (Kill)',
    ]);
  });
});

/**
 * The same scenarios against the full logs, when present (CI skips them via
 * sparse checkout). Proves the excerpts are faithful and checks boss health,
 * which the excerpts do not carry.
 */
const fullLogs = path.join(fixtures, 'combatlogs');
const haveFullLogs = fs.existsSync(path.join(fullLogs, 'retail/raid_wipe.txt'));

(haveFullLogs ? describe : describe.skip)('full logs', () => {
  const scenarios: [Flavour, string][] = [
    ['retail', 'raid_wipe'],
    ['retail', 'raid_reset'],
    ['retail', 'raid_unknown_encounter'],
    ['retail', 'raid_holy_priest_angel_death'],
    ['retail', 'beloren_boss_hp'],
    ['retail', 'coiled_altar_boss_hp'],
    ['retail', 'mythic_plus'],
    ['retail', 'mythic_plus_drop_go'],
    ['retail', 'mythic_plus_repair'],
    ['retail', 'mythic_plus_no_boss'],
    ['retail', 'mythic_plus_ditch_into_raid'],
    ['retail', 'zone_changes'],
    ['classic', 'raid'],
    ['classic', 'mop_challenge_mode'],
    ['era', 'raid'],
  ];

  test.each(scenarios)(
    '%s/%s matches its excerpt',
    async (flavour, name) => {
      const excerpt = names(await play(flavour, name));
      const full = names(await play(flavour, name, 'combatlogs'));
      expect(full).toEqual(excerpt);
    },
    120000,
  );

  test.each([
    ['beloren_boss_hp', 45],
    ['coiled_altar_boss_hp', 17],
  ])(
    '%s boss health is %i%%',
    async (name, hp) => {
      const [video] = await play('retail', name as string, 'combatlogs');
      expect(video.metadata.bossPercent).toBe(hp);
    },
    120000,
  );
});

/**
 * PvP (post-MVP, phase 7). These logs are small, so they run unexcerpted;
 * CI's sparse checkout includes them.
 */
const havePvpLogs = fs.existsSync(path.join(fullLogs, 'retail/rated_2v2.txt'));

(havePvpLogs ? describe : describe.skip)('pvp (full logs)', () => {
  const pvp: [Flavour, string, string[]][] = [
    ['retail', 'rated_2v2', ['Alexhots - 2v2 Enigma Crucible (Win)']],
    ['retail', 'rated_2v2_afk_out', ['Alexhots - 2v2 Enigma Crucible (Loss)']],
    ['retail', 'rated_3v3', ["Alexsmite - 3v3 Tol'viron (Loss)"]],
    ['retail', 'rated_battleground', ['Alexsmite - Temple of Kotmogu (Loss)']],
    [
      'retail',
      'rated_solo_shuffle',
      ["Alexsmite - Solo Shuffle Tiger's Peak (3-3)"],
    ],
    ['retail', 'skirmish', ['Alexsmite - Skirmish Nagrand (Win)']],
    ['retail', 'wargame_3v3', ["Alexsmite - 3v3 Tol'viron (Loss)"]],
    ['classic', 'rated_2v2', ["Alexpals - 2v2 Blade's Edge (Win)"]],
    ['classic', 'rated_3v3', ['Alexpals - 3v3 Dalaran (Win)']],
    ['classic', 'rated_5v5', ['Alexpals - 5v5 Ruins of Lordaeron (Loss)']],
    ['classic', 'battleground', ['Alexpals - Warsong Gulch (Loss)']],
    ['classic', 'rated_2v2_extra_units', ['Jammln - 2v2 Dalaran (Loss)']],
    ['classic', 'rated_2v2_feign_death', ['Jammln - 2v2 Nagrand (Win)']],
  ];

  test.each(pvp)(
    '%s/%s',
    async (flavour, name, expected) => {
      const videos = await play(flavour, name, 'combatlogs');
      expect(names(videos)).toEqual(expected);
    },
    120000,
  );
});
