import EventEmitter from 'events';
import { execFile } from 'child_process';
import ConfigService from 'config/ConfigService';
import { WowProcessEvent } from 'main/types';

export type WowProcessState = { Retail: boolean; Classic: boolean };

/**
 * Folder names under the WoW install that hold each client. On macOS the
 * executable lives at e.g.
 *   /Applications/World of Warcraft/_retail_/World of Warcraft.app/Contents/MacOS/World of Warcraft
 */
const retailFolders = ['_retail_', '_ptr_', '_xptr_', '_beta_'];

const classicFolders = [
  '_classic_',
  '_classic_era_',
  '_classic_ptr_',
  '_classic_era_ptr_',
  '_classic_beta_',
  '_anniversary_',
];

/**
 * Process listing command. `-ww` asks for unlimited width so a long
 * executable path is never cut to the terminal width (the app may be
 * started from a terminal in dev mode).
 */
export const psCommand = '/bin/ps';
export const psArgs = ['-axww', '-o', 'comm='];

/**
 * Decide which WoW flavours are running from `ps -axww -o comm=` output
 * (one executable path per line). Exported for tests.
 */
export const parseWowProcesses = (psOutput: string): WowProcessState => {
  const state: WowProcessState = { Retail: false, Classic: false };

  psOutput.split('\n').forEach((raw) => {
    const exe = raw.trim();
    const name = exe.split('/').pop() ?? '';

    // ps reports argv[0], normally the full path; a launcher may pass a
    // bare name instead, which still identifies the client.
    const isClient =
      (exe.includes('.app/Contents/MacOS/') || !exe.includes('/')) &&
      name.startsWith('World of Warcraft') &&
      !/helper|launcher|crash|error/i.test(name);

    if (!isClient) return;

    const folders = exe.split('/');

    if (folders.some((f) => classicFolders.includes(f))) {
      state.Classic = true;
    } else if (folders.some((f) => retailFolders.includes(f))) {
      state.Retail = true;
    } else if (name.includes('Classic')) {
      // Non-standard install location: fall back to the app name.
      state.Classic = true;
    } else {
      state.Retail = true;
    }
  });

  return state;
};

/**
 * Lines that look WoW related, for diagnosing a client the parser does not
 * recognise.
 */
const wowLikeProcesses = (psOutput: string) =>
  psOutput
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => /warcraft/i.test(l) && !l.includes('WarcraftRecorder'));

/**
 * The Poller singleton periodically checks the list of WoW active
 * processes. If the state changes, it emits a WowProcessEvent.
 *
 * macOS: polls `ps` every two seconds (upstream used a Windows-only Rust
 * binary). Setting WCR_FAKE_WOW=retail or WCR_FAKE_WOW=classic pretends
 * that client is running, for testing the recorder without WoW.
 */
export default class Poller extends EventEmitter {
  /**
   * Singleton instance.
   */
  private static instance: Poller;

  /**
   * Config service handle.
   */
  private cfg: ConfigService = ConfigService.getInstance();

  /**
   * If a WoW process is running AND the corresponding record config is
   * enabled. Includes various flavours of retail, classic and era.
   */
  private wowRunning = false;

  /**
   * Polling timer.
   */
  private timer: NodeJS.Timeout | undefined;

  /**
   * False after stop(), so a ps call still in flight is ignored.
   */
  private polling = false;

  private pollIntervalMs = 2000;

  /**
   * Last process snapshot logged, to log changes only.
   */
  private lastLogged = '';

  /**
   * Create or get the singleton.
   */
  static getInstance() {
    if (!Poller.instance) Poller.instance = new Poller();
    return Poller.instance;
  }

  /**
   * Private constructor as part of the singleton pattern.
   */
  private constructor() {
    super();
  }

  /**
   * Convienence method to check if WoW is running. Only returns true if WoW
   * is running, and the configuration is setup to record that flavour of WoW.
   */
  public isWowRunning() {
    return this.wowRunning;
  }

  /**
   * Stop the poller and reset the state.
   */
  public stop() {
    console.info('[Poller] Stop process poller');
    this.wowRunning = false;
    this.polling = false;
    this.lastLogged = '';

    if (this.timer) {
      clearInterval(this.timer);
      this.timer = undefined;
    }
  }

  /**
   * Start the poller.
   */
  public start() {
    this.stop();
    console.info('[Poller] Start process poller');
    this.polling = true;
    this.poll();
    this.timer = setInterval(() => this.poll(), this.pollIntervalMs);
  }

  private poll() {
    const fake = process.env.WCR_FAKE_WOW;

    if (fake) {
      this.handleProcessState({
        Retail: fake === 'retail',
        Classic: fake === 'classic',
      });

      return;
    }

    execFile(
      psCommand,
      psArgs,
      { maxBuffer: 4 * 1024 * 1024 },
      (error, stdout) => {
        if (error) {
          console.warn('[Poller] ps failed', String(error));
          return;
        }

        const state = parseWowProcesses(stdout);
        this.logSnapshot(state, wowLikeProcesses(stdout));
        this.handleProcessState(state);
      },
    );
  }

  /**
   * Log what was detected whenever it changes, including WoW-like processes
   * that were not recognised as a client.
   */
  private logSnapshot(state: WowProcessState, candidates: string[]) {
    const snapshot = JSON.stringify({ ...state, candidates });
    if (snapshot === this.lastLogged) return;
    this.lastLogged = snapshot;

    console.info('[Poller] WoW processes', snapshot);
  }

  /**
   * Apply a process snapshot. We don't care to do anything better in the
   * scenario of multiple processes running. We don't support users
   * multi-boxing.
   */
  public handleProcessState({ Retail, Classic }: WowProcessState) {
    if (!this.polling) {
      // A poll that completed after stop(); ignore it.
      return;
    }

    const recordRetail = this.cfg.get<boolean>('recordRetail');
    const recordRetailPtr = this.cfg.get<boolean>('recordRetailPtr');
    const recordClassic = this.cfg.get<boolean>('recordClassic');
    const recordClassicPtr = this.cfg.get<boolean>('recordClassicPtr');
    const recordEra = this.cfg.get<boolean>('recordEra');

    const running =
      ((recordRetail || recordRetailPtr) && Retail) ||
      ((recordClassic || recordClassicPtr || recordEra) && Classic);

    if (this.wowRunning === running) {
      // Nothing to emit.
      return;
    }

    // Update before emitting: handlers ask isWowRunning(), e.g. ending an
    // activity on WoW exit decides whether to re-arm the buffer.
    this.wowRunning = running;

    if (running) {
      this.emit(WowProcessEvent.STARTED);
    } else {
      this.emit(WowProcessEvent.STOPPED);
    }
  }
}
