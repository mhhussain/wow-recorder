import { AudioSourceType } from '../types';
import { DeviceList, emptyDeviceList, HelperTransport } from './CaptureHelper';
import {
  ObsData,
  ObsListItem,
  ObsListProperty,
  ObsProperty,
  SceneItemPosition,
  Signal,
  SourceDimensions,
} from './noobsTypes';

/**
 * VideoToolbox hardware encoders exposed by the helper. IDs match the libobs
 * mac-videotoolbox encoder IDs.
 */
export const MacEncoders = {
  H264: 'com.apple.videotoolbox.videoencoder.ave.avc',
  HEVC: 'com.apple.videotoolbox.videoencoder.ave.hevc',
};

const VIDEO_TYPES = ['window_capture', 'game_capture', 'monitor_capture'];

const AUDIO_KINDS: Record<string, 'system' | 'mic' | 'app'> = {
  [AudioSourceType.OUTPUT]: 'system',
  [AudioSourceType.INPUT]: 'mic',
  [AudioSourceType.PROCESS]: 'app',
};

/** Matches EngineConfig in native/wcr-capture/Sources/Config.swift. */
export type EngineConfig = {
  outputDir: string;
  fps: number;
  width: number;
  height: number;
  encoder: string;
  quality: number;
  video: {
    kind: 'display' | 'wow' | 'none';
    displayId?: number;
    showCursor: boolean;
  };
  audio: {
    name: string;
    kind: 'system' | 'mic' | 'app';
    device?: string;
    volume: number;
    tracks: number;
  }[];
  forceMono: boolean;
  suppression: boolean;
  muteInputs: boolean;
  excludeBundlePrefix: string;
  bufferSeconds: number;
};

type SourceState = {
  type: string;
  settings: ObsData;
  inScene: boolean;
  volume: number;
  tracks: number;
  pos: SceneItemPosition;
};

export type MacNoobsOptions = {
  transport: HelperTransport;

  /** Bundle ID prefix of this app, excluded from system audio capture. */
  excludeBundlePrefix: string;

  /** Displays in Electron's screen.getAllDisplays() order (monitorIndex). */
  getDisplays: () => { id: number; label: string }[];
};

const defaultPosition = (): SceneItemPosition => ({
  x: 0,
  y: 0,
  scaleX: 1,
  scaleY: 1,
  cropLeft: 0,
  cropRight: 0,
  cropTop: 0,
  cropBottom: 0,
});

const listProperty = (
  name: string,
  description: string,
  items: ObsListItem[],
): ObsListProperty => ({
  name,
  description,
  type: 'list',
  enabled: true,
  visible: true,
  combo_type: 'list',
  combo_format: 'string',
  items,
});

const item = (name: string, value: string): ObsListItem => ({
  name,
  value,
  disabled: false,
});

/**
 * macOS stand-in for the `noobs` libobs binding. It implements the call
 * surface Recorder uses, keeps the scene (sources, settings, volumes, track
 * routing) in TypeScript, and pushes the complete desired state to the
 * wcr-capture helper, which reconciles its capture sources. Recording
 * commands and signals map one to one onto the helper protocol.
 *
 * Preview and scene positioning are accepted but have no effect: there is
 * no native preview on macOS (see DECISIONS D-004).
 */
export default class MacNoobs {
  private sources = new Map<string, SourceState>();

  private callback: (signal: Signal) => void = () => {};

  private devices: DeviceList = emptyDeviceList();

  private outputDir = '';

  private fps = 60;

  private width = 1920;

  private height = 1080;

  private encoder = MacEncoders.H264;

  private quality = 0.6;

  private forceMono = false;

  private suppression = false;

  private muteInputs = false;

  private volmeterEnabled = false;

  private lastRecording = '';

  private buffering = false;

  private dirty = false;

  private flushScheduled = false;

  private shuttingDown = false;

  private restarts: number[] = [];

  /** Non-fatal helper errors, e.g. a microphone failing to open. */
  public onHelperError: (message: string) => void = () => {};

  constructor(private opts: MacNoobsOptions) {}

  // Lifecycle

  public Init(_distPath: string, _logPath: string, cb: (s: Signal) => void) {
    this.callback = cb;
    const { transport } = this.opts;

    transport.on('signal', (signal: Signal) => this.onSignal(signal));

    transport.on('helperError', (message: string) => {
      console.error('[MacNoobs] Helper error:', message);
      this.onHelperError(message);
    });

    transport.on('exit', () => this.onHelperExit());

    try {
      this.devices = transport.listDevicesSync();
    } catch (error) {
      console.warn('[MacNoobs] Initial device listing failed', String(error));
    }

    transport.start();
    this.markDirty();
  }

  public IsHelperRunning() {
    return this.opts.transport.isRunning();
  }

  public Shutdown() {
    this.shuttingDown = true;
    this.flushConfig();
    this.opts.transport.stop();
  }

  // Recording

  public SetBuffering(enabled: boolean) {
    // The helper always buffers.
    if (!enabled) console.warn('[MacNoobs] Unbuffered recording unsupported');
  }

  public SetFragmentation(enabled: boolean) {
    // The helper always writes fragmented MP4.
    if (!enabled) console.warn('[MacNoobs] Unfragmented output unsupported');
  }

  public SetRecordingCfg(recordingPath: string, fileExtension: string) {
    if (fileExtension !== 'mp4') {
      console.warn('[MacNoobs] Only mp4 is supported, got', fileExtension);
    }

    this.outputDir = recordingPath;
    this.markDirty();
  }

  public ResetVideoContext(fps: number, width: number, height: number) {
    this.fps = fps;
    this.width = width;
    this.height = height;
    this.markDirty();
  }

  public ListVideoEncoders(): string[] {
    return [MacEncoders.H264, MacEncoders.HEVC];
  }

  public SetVideoEncoder(id: string, settings: ObsData) {
    this.encoder = id;

    if (typeof settings.quality === 'number') {
      this.quality = settings.quality;
    }

    this.markDirty();
  }

  public StartBuffer() {
    if (!this.opts.transport.isRunning()) {
      this.emitAsync({
        type: 'output',
        id: 'deactivate',
        code: -1,
        error:
          'The capture helper is not running. Was binaries/wcr-capture built (npm run build:native)?',
      });
      return;
    }

    this.flushConfig();
    this.command('startBuffer');
  }

  public StartRecording(offset: number) {
    this.flushConfig();
    this.command('convert', { offset });
  }

  public StopRecording() {
    this.stopCommand('stop');
  }

  public ForceStopRecording() {
    this.stopCommand('forceStop');
  }

  public GetLastRecording() {
    return this.lastRecording;
  }

  // Sources

  public CreateSource(name: string, type: string): string {
    let unique = name;
    let n = 2;

    while (this.sources.has(unique)) {
      unique = `${name} ${n}`;
      n++;
    }

    this.sources.set(unique, {
      type,
      settings: MacNoobs.defaultSettings(type),
      inScene: false,
      volume: 1,
      tracks: 1,
      pos: defaultPosition(),
    });

    return unique;
  }

  public DeleteSource(name: string) {
    this.sources.delete(name);
    this.markDirty();
  }

  public GetSourceSettings(name: string): ObsData {
    return { ...this.get(name).settings };
  }

  public SetSourceSettings(name: string, settings: ObsData) {
    this.get(name).settings = { ...settings };
    this.markDirty();
  }

  public GetSourceProperties(name: string): ObsProperty[] {
    const source = this.get(name);

    // Lists are served from a cache; refresh it for next time.
    this.RefreshDevices().catch(() => {});

    switch (source.type) {
      case AudioSourceType.INPUT:
        return [
          listProperty('device_id', 'Device', [
            item('Default', 'default'),
            ...this.devices.mics.map((m) => item(m.name, m.id)),
          ]),
        ];

      case AudioSourceType.OUTPUT:
        return [
          listProperty('device_id', 'Device', [
            item('System audio (all apps except Warcraft Recorder)', 'default'),
          ]),
        ];

      case AudioSourceType.PROCESS:
        return [
          listProperty('window', 'Window', [
            item('World of Warcraft (any client)', 'wow'),
            ...this.devices.apps
              .filter((a) => !a.wow)
              .map((a) => item(a.name, a.bundleId)),
          ]),
        ];

      case 'monitor_capture':
        return [
          listProperty(
            'monitor_id',
            'Display',
            this.opts.getDisplays().map((d) => item(d.label, String(d.id))),
          ),
        ];

      case 'window_capture':
      case 'game_capture':
        return [
          listProperty('window', 'Window', [item('World of Warcraft', 'wow')]),
        ];

      default:
        return [];
    }
  }

  /**
   * Ask macOS for Screen Recording access, so the app shows up in System
   * Settings before WoW is first launched.
   */
  public RequestScreenAccess() {
    this.command('requestScreenAccess');
  }

  public async RefreshDevices() {
    try {
      this.devices = await this.opts.transport.listDevices();
    } catch (error) {
      console.warn('[MacNoobs] Device refresh failed', String(error));
    }
  }

  // Audio

  public SetMuteAudioInputs(mute: boolean) {
    this.muteInputs = mute;
    this.markDirty();
  }

  public SetSourceVolume(name: string, volume: number) {
    this.get(name).volume = volume;
    this.markDirty();
  }

  public SetVolmeterEnabled(enabled: boolean) {
    this.volmeterEnabled = enabled;
    this.command('setVolmeter', { enabled });
  }

  public SetAudioSuppression(enabled: boolean) {
    this.suppression = enabled;
    this.markDirty();
  }

  public SetForceMono(enabled: boolean) {
    this.forceMono = enabled;
    this.markDirty();
  }

  public GetSourceAudioTracks(name: string) {
    return this.get(name).tracks;
  }

  public SetSourceAudioTracks(name: string, tracks: number) {
    this.get(name).tracks = tracks;
    this.markDirty();
  }

  // Scene

  public AddSourceToScene(name: string) {
    this.get(name).inScene = true;
    this.markDirty();
  }

  public RemoveSourceFromScene(name: string) {
    const source = this.sources.get(name);
    if (!source) return;
    source.inScene = false;
    this.markDirty();
  }

  public GetSourcePos(name: string): SceneItemPosition & SourceDimensions {
    // The helper scales captures to fill the canvas.
    return { ...this.get(name).pos, width: this.width, height: this.height };
  }

  public SetSourcePos(name: string, pos: SceneItemPosition) {
    this.get(name).pos = { ...pos };
  }

  // Preview: not available on macOS.

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  public InitPreview(_handle: Buffer) {}

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  public ConfigurePreview(_x: number, _y: number, _w: number, _h: number) {}

  public ShowPreview() {}

  public HidePreview() {}

  public DisablePreview() {}

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  public SetDrawSourceOutline(_enabled: boolean) {}

  public GetDrawSourceOutlineEnabled() {
    return false;
  }

  public GetPreviewInfo() {
    return {
      canvasWidth: this.width,
      canvasHeight: this.height,
      previewWidth: 0,
      previewHeight: 0,
    };
  }

  // Internals

  /** The full desired state for the helper. Public for tests. */
  public buildConfig(): EngineConfig {
    const inScene = Array.from(this.sources.entries()).filter(
      ([, s]) => s.inScene,
    );

    const videoEntry = inScene.find(([, s]) => VIDEO_TYPES.includes(s.type));
    let video: EngineConfig['video'] = { kind: 'none', showCursor: false };

    if (videoEntry) {
      const [, source] = videoEntry;
      const { settings } = source;
      const cursor = settings.capture_cursor ?? settings.cursor ?? true;

      if (source.type === 'monitor_capture') {
        const displayId = Number(settings.monitor_id);

        video = {
          kind: 'display',
          showCursor: Boolean(cursor),
          ...(Number.isFinite(displayId) && displayId > 0 ? { displayId } : {}),
        };
      } else {
        video = { kind: 'wow', showCursor: Boolean(cursor) };
      }
    }

    const audio: EngineConfig['audio'] = [];

    inScene.forEach(([name, source]) => {
      const kind = AUDIO_KINDS[source.type];
      if (!kind) return;

      const device =
        kind === 'app'
          ? source.settings.window
          : (source.settings.device_id ?? 'default');

      if (kind === 'app' && !device) {
        // App source with no application picked yet.
        return;
      }

      audio.push({
        name,
        kind,
        device: String(device),
        volume: source.volume,
        tracks: source.tracks,
      });
    });

    return {
      outputDir: this.outputDir,
      fps: this.fps,
      width: this.width,
      height: this.height,
      encoder: this.encoder,
      quality: this.quality,
      video,
      audio,
      forceMono: this.forceMono,
      suppression: this.suppression,
      muteInputs: this.muteInputs,
      excludeBundlePrefix: this.opts.excludeBundlePrefix,
      bufferSeconds: 60,
    };
  }

  private static defaultSettings(type: string): ObsData {
    if (type === AudioSourceType.INPUT || type === AudioSourceType.OUTPUT) {
      return { device_id: 'default' };
    }

    if (VIDEO_TYPES.includes(type)) {
      return { capture_cursor: true };
    }

    return {};
  }

  private get(name: string): SourceState {
    const source = this.sources.get(name);

    if (!source) {
      throw new Error(`Source not found: ${name}`);
    }

    return source;
  }

  /**
   * Coalesce state changes made in one tick into one configure command.
   * Commands that depend on the state flush first, so ordering holds.
   */
  private markDirty() {
    this.dirty = true;
    if (this.flushScheduled) return;
    this.flushScheduled = true;

    setImmediate(() => {
      this.flushScheduled = false;
      this.flushConfig();
    });
  }

  private flushConfig() {
    if (!this.dirty || !this.opts.transport.isRunning()) return;
    this.dirty = false;
    this.command('configure', { config: this.buildConfig() });
  }

  private command(cmd: string, payload: Record<string, unknown> = {}) {
    if (!this.opts.transport.isRunning()) {
      console.warn('[MacNoobs] Helper not running, dropping', cmd);
      return;
    }

    this.opts.transport.send(cmd, payload).catch((error) => {
      console.error('[MacNoobs] Command failed', cmd, String(error));
    });
  }

  private stopCommand(cmd: 'stop' | 'forceStop') {
    if (!this.opts.transport.isRunning()) {
      // Nothing is recording; still resolve the Recorder's wait.
      this.emitAsync({ type: 'output', id: 'deactivate', code: 0, path: '' });
      return;
    }

    this.command(cmd);
  }

  private emitAsync(signal: Signal) {
    setImmediate(() => this.onSignal(signal));
  }

  private onSignal(signal: Signal) {
    if (signal.type === 'output') {
      if (signal.id === 'start') {
        this.buffering = true;
      } else if (signal.id === 'deactivate') {
        this.buffering = false;
        this.lastRecording = signal.path ?? '';
      }
    }

    this.callback(signal);
  }

  /**
   * The helper died. Tell the Recorder the output is gone, restart the
   * helper and, if it was buffering, resume buffering. Gives up after five
   * crashes in a minute.
   */
  private onHelperExit() {
    if (this.shuttingDown) return;
    const wasBuffering = this.buffering;

    if (wasBuffering) {
      this.onSignal({
        type: 'output',
        id: 'deactivate',
        code: -1,
        error: 'Capture helper exited unexpectedly',
        path: '',
      });
    }

    const now = Date.now();
    this.restarts = this.restarts.filter((t) => now - t < 60000);

    if (this.restarts.length >= 5) {
      console.error('[MacNoobs] Helper keeps crashing, not restarting');
      this.onHelperError('The capture helper keeps crashing. Check the logs.');
      return;
    }

    this.restarts.push(now);

    setTimeout(() => {
      console.info('[MacNoobs] Restarting helper');
      this.opts.transport.start();
      this.dirty = true;
      this.flushConfig();

      if (this.volmeterEnabled) {
        this.command('setVolmeter', { enabled: true });
      }

      if (wasBuffering) {
        this.StartBuffer();
      }
    }, 1000);
  }
}
