import path from 'path';
import { app, BrowserWindow } from 'electron';

/**
 * CI boot check for the packaged app. With WCR_SMOKE_TEST=<dir> the app:
 *   - keeps user data and logs under <dir> (nothing in ~/Library/Application Support),
 *   - hides its Dock icon and never shows its window or tray icon,
 *   - skips first-run setup, permission requests and the input hook,
 *   - starts no WoW polling (an empty config is invalid, so the Manager
 *     does not start the Poller),
 * then exits 0 if the main process, renderer and capture helper came up
 * cleanly, or 1 with the reasons. Nothing here requests a privacy
 * permission, so it cannot raise prompts on the runner's desktop.
 */
const smokeTestDir = process.env.WCR_SMOKE_TEST;

const isSmokeTest = () => Boolean(smokeTestDir);

const failures: string[] = [];

/**
 * Must run before anything reads app paths or creates the config store.
 */
const prepareSmokeTest = () => {
  if (!smokeTestDir) return;

  app.setPath('userData', path.join(smokeTestDir, 'userData'));
  app.setAppLogsPath(path.join(smokeTestDir, 'logs'));
  app.dock?.hide();

  process.on('uncaughtException', (error) => {
    failures.push(`uncaughtException: ${error.stack ?? error}`);
  });

  process.on('unhandledRejection', (reason) => {
    failures.push(`unhandledRejection: ${String(reason)}`);
  });
};

const watchSmokeTestWindow = (window: BrowserWindow) => {
  const { webContents } = window;

  webContents.on('render-process-gone', (_event, details) => {
    failures.push(`render-process-gone: ${details.reason}`);
  });

  webContents.on('did-fail-load', (_event, code, description) => {
    failures.push(`did-fail-load: ${code} ${description}`);
  });

  webContents.on('preload-error', (_event, preloadPath, error) => {
    failures.push(`preload-error: ${preloadPath} ${error}`);
  });

  webContents.on('console-message', (details) => {
    // Logged for diagnosis only; React and Chromium warnings are noisy.
    const { level, message } = details as unknown as {
      level?: string | number;
      message?: string;
    };

    if (level === 'error' || level === 3) {
      console.warn('[SmokeTest] Renderer console error:', message);
    }
  });
};

/**
 * Give the app time to settle, check it, report and exit.
 */
const finishSmokeTest = (
  window: BrowserWindow,
  checks: () => Promise<Record<string, unknown>>,
) => {
  setTimeout(async () => {
    let results: Record<string, unknown> = {};

    try {
      results = await checks();

      const text = await window.webContents.executeJavaScript(
        'document.body ? document.body.innerText.length : 0',
      );

      results.rendererTextLength = text;

      if (!text) {
        failures.push('renderer rendered no text');
      }
    } catch (error) {
      failures.push(`checks threw: ${String(error)}`);
    }

    const passed = failures.length === 0;
    console.info('[SmokeTest] Results', JSON.stringify(results));

    failures.forEach((failure) => {
      console.error('[SmokeTest] Failure:', failure);
    });

    console.info(`[SmokeTest] ${passed ? 'PASS' : 'FAIL'}`);
    app.exit(passed ? 0 : 1);
  }, 10000);
};

export { isSmokeTest, prepareSmokeTest, watchSmokeTestWindow, finishSmokeTest };
