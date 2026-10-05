/**
 * Stub for the native global input hook, which is not needed (and not
 * installed in the Linux container) for unit tests.
 */
import { EventEmitter } from 'events';

export enum EventType {
  EVENT_KEY_PRESSED = 4,
  EVENT_KEY_RELEASED = 5,
  EVENT_MOUSE_PRESSED = 7,
  EVENT_MOUSE_RELEASED = 8,
}

class Hook extends EventEmitter {
  start() {}

  stop() {}
}

export const uIOhook = new Hook();
export const UiohookKey = {};
export type UiohookKeyboardEvent = Record<string, unknown>;
export type UiohookMouseEvent = Record<string, unknown>;
