import icon from '../../assets/icon.png';

/**
 * The draggable title bar. The window buttons are the native macOS traffic
 * lights, drawn by the system over the left of this bar.
 */
export default function RendererTitleBar() {
  return (
    <div
      id="title-bar"
      className="w-full h-[32px] bg-background flex items-center justify-center px-2 pr-0 absolute top-0 left-0"
    >
      <img
        src={icon}
        style={{ width: '20px', height: '20px', marginRight: 8 }}
      />
      <div className="text-popover-foreground font-semibold text-sm font-sans">
        Warcraft Recorder
      </div>
    </div>
  );
}
