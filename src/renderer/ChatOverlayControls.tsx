import {
  Dispatch,
  SetStateAction,
  useCallback,
  useEffect,
  useRef,
  useState,
} from 'react';
import { configSchema, ConfigurationSchema } from 'config/configSchema';
import { Info } from 'lucide-react';
import { AppState, SceneItem } from 'main/types';
import { getLocalePhrase } from 'localisation/translations';
import { setConfigValues } from './useSettings';
import { imageSelect } from './rendererutils';
import Label from './components/Label/Label';
import { Tooltip } from './components/Tooltip/Tooltip';
import Switch from './components/Switch/Switch';
import { Input } from './components/Input/Input';
import { Phrase } from 'localisation/phrases';
import Slider from './components/Slider/Slider';

const ipc = window.electron.ipcRenderer;

interface IProps {
  appState: AppState;
  config: ConfigurationSchema;
  setConfig: Dispatch<SetStateAction<ConfigurationSchema>>;
}

const ChatOverlayControls = (props: IProps) => {
  const { appState, config, setConfig } = props;
  const initialRender = useRef(true);

  const [cropMaxX, setCropMaxX] = useState(0);
  const [cropMaxY, setCropMaxY] = useState(0);

  const initCropSliders = useCallback(async () => {
    if (!config.chatOverlayEnabled) return;
    const pos = await ipc.getSourcePosition(SceneItem.OVERLAY);
    if (!pos) return;
    // Don't let them crop more than 80% of the dimension. Crop is in image
    // pixels, so undo the scale.
    setCropMaxX(Math.round((0.8 * pos.width) / pos.scaleX / 2));
    setCropMaxY(Math.round((0.8 * pos.height) / pos.scaleY / 2));
  }, [config.chatOverlayEnabled]);

  useEffect(() => {
    if (initialRender.current) return;

    setConfigValues({
      chatOverlayEnabled: config.chatOverlayEnabled,
      chatOverlayOwnImage: config.chatOverlayOwnImage,
      chatOverlayOwnImagePath: config.chatOverlayOwnImagePath,
    });

    ipc.reconfigureOverlay();

    // The image may have changed size. There is no preview on macOS to
    // signal that, so re-read it once the main process has applied it.
    const timer = setTimeout(initCropSliders, 500);
    return () => clearTimeout(timer);
  }, [
    config.chatOverlayEnabled,
    config.chatOverlayOwnImage,
    config.chatOverlayOwnImagePath,
    initCropSliders,
  ]);

  useEffect(() => {
    // If the user changes an overlay source, it will fire the source
    //  callback, which we react to to ensure the sliders are sensible.
    ipc.on('initCropSliders', initCropSliders);

    return () => {
      ipc.removeAllListeners('initCropSliders');
    };
  }, [initCropSliders]);

  useEffect(() => {
    initCropSliders();
    initialRender.current = false;
  }, []);

  const setOverlayEnabled = (checked: boolean) => {
    setConfig((prevState) => {
      return {
        ...prevState,
        chatOverlayEnabled: checked,
      };
    });
  };

  const setOwnImage = (checked: boolean) => {
    setConfig((prevState) => {
      return {
        ...prevState,
        chatOverlayOwnImage: checked,
      };
    });
  };

  const getChatOverlayEnabledSwitch = () => {
    return (
      <div className="flex flex-col">
        <Label className="flex items-center">
          {getLocalePhrase(appState.language, Phrase.ChatOverlayLabel)}
          <Tooltip
            content={getLocalePhrase(
              appState.language,
              configSchema.chatOverlayEnabled.description,
            )}
            side="right"
          >
            <Info size={20} className="inline-flex ml-2" />
          </Tooltip>
        </Label>
        <div className="flex h-10 items-center">
          <Switch
            checked={config.chatOverlayEnabled}
            onCheckedChange={setOverlayEnabled}
          />
        </div>
      </div>
    );
  };

  const getChatOverlayOwnImageSwitch = () => {
    return (
      <div className="flex flex-col">
        <Label className="flex items-center gap-x-2">
          {getLocalePhrase(appState.language, Phrase.OwnImageLabel)}
          <Tooltip
            content={getLocalePhrase(
              appState.language,
              configSchema.chatOverlayOwnImage.description,
            )}
            side="right"
          >
            <Info size={20} className="inline-flex" />
          </Tooltip>
        </Label>
        <div className="flex h-10 items-center">
          <Switch
            checked={config.chatOverlayOwnImage}
            onCheckedChange={setOwnImage}
            disabled={!config.chatOverlayOwnImage && !config.chatOverlayEnabled}
          />
        </div>
      </div>
    );
  };

  const setOverlayPath = async () => {
    const newPath = await imageSelect();

    if (newPath === '') {
      return;
    }

    setConfig((prevState) => {
      return {
        ...prevState,
        chatOverlayOwnImagePath: newPath,
      };
    });
  };

  const getOwnImagePathField = () => {
    return (
      <div className="flex flex-col w-1/3 min-w-60 max-w-80">
        <Label htmlFor="overlayImagePath" className="flex items-center">
          {getLocalePhrase(appState.language, Phrase.ImagePathLabel)}
          <Tooltip
            content={getLocalePhrase(
              appState.language,
              configSchema.chatOverlayOwnImagePath.description,
            )}
            side="right"
          >
            <Info size={20} className="inline-flex ml-2" />
          </Tooltip>
        </Label>
        <>
          <Input
            name="overlayImagePath"
            value={config.chatOverlayOwnImagePath}
            onClick={setOverlayPath}
            readOnly
          />
        </>
      </div>
    );
  };

  /**
   * There is no live preview on macOS to drag the overlay around, so
   * position and scale are set with sliders, in canvas pixels. Crop stays
   * the same number of image pixels when the scale changes.
   */
  const moveOverlay = async (change: {
    x?: number;
    y?: number;
    scale?: number;
    cropX?: number;
    cropY?: number;
  }) => {
    const p = await ipc.getSourcePosition(SceneItem.OVERLAY);
    if (!p) return;

    const scale = change.scale ?? p.scaleX;
    const ratio = scale / p.scaleX;

    if (change.x !== undefined) p.x = change.x;
    if (change.y !== undefined) p.y = change.y;

    // Width, height and crop are in scaled pixels; setSourcePosition
    // derives the new scale from the width.
    p.width *= ratio;
    p.height *= ratio;
    p.cropLeft = (change.cropX ?? p.cropLeft / p.scaleX) * scale;
    p.cropRight = (change.cropX ?? p.cropRight / p.scaleX) * scale;
    p.cropTop = (change.cropY ?? p.cropTop / p.scaleY) * scale;
    p.cropBottom = (change.cropY ?? p.cropBottom / p.scaleY) * scale;

    await ipc.setSourcePosition(SceneItem.OVERLAY, p);
  };

  const setOverlayValue = (
    key:
      | 'chatOverlayXPosition'
      | 'chatOverlayYPosition'
      | 'chatOverlayScale'
      | 'chatOverlayCropX'
      | 'chatOverlayCropY',
    value: number,
  ) => {
    setConfig((prev) => ({ ...prev, [key]: value }));

    const change = {
      chatOverlayXPosition: { x: value },
      chatOverlayYPosition: { y: value },
      chatOverlayScale: { scale: value },
      chatOverlayCropX: { cropX: value },
      chatOverlayCropY: { cropY: value },
    }[key];

    moveOverlay(change);
  };

  const [canvasWidth, canvasHeight] = config.obsOutputResolution
    .split('x')
    .map(Number);

  const getSlider = (
    label: Phrase,
    description: Phrase,
    key: Parameters<typeof setOverlayValue>[0],
    max: number,
    step: number,
    min = 0,
  ) => (
    <div className="flex gap-x-3 items-center" key={key}>
      <Label className="flex items-center w-[100px] mb-0">
        {getLocalePhrase(appState.language, label)}
        <Tooltip
          content={getLocalePhrase(appState.language, description)}
          side="right"
        >
          <Info size={20} className="inline-flex ml-2" />
        </Tooltip>
      </Label>
      <div className="flex w-[150px] items-center">
        <Slider
          value={[config[key]]}
          min={min}
          max={max}
          step={step}
          onValueChange={(array) => setOverlayValue(key, array[0])}
        />
      </div>
    </div>
  );

  const getChatOverlayPositionSliders = () => {
    return (
      <div className="flex flex-col gap-y-4 w-full mt-2">
        {getSlider(
          Phrase.XPositionLabel,
          Phrase.ChatOverlayXPositionDescription,
          'chatOverlayXPosition',
          canvasWidth || 1920,
          1,
        )}
        {getSlider(
          Phrase.YPositionLabel,
          Phrase.ChatOverlayYPositionDescription,
          'chatOverlayYPosition',
          canvasHeight || 1080,
          1,
        )}
        {getSlider(
          Phrase.ScaleLabel,
          Phrase.ChatOverlayScaleDescription,
          'chatOverlayScale',
          3,
          0.05,
          0.1,
        )}
        {getSlider(
          Phrase.WidthLabel,
          Phrase.ChatOverlayWidthDescription,
          'chatOverlayCropX',
          cropMaxX,
          1,
        )}
        {getSlider(
          Phrase.HeightLabel,
          Phrase.ChatOverlayHeightDescription,
          'chatOverlayCropY',
          cropMaxY,
          1,
        )}
      </div>
    );
  };

  const showPathWarning =
    config.chatOverlayOwnImage &&
    !config.chatOverlayOwnImagePath.endsWith('.png') &&
    !config.chatOverlayOwnImagePath.endsWith('.gif');

  return (
    <div className="flex flex-col items-center content-center w-full flex-wrap gap-4">
      <div className="flex items-center content-center w-full gap-8">
        {getChatOverlayEnabledSwitch()}
        {config.chatOverlayEnabled && getChatOverlayOwnImageSwitch()}
        {config.chatOverlayEnabled &&
          config.chatOverlayOwnImage &&
          getOwnImagePathField()}
      </div>
      {showPathWarning && (
        <p className="flex w-full text-red-500 text-sm">
          {getLocalePhrase(appState.language, Phrase.ErrorCustomImageFileType)}
        </p>
      )}
      {config.chatOverlayEnabled && getChatOverlayPositionSliders()}
    </div>
  );
};

export default ChatOverlayControls;
