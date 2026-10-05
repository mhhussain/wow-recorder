/**
 * The Poller's ps invocation against the real ps on macOS, without a
 * terminal (as in the packaged app): executable paths must come back whole.
 * A copy of the capture helper is started from a deliberately long path; no
 * process is named like WoW, so a running Warcraft Recorder is unaffected.
 * Skipped off macOS or before `npm run build:native`.
 */
import fs from 'fs';
import os from 'os';
import path from 'path';
import { ChildProcess, execFileSync, spawn } from 'child_process';
import { psArgs, psCommand } from '../../utils/Poller';

const helper = path.join(__dirname, '../../../binaries/wcr-capture');
const available = process.platform === 'darwin' && fs.existsSync(helper);

// ps with no terminal on any stdio and no COLUMNS, like a GUI app.
const ps = (args: string[]) => {
  const env = { ...process.env };
  delete env.COLUMNS;
  return execFileSync(psCommand, args, { env, stdio: 'pipe' }).toString();
};

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

    for (let i = 0; i < 40 && !ps(psArgs).includes(exe); i++) {
      await new Promise((r) => setTimeout(r, 50));
    }
  });

  afterAll(() => {
    child.kill('SIGKILL');
    fs.rmSync(dir, { recursive: true, force: true });
  });

  test('the probe path is longer than the default ps width', () => {
    expect(exe.length).toBeGreaterThan(79);
  });

  test('psArgs list the full executable path', () => {
    const lines = ps(psArgs)
      .split('\n')
      .map((l) => l.trim());
    expect(lines).toContain(exe);
  });

  test('plain -axo comm= truncates it (the bug psArgs avoids)', () => {
    const lines = ps(['-axo', 'comm='])
      .split('\n')
      .map((l) => l.trim());
    expect(lines).not.toContain(exe);

    // Cut at the default width of 79 columns.
    const cut = lines.filter((l) => l.length >= 70 && exe.startsWith(l));
    expect(cut).toHaveLength(1);
    expect(cut[0].length).toBeLessThanOrEqual(80);
  });
});
