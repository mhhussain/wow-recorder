import path from 'path';
import { app, screen } from 'electron';
import CaptureHelper from './CaptureHelper';
import MacNoobs from './MacNoobs';

/**
 * The macOS recording backend instance used by Recorder in place of the
 * Windows-only `noobs` module.
 */
const binary = app.isPackaged
  ? path.join(process.resourcesPath, 'binaries', 'wcr-capture')
  : path.join(__dirname, '../../binaries', 'wcr-capture');

/**
 * Displays in Electron order, which is what the monitorIndex setting
 * indexes. On macOS Electron's display.id is the CGDirectDisplayID the
 * helper captures by.
 */
const getDisplays = () =>
  screen.getAllDisplays().map((display, index) => {
    const width = Math.round(display.size.width * display.scaleFactor);
    const height = Math.round(display.size.height * display.scaleFactor);

    return {
      id: display.id,
      label: `Display ${index + 1} (${width}x${height})`,
    };
  });

const noobs = new MacNoobs({
  transport: new CaptureHelper(binary),
  // Excluded from system audio so the app's own playback is not recorded.
  excludeBundlePrefix: app.isPackaged
    ? 'org.WarcraftRecorder'
    : 'com.github.Electron',
  getDisplays,
});

export default noobs;
