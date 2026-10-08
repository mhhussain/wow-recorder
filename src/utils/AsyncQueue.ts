export default class AsyncQueue {
  private queue: (() => Promise<void>)[] = [];
  private running = false;
  private limit: number; // Limit the queued tasks.
  private idleWaiters: (() => void)[] = [];

  constructor(limit: number) {
    this.limit = limit;
  }

  public add(task: () => Promise<void>) {
    // Just drop any tasks added over the limit.
    if (this.queue.length >= this.limit) return;
    this.queue.push(task);
    if (!this.running) this.run();
  }

  private async run() {
    this.running = true;

    while (this.queue.length) {
      const task = this.queue.shift()!;

      try {
        await task();
      } catch (e) {
        // Don't let a failing task stop the queue processing
        // further tasks. Just log it and move on.
        console.warn('[AsyncQueue] Task failed:', e);
      }
    }

    this.running = false;
    this.idleWaiters.splice(0).forEach((resolve) => resolve());
  }

  /**
   * Resolves once every queued task has finished.
   */
  public drain(): Promise<void> {
    if (!this.running && this.queue.length === 0) return Promise.resolve();
    return new Promise((resolve) => this.idleWaiters.push(resolve));
  }
}
