import { EventEmitter } from 'stream';
import fs, { watch, FSWatcher } from 'fs';
import path from 'path';
import { getSortedFiles } from '../main/util';
import LogLine from './LogLine';
import AsyncQueue from 'utils/AsyncQueue';

/**
 * What we remember about each log file between reads.
 */
type TrackedFile = {
  size: number;
  ino: number;
};

/**
 * Watches a directory for combat logs, read the new data from them
 * and emits events containing a LogLine object for processing elsewhere.
 *
 * macOS port: reads are driven by stat() rather than by the watcher's event
 * type. Node's fs.watch on macOS sits on FSEvents, which coalesces events
 * and can report writes to a recently created file as 'rename'. Upstream
 * treated 'rename' as "file recreated, reset to byte 0", which on macOS
 * could replay a whole log or never read it. Instead every event (and a
 * one second poll of the active file, as a backstop for coalesced events)
 * triggers a stat: growth is read incrementally, a shrink or a new inode
 * means the file was truncated or recreated and is read from the start
 * (upstream issue 624). Partial trailing lines are carried over to the next
 * read rather than parsed early.
 */
export default class CombatLogWatcher extends EventEmitter {
  /**
   * The directory to watch for logs.
   */
  private logDir: string;

  /**
   * The watcher object itself.
   */
  private watcher?: FSWatcher;

  /**
   * Backstop poll of the active log file.
   */
  private pollTimer?: NodeJS.Timeout;

  private pollIntervalMs: number;

  /**
   * Set by unwatch(). watch() is async, so unwatch() can run before it has
   * created the watcher; this stops it creating one afterwards.
   */
  private stopped = false;

  /**
   * We need to keep track of some info about each log file to know how much we
   * should read.
   */
  private state: Record<string, TrackedFile> = {};

  /**
   * Incomplete final line from the last read of each file, kept as bytes so
   * a multi-byte UTF-8 character split across reads decodes correctly.
   */
  private remainders: Record<string, Buffer> = {};

  /**
   * A promise queue we use to ensure that we only have one active attempt to
   * parse the file at a time.
   */
  private queue = new AsyncQueue(Number.MAX_SAFE_INTEGER);

  /**
   * The most recently updated log file, polled as a backstop and logged
   * when it changes.
   */
  private current = '';

  /**
   * Constructor. No events will be emitted until watch() is called.
   */
  constructor(logDir: string, pollIntervalMs = 1000) {
    super();
    this.logDir = logDir;
    this.pollIntervalMs = pollIntervalMs;
  }

  /**
   * Start watching the directory.
   */
  public async watch() {
    this.stopped = false;
    await this.getLogDirectoryState();

    if (this.stopped) {
      return;
    }

    this.watcher = watch(this.logDir);

    this.watcher.on('change', (_type, file) => {
      if (typeof file !== 'string') {
        return;
      }

      if (!file.startsWith('WoWCombatLog')) {
        return;
      }

      if (file !== this.current) {
        console.info('[CombatLogWatcher] New active log file', file);
        this.current = file;
      }

      this.queueProcess(file);
    });

    this.watcher.on('error', (error) => {
      console.error('[CombatLogWatcher] Watcher error', String(error));
    });

    this.pollTimer = setInterval(() => {
      if (this.current) this.queueProcess(this.current);
    }, this.pollIntervalMs);
  }

  /**
   * Stop watching the directory.
   */
  public async unwatch() {
    this.stopped = true;

    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = undefined;
    }

    if (this.watcher) {
      this.watcher.close();
      this.watcher = undefined;
    }
  }

  private queueProcess(file: string) {
    this.queue.add(() => this.process(file));
  }

  /**
   * We need this in-case WCR is launched mid activity where a partial log file
   * already exists.
   */
  private async getLogDirectoryState() {
    const logs = await getSortedFiles(this.logDir, 'WoWCombatLog.*.txt');

    await Promise.all(
      logs.map(async (log) => {
        try {
          const stat = await fs.promises.stat(log.name);
          this.state[log.name] = { size: stat.size, ino: stat.ino };
        } catch {
          // Deleted while listing; nothing to track.
        }
      }),
    );

    if (logs.length > 0) {
      // getSortedFiles returns newest first.
      this.current = path.basename(logs[0].name);
    }
  }

  /**
   * Read whatever is new in a log file. Public for tests.
   */
  public async process(file: string) {
    const fullPath = path.join(this.logDir, file);
    let stat: fs.Stats;

    try {
      stat = await fs.promises.stat(fullPath);
    } catch {
      // Deleted. Forget it so a recreated file is read from the start.
      delete this.state[fullPath];
      delete this.remainders[fullPath];
      return;
    }

    const last = this.state[fullPath];
    let start = 0;

    if (last && last.ino === stat.ino && stat.size >= last.size) {
      start = last.size;
    } else if (last) {
      console.info('[CombatLogWatcher] Log truncated or replaced', file);
      delete this.remainders[fullPath];
    }

    this.state[fullPath] = { size: stat.size, ino: stat.ino };
    const bytes = stat.size - start;

    if (bytes < 1) {
      // Duplicate event or poll with nothing new.
      return;
    }

    await this.parseFileChunk(fullPath, bytes, start);
  }

  /**
   * Parse a chunk of the file of length bytes from a specified position.
   */
  private async parseFileChunk(file: string, bytes: number, position: number) {
    const buffer = Buffer.alloc(bytes);
    const handle = await fs.promises.open(file, 'r');
    let bytesRead = 0;

    try {
      ({ bytesRead } = await handle.read(buffer, 0, bytes, position));
    } finally {
      await handle.close();
    }

    if (bytesRead !== bytes) {
      console.error(
        '[CombatLogParser] Read attempted for',
        bytes,
        'bytes, but read',
        bytesRead,
      );
    }

    this.emit('WARCRAFT_RECORDER_LOG_ACTIVITY');

    const remainder = this.remainders[file];
    const read = buffer.subarray(0, bytesRead);
    const data = remainder ? Buffer.concat([remainder, read]) : read;

    // Everything after the last newline is a partial line; keep it for the
    // next read.
    const end = data.lastIndexOf(0x0a) + 1;
    this.remainders[file] = Buffer.from(data.subarray(end));

    data
      .subarray(0, end)
      .toString('utf-8')
      .split('\n')
      .map((s) => s.trim())
      .filter((s) => s)
      .forEach((line) => this.handleLogLine(line));
  }

  /**
   * Handle a line from the WoW log. Public as this is called by the test
   * button.
   */
  public handleLogLine(line: string) {
    const logLine = new LogLine(line);
    const logEventType = logLine.type();
    this.emit(logEventType, logLine);
  }
}
