/**
 * The Poller's ps invocation against the real ps on macOS, with no terminal
 * (as in the packaged app): a long executable path must come back whole. A
 * copy of the capture helper is started from a deliberately long path; no
 * process is named like WoW, so a running Warcraft Recorder is unaffected.
 * Assertions avoid printing the process list into CI logs. Skipped off macOS
 * or before `npm run build:native`.
 */
import fs from 'fs';
import os from 'os';
import path from 'path';
import { ChildProcess, execFileSync, spawn } from 'child_process';
import { psArgs, psCommand } from '../../utils/Poller';

const helper = path.join(__dirname, '../../../binaries/wcr-capture');
const available = process.platform === 'darwin' && fs.existsSync(helper);

const listed = (exe: string) =>
  execFileSync(psCommand, psArgs, { stdio: 'pipe' })
    .toString()
    .split('\n')
    .some((l) => l.trim() === exe);

(available ? describe : describe.skip)('process listing', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wcr-ps-'));
  const longDir = path.join(dir, `${'x'.repeat(60)}.app/Contents/MacOS`);
  const exe = path.join(longDir, 'wcr-long-path-probe');
  let child: ChildProcess;

  beforeAll(async () => {
    fs.mkdirSync(longDir, { recursive: true });
    fs.copyFileSync(helper, exe);
    fs.chmodSync(exe, 0o755);

    // `serve` idles until stdin closes.
    child = spawn(exe, ['serve'], { stdio: ['pipe', 'ignore', 'ignore'] });

    for (let i = 0; i < 40 && !listed(exe); i++) {
      await new Promise((r) => setTimeout(r, 50));
    }
  });

  afterAll(() => {
    child.kill('SIGKILL');
    fs.rmSync(dir, { recursive: true, force: true });
  });

  test('psArgs list a long executable path in full', () => {
    expect(exe.length).toBeGreaterThan(100);
    expect(listed(exe)).toBe(true);
  });
});
