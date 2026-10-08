import Poller, { parseWowProcesses } from '../../utils/Poller';
import ConfigService from '../../config/ConfigService';
import { WowProcessEvent } from '../../main/types';

const app = (folder: string, name: string) =>
  `/Applications/World of Warcraft/${folder}/${name}.app/Contents/MacOS/${name}`;

test('detects retail and classic clients by install folder', () => {
  const ps = [
    '/sbin/launchd',
    '/Applications/Discord.app/Contents/MacOS/Discord',
    app('_retail_', 'World of Warcraft'),
  ].join('\n');

  expect(parseWowProcesses(ps)).toEqual({ Retail: true, Classic: false });

  expect(
    parseWowProcesses(app('_classic_era_', 'World of Warcraft Classic')),
  ).toEqual({ Retail: false, Classic: true });

  expect(
    parseWowProcesses(app('_ptr_', 'World of Warcraft Public Test')),
  ).toEqual({ Retail: true, Classic: false });
});

test('falls back to the app name for non-standard install folders', () => {
  const custom = (name: string) =>
    `/Users/me/Games/${name}.app/Contents/MacOS/${name}`;

  expect(parseWowProcesses(custom('World of Warcraft'))).toEqual({
    Retail: true,
    Classic: false,
  });

  expect(parseWowProcesses(custom('World of Warcraft Classic'))).toEqual({
    Retail: false,
    Classic: true,
  });
});

test("detects the owner's install on an external volume", () => {
  // `ps -axo comm= | grep -i warcraft` on the owner's Mac with WoW open.
  const ps = [
    '/Volumes/Dock/World of Warcraft/_retail_/World of Warcraft.app/Contents/MacOS/World of Warcraft',
    '/Volumes/Dock/World of Warcraft/_retail_/World of Warcraft.app/Contents/Helpers/WowVoiceProxy.app/Contents/MacOS/WowVoiceProxy',
    '/Users/me/Applications/WarcraftRecorder.app/Contents/MacOS/WarcraftRecorder',
    '/Users/me/Applications/WarcraftRecorder.app/Contents/Resources/binaries/wcr-capture',
  ].join('\n');

  expect(parseWowProcesses(ps)).toEqual({ Retail: true, Classic: false });
});

test('accepts a bare client name', () => {
  expect(parseWowProcesses('World of Warcraft')).toEqual({
    Retail: true,
    Classic: false,
  });
});

test('ignores helpers, launchers and look-alikes', () => {
  const ps = [
    app('_retail_', 'World of Warcraft Helper'),
    '/Applications/Battle.net.app/Contents/MacOS/Battle.net',
    '/tmp/World of Warcraft', // Not inside an app bundle.
  ].join('\n');

  expect(parseWowProcesses(ps)).toEqual({ Retail: false, Classic: false });
});

test('emits started/stopped only for flavours configured to record', () => {
  const cfg = ConfigService.getInstance();
  cfg.set('recordRetail', true);
  cfg.set('recordClassic', false);

  const poller = Poller.getInstance();
  const events: string[] = [];
  // Handlers see the new state (ending an activity on WoW exit must not
  // re-arm the buffer).
  poller.on(WowProcessEvent.STARTED, () =>
    events.push(`started ${poller.isWowRunning()}`),
  );
  poller.on(WowProcessEvent.STOPPED, () =>
    events.push(`stopped ${poller.isWowRunning()}`),
  );

  process.env.WCR_FAKE_WOW = 'classic';
  poller.start(); // Classic running but not configured: nothing.
  expect(poller.isWowRunning()).toBe(false);

  poller.handleProcessState({ Retail: true, Classic: false });
  poller.handleProcessState({ Retail: true, Classic: false });
  poller.handleProcessState({ Retail: false, Classic: false });
  poller.stop();

  // Late results after stop are ignored.
  poller.handleProcessState({ Retail: true, Classic: false });

  expect(events).toEqual(['started true', 'stopped false']);
  delete process.env.WCR_FAKE_WOW;
});
