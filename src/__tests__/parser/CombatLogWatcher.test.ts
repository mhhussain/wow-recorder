import fs from 'fs';
import os from 'os';
import path from 'path';
import CombatLogWatcher from '../../parsing/CombatLogWatcher';
import LogLine from '../../parsing/LogLine';

const line = (n: number, name = 'Player') =>
  `7/28/2025 17:35:${String(n).padStart(2, '0')}.000  UNIT_DIED,0000000000000000,nil,0x80000000,0x80000000,Player-1-${n},"${name}",0x511,0x0,0\n`;

const setup = () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wcr-logs-'));
  const file = 'WoWCombatLog-100526_120000.txt';
  const full = path.join(dir, file);
  const watcher = new CombatLogWatcher(dir, 50);
  const seen: string[] = [];
  watcher.on('UNIT_DIED', (l: LogLine) => seen.push(l.arg(6)));
  return { dir, file, full, watcher, seen };
};

const waitFor = async (check: () => boolean, ms = 3000) => {
  const deadline = Date.now() + ms;
  while (!check()) {
    if (Date.now() > deadline) throw new Error('timed out');
    await new Promise((r) => setTimeout(r, 20));
  }
};

test('reads appended lines incrementally and carries partial lines', async () => {
  const { full, file, watcher, seen } = setup();

  fs.writeFileSync(full, line(1, 'A'));
  await watcher.process(file);
  expect(seen).toEqual(['A']);

  // A line split across two writes, including a multi-byte character split
  // in the middle of its UTF-8 encoding.
  const bytes = Buffer.from(line(2, 'Bjørn'));
  const cut = bytes.indexOf(Buffer.from('ø')) + 1;
  fs.appendFileSync(full, bytes.subarray(0, cut));
  await watcher.process(file);
  expect(seen).toEqual(['A']);

  fs.appendFileSync(
    full,
    Buffer.concat([bytes.subarray(cut), Buffer.from(line(3, 'C'))]),
  );
  await watcher.process(file);
  expect(seen).toEqual(['A', 'Bjørn', 'C']);

  // Nothing new: no duplicate processing.
  await watcher.process(file);
  expect(seen).toHaveLength(3);
});

test('re-reads a truncated or recreated file from the start', async () => {
  const { full, file, watcher, seen } = setup();

  fs.writeFileSync(full, line(1, 'A') + line(2, 'B'));
  await watcher.process(file);

  // Truncated (smaller than before).
  fs.writeFileSync(full, line(3, 'C'));
  await watcher.process(file);
  expect(seen).toEqual(['A', 'B', 'C']);

  // Deleted and recreated with the same name (new inode), even if larger.
  fs.unlinkSync(full);
  await watcher.process(file);
  fs.writeFileSync(full, line(4, 'D') + line(5, 'E') + line(6, 'F'));
  await watcher.process(file);
  expect(seen).toEqual(['A', 'B', 'C', 'D', 'E', 'F']);
});

test('does not replay an existing log on start, then follows writes', async () => {
  const { full, watcher, seen } = setup();
  fs.writeFileSync(full, line(1, 'Old'));

  await watcher.watch();

  try {
    fs.appendFileSync(full, line(2, 'New'));
    await waitFor(() => seen.length === 1);
    expect(seen).toEqual(['New']);

    // A brand new log file (WoW starts one per /combatlog toggle).
    const next = path.join(
      path.dirname(full),
      'WoWCombatLog-100526_130000.txt',
    );
    fs.writeFileSync(next, line(3, 'Fresh'));
    await waitFor(() => seen.length === 2);
    expect(seen).toEqual(['New', 'Fresh']);
  } finally {
    await watcher.unwatch();
  }
});
