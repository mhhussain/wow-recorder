/**
 * Global unit test setup. CloudClient starts heartbeat timers and makes
 * network calls on construction (ChallengeModeDungeon asks it for keystone
 * timers); tests use the local fallback timers instead.
 */
jest.mock('storage/CloudClient', () => {
  const client = {
    getKeystoneTimers: () => Promise.reject(new Error('offline in tests')),
    ready: async () => false,
    refreshStatus: () => {},
    refreshVideos: async () => {},
  };

  return { __esModule: true, default: { getInstance: () => client } };
});
