import type { AppearancePreset, SizePreset } from '~~/types/component'
import { getDeviceColor } from './device-colors'

export interface ComponentUIConfig {
  icon: string
  /** 设备 PNG 图标路径（public/ 下），有值时侧栏/画布优先展示图片 */
  iconSrc?: string
  canvasType: 'energy' | 'shape'
  defaultSize: SizePreset
  appearance: AppearancePreset
}

/** 设备 PNG 资源目录：public/icons/device/，同名文件可直接替换 */
const deviceIcon = (file: string) => `/icons/device/${file}.png`

const createAppearance = (
  fillColor: string,
  strokeColor = '#475467',
  borderRadius = 10
): AppearancePreset => ({
  fillColor,
  strokeColor,
  strokeWidth: 1.5,
  fontSize: 13,
  textColor: '#1D2939',
  borderRadius,
  rotation: 0,
  opacity: 1
})

export const componentUIConfigs: Record<string, ComponentUIConfig> = {
  // ===== 电力系统 =====
  WT: {
    icon: 'wind',
    iconSrc: deviceIcon('wind-turbine'),
    canvasType: 'energy',
    defaultSize: { width: 150, height: 150 },
    appearance: createAppearance('#EFF8FF', getDeviceColor('WT'))
  },
  CP: {
    icon: 'factory',
    iconSrc: deviceIcon('gas-plant'),
    canvasType: 'energy',
    defaultSize: { width: 150, height: 150 },
    appearance: createAppearance('#FFF1F0', getDeviceColor('CP'))
  },
  CHP: {
    icon: 'factory',
    iconSrc: deviceIcon('chp'),
    canvasType: 'energy',
    defaultSize: { width: 150, height: 150 },
    appearance: createAppearance('#FFF7E8', getDeviceColor('CHP'))
  },
  ES: {
    icon: 'battery',
    iconSrc: deviceIcon('battery'),
    canvasType: 'energy',
    defaultSize: { width: 150, height: 150 },
    appearance: createAppearance('#FFF1F2', getDeviceColor('ES'))
  },
  FS: {
    icon: 'battery',
    iconSrc: deviceIcon('fuel-storage'),
    canvasType: 'energy',
    defaultSize: { width: 150, height: 150 },
    appearance: createAppearance('#F3F0FF', getDeviceColor('FS'))
  },
  PS: {
    icon: 'water-storage',
    iconSrc: deviceIcon('water-storage'),
    canvasType: 'energy',
    defaultSize: { width: 150, height: 150 },
    appearance: createAppearance('#E0F2FE', getDeviceColor('PS'))
  },
  CS: {
    icon: 'battery',
    iconSrc: deviceIcon('air-storage'),
    canvasType: 'energy',
    defaultSize: { width: 150, height: 150 },
    appearance: createAppearance('#E0F2FE', getDeviceColor('CS'))
  },
  ELOAD: {
    icon: 'load',
    iconSrc: deviceIcon('load'),
    canvasType: 'energy',
    defaultSize: { width: 150, height: 150 },
    appearance: createAppearance('#F0F9FF', getDeviceColor('ELOAD'))
  },
  HLOAD: {
    icon: 'gas-load',
    iconSrc: deviceIcon('hydrogen-load'),
    canvasType: 'energy',
    defaultSize: { width: 150, height: 150 },
    appearance: createAppearance('#F0FDF4', getDeviceColor('HLOAD'))
  },
  QLOAD: {
    icon: 'heat-load',
    iconSrc: deviceIcon('heat-load'),
    canvasType: 'energy',
    defaultSize: { width: 150, height: 150 },
    appearance: createAppearance('#FFF7ED', getDeviceColor('QLOAD'))
  },
  PV: {
    icon: 'solar',
    iconSrc: deviceIcon('solar-panel'),
    canvasType: 'energy',
    defaultSize: { width: 150, height: 150 },
    appearance: createAppearance('#F0FDF4', getDeviceColor('PV'))
  },
  GP: {
    icon: 'factory',
    iconSrc: deviceIcon('coal-plant'),
    canvasType: 'energy',
    defaultSize: { width: 150, height: 150 },
    appearance: createAppearance('#FFF7ED', getDeviceColor('GP'))
  },
  ET: {
    icon: 'electrolyzer',
    iconSrc: deviceIcon('electrolyzer'),
    canvasType: 'energy',
    defaultSize: { width: 150, height: 150 },
    appearance: createAppearance('#F7FEE7', getDeviceColor('ET'))
  },
  HS: {
    icon: 'hydrogen-storage',
    iconSrc: deviceIcon('hydrogen-storage'),
    canvasType: 'energy',
    defaultSize: { width: 150, height: 150 },
    appearance: createAppearance('#F0FDFA', getDeviceColor('HS'))
  },
  GRID: {
    icon: 'grid',
    iconSrc: deviceIcon('grid'),
    canvasType: 'energy',
    defaultSize: { width: 150, height: 150 },
    appearance: createAppearance('#F5F3FF', getDeviceColor('GRID'))
  },
  HGRID: {
    icon: 'grid',
    iconSrc: deviceIcon('hydrogen-grid'),
    canvasType: 'energy',
    defaultSize: { width: 150, height: 150 },
    appearance: createAppearance('#F0FDFA', getDeviceColor('HGRID'))
  },
  HYDRO: {
    icon: 'hydro',
    iconSrc: deviceIcon('hydro'),
    canvasType: 'energy',
    defaultSize: { width: 150, height: 150 },
    appearance: createAppearance('#EFF6FF', getDeviceColor('HYDRO'))
  },

  // ===== 总线 =====
  ELEC_BUS: {
    icon: 'bus-electric',
    iconSrc: deviceIcon('bus-electric'),
    canvasType: 'shape',
    defaultSize: { width: 10, height: 100 },
    appearance: createAppearance('#EEF4FF', '#155EEF', 1)
  },
  THERMAL_BUS: {
    icon: 'bus-thermal',
    iconSrc: deviceIcon('bus-thermal'),
    canvasType: 'shape',
    defaultSize: { width: 10, height: 100 },
    appearance: createAppearance('#FFF4ED', '#F97316', 1)
  },
  H2_BUS: {
    icon: 'hydrogen',
    iconSrc: deviceIcon('bus-hydrogen'),
    canvasType: 'shape',
    defaultSize: { width: 10, height: 100 },
    appearance: createAppearance('#ECFDF3', '#12B76A', 1)
  }
}
