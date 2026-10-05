import {
  ChildProcessWithoutNullStreams,
  execFileSync,
  spawn,
} from 'child_process';
import { EventEmitter } from 'events';
import { Signal } from './noobsTypes';

/**
 * Device lists reported by `wcr-capture list` / `listDevices`. Enumeration
 * needs no privacy permission.
 */
export type DeviceList = {
  displays: { id: number; width: number; height: number; main: boolean }[];
  mics: { id: string; name: string }[];
  defaultMic: string;
  apps: { bundleId: string; name: string; pid: number; wow: boolean }[];
};

export const emptyDeviceList = (): DeviceList => ({
  displays: [],
  mics: [],
  defaultMic: '',
  apps: [],
});

/**
 * What MacNoobs needs from the helper process. Events:
 *   - 'signal' (Signal): output and volmeter signals, same shape as noobs.
 *   - 'helperError' (string): non-fatal errors, e.g. a source failed.
 *   - 'exit' (number): the process exited.
 */
export interface HelperTransport extends EventEmitter {
  start(): void;
  stop(): void;
  isRunning(): boolean;
  send(cmd: string, payload?: Record<string, unknown>): Promise<unknown>;
  listDevicesSync(): DeviceList;
  listDevices(): Promise<DeviceList>;
}

type Pending = {
  cmd: string;
  resolve: (value: unknown) => void;
  reject: (reason: Error) => void;
};

/**
 * Spawns and talks to the `wcr-capture` Swift helper over JSON lines on
 * stdio. See native/wcr-capture/Sources/main.swift for the protocol.
 */
export default class CaptureHelper
  extends EventEmitter
  implements HelperTransport
{
  private child?: ChildProcessWithoutNullStreams;

  private nextId = 1;

  private pending = new Map<number, Pending>();

  private stdoutBuffer = '';

  private stderrBuffer = '';

  constructor(private binary: string) {
    super();
  }

  public isRunning() {
    return this.child !== undefined;
  }

  public start() {
    if (this.child) return;
    console.info('[CaptureHelper] Starting', this.binary);

    const child = spawn(this.binary, ['serve'], { stdio: 'pipe' });
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (data: string) => this.onStdout(data));
    child.stderr.on('data', (data: string) => this.onStderr(data));

    child.on('error', (error) => {
      // Typically ENOENT when the helper has not been built.
      console.error('[CaptureHelper] Process error', String(error));
    });

    child.on('exit', (code, signal) => {
      console.warn('[CaptureHelper] Exited', { code, signal });
      this.child = undefined;

      this.pending.forEach((p) =>
        p.reject(new Error(`Capture helper exited during ${p.cmd}`)),
      );

      this.pending.clear();
      this.emit('exit', code ?? -1);
    });

    this.child = child;
  }

  public stop() {
    const { child } = this;
    if (!child) return;
    console.info('[CaptureHelper] Stopping');

    // Closing stdin asks the helper to finish any recording and exit.
    child.stdin.end();

    setTimeout(() => {
      if (this.child === child) {
        console.warn('[CaptureHelper] Did not exit, killing');
        child.kill('SIGKILL');
      }
    }, 10000).unref();
  }

  public send(cmd: string, payload: Record<string, unknown> = {}) {
    const { child } = this;

    if (!child) {
      return Promise.reject(new Error('Capture helper is not running'));
    }

    const id = this.nextId++;
    const line = `${JSON.stringify({ ...payload, id, cmd })}\n`;

    return new Promise<unknown>((resolve, reject) => {
      this.pending.set(id, { cmd, resolve, reject });
      child.stdin.write(line);
    });
  }

  public listDevicesSync(): DeviceList {
    const out = execFileSync(this.binary, ['list'], {
      encoding: 'utf8',
      timeout: 10000,
    });

    return CaptureHelper.parseDeviceList(out);
  }

  public async listDevices(): Promise<DeviceList> {
    if (this.child) {
      return (await this.send('listDevices')) as DeviceList;
    }

    return this.listDevicesSync();
  }

  public static parseDeviceList(output: string): DeviceList {
    const lines = output.trim().split('\n');
    const parsed = JSON.parse(lines[lines.length - 1]);
    return { ...emptyDeviceList(), ...parsed };
  }

  private onStdout(data: string) {
    this.stdoutBuffer += data;
    const lines = this.stdoutBuffer.split('\n');
    this.stdoutBuffer = lines.pop() ?? '';

    lines
      .map((l) => l.trim())
      .filter((l) => l)
      .forEach((l) => this.handleLine(l));
  }

  private onStderr(data: string) {
    this.stderrBuffer += data;
    const lines = this.stderrBuffer.split('\n');
    this.stderrBuffer = lines.pop() ?? '';

    lines
      .filter((l) => l.trim())
      .forEach((l) => console.info('[wcr-capture]', l));
  }

  /**
   * Public for tests. Events carry an `event` field; command responses carry
   * a numeric `id`.
   */
  public handleLine(line: string) {
    let message: Record<string, unknown>;

    try {
      message = JSON.parse(line);
    } catch {
      console.warn('[CaptureHelper] Unparseable line', line);
      return;
    }

    if (message.event === 'signal') {
      const { type, id, code, value, error, path } = message;

      const signal: Signal = {
        type: String(type),
        id: String(id),
        code: Number(code ?? 0),
      };

      if (typeof value === 'number') signal.value = value;
      if (typeof error === 'string') signal.error = error;
      if (typeof path === 'string') signal.path = path;
      this.emit('signal', signal);
      return;
    }

    if (message.event === 'error') {
      this.emit('helperError', String(message.message));
      return;
    }

    if (message.event === 'ready') {
      console.info('[CaptureHelper] Ready, pid', message.pid);
      return;
    }

    if (typeof message.id !== 'number') {
      console.warn('[CaptureHelper] Unexpected message', message);
      return;
    }

    const pending = this.pending.get(message.id);
    if (!pending) return;
    this.pending.delete(message.id);

    if (message.ok) {
      pending.resolve(message.result);
    } else {
      pending.reject(new Error(String(message.error)));
    }
  }
}
