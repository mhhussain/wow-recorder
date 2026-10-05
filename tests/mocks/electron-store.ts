/**
 * In-memory stand-in for electron-store (ESM-only, needs Electron paths).
 * ConfigService applies schema defaults itself, so an empty store behaves
 * like a fresh install.
 */
export default class ElectronStore<T extends Record<string, unknown>> {
  public store: Partial<T> = {};

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  constructor(_options?: unknown) {}

  has(key: keyof T) {
    return Object.prototype.hasOwnProperty.call(this.store, key);
  }

  get(key: keyof T) {
    return this.store[key];
  }

  set(key: keyof T, value: T[keyof T]) {
    this.store[key] = value;
  }

  delete(key: keyof T) {
    delete this.store[key];
  }

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  onDidAnyChange(_cb: unknown) {
    return () => {};
  }
}
