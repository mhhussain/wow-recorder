import { uIOhook } from 'uiohook-napi';

/**
 * The global keyboard/mouse hook (push to talk, manual record hotkey, hotkey
 * binding in settings). On macOS it needs the Accessibility permission:
 * without it, uIOhook.start() throws and raises the system prompt. Upstream
 * started it unconditionally at launch; here it starts only when a feature
 * needs it, and failures are reported instead of thrown.
 */
let started = false;

const accessibilityHelp =
  'Push to talk and the manual record hotkey need the Accessibility permission. Enable Warcraft Recorder in System Settings > Privacy & Security > Accessibility, then restart Warcraft Recorder.';

/**
 * Start the hook if it is not running. Returns whether it is running.
 */
const ensureInputHook = (onError?: (message: string) => void): boolean => {
  if (started) return true;

  try {
    uIOhook.start();
    started = true;
    console.info('[InputHook] Started global input hook');
  } catch (error) {
    console.warn(
      '[InputHook] Failed to start global input hook',
      String(error),
    );
    if (onError) onError(accessibilityHelp);
  }

  return started;
};

const stopInputHook = () => {
  if (!started) return;
  uIOhook.stop();
  started = false;
};

export { ensureInputHook, stopInputHook };
