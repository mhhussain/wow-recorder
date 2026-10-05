/**
 * Types from the `noobs` package (aza547/noobs, LGPL-2.0), vendored because
 * the package itself is Windows-only and is not installed on macOS. The
 * macOS backend (MacNoobs) implements the same call surface.
 */
// OBS Data Types
export type ObsDataValue =
  | string
  | number
  | boolean
  | ObsData
  | ObsData[]
  | null;

export interface ObsData {
  [key: string]: ObsDataValue;
}

// OBS Property Types
export type ObsPropertyType =
  | 'invalid'
  | 'bool'
  | 'int'
  | 'float'
  | 'text'
  | 'path'
  | 'list'
  | 'color'
  | 'button'
  | 'font'
  | 'editable_list'
  | 'frame_rate'
  | 'group'
  | 'color_alpha'
  | 'unknown';

export type ObsNumberType = 'scroller' | 'slider';

export type ObsTextType = 'default' | 'password' | 'multiline' | 'info';

export type ObsPathType = 'file' | 'file_save' | 'directory';

export type ObsComboType = 'invalid' | 'editable' | 'list' | 'radio';

export type ObsComboFormat = 'invalid' | 'int' | 'float' | 'string';

export interface ObsListItem {
  name: string;
  value: string | number;
  disabled: boolean;
}

export interface ObsPropertyBase {
  name: string;
  description: string;
  type: ObsPropertyType;
  enabled: boolean;
  visible: boolean;
}

export interface ObsIntProperty extends ObsPropertyBase {
  type: 'int';
  min: number;
  max: number;
  step: number;
  number_type: ObsNumberType;
}

export interface ObsFloatProperty extends ObsPropertyBase {
  type: 'float';
  min: number;
  max: number;
  step: number;
  number_type: ObsNumberType;
}

export interface ObsTextProperty extends ObsPropertyBase {
  type: 'text';
  text_type: ObsTextType;
}

export interface ObsPathProperty extends ObsPropertyBase {
  type: 'path';
  path_type: ObsPathType;
  filter: string;
  default_path: string;
}

export interface ObsListProperty extends ObsPropertyBase {
  type: 'list';
  combo_type: ObsComboType;
  combo_format: ObsComboFormat;
  items: ObsListItem[];
}

export interface ObsBoolProperty extends ObsPropertyBase {
  type: 'bool';
}

export interface ObsColorProperty extends ObsPropertyBase {
  type: 'color' | 'color_alpha';
}

export interface ObsButtonProperty extends ObsPropertyBase {
  type: 'button';
}

export interface ObsFontProperty extends ObsPropertyBase {
  type: 'font';
}

export interface ObsEditableListProperty extends ObsPropertyBase {
  type: 'editable_list';
}

export interface ObsFrameRateProperty extends ObsPropertyBase {
  type: 'frame_rate';
}

export interface ObsGroupProperty extends ObsPropertyBase {
  type: 'group';
}

export interface ObsGenericProperty extends ObsPropertyBase {
  type: 'invalid' | 'unknown';
}

export type ObsProperty =
  | ObsIntProperty
  | ObsFloatProperty
  | ObsTextProperty
  | ObsPathProperty
  | ObsListProperty
  | ObsBoolProperty
  | ObsColorProperty
  | ObsButtonProperty
  | ObsFontProperty
  | ObsEditableListProperty
  | ObsFrameRateProperty
  | ObsGroupProperty
  | ObsGenericProperty;

export type Signal = {
  type: string; // Either "output" or "volmeter", "source", "converted".
  id: string; // Signal identifier, e.g. "stop"
  code: number; // 0 for success, other values for errors
  value?: number; // Currently only used for volmeters.
  error?: string; // Error message, if any.
  path?: string; // Converted signal specifies the path.
};

export type SceneItemPosition = {
  x: number; // X position in pixels
  y: number; // Y position in pixels
  scaleX: number; // X scaling factor
  scaleY: number; // Y scaling factor
  cropLeft: number; // Pixels to crop from the left
  cropRight: number; // Pixels to crop from the right
  cropTop: number; // Pixels to crop from the top
  cropBottom: number; // Pixels to crop from the bottom
};

export type SourceDimensions = {
  height: number; // Height in pixels, before scaling
  width: number; // Width in pixels, before scaling
};
