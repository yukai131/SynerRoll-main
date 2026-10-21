export type ResultFlowMedium = 'electric' | 'thermal' | 'hydrogen'

/** 结果变量的物理单位；变量含义优先于历史结果中不准确的 remark。 */
export function getResultDisplayUnit(varName: string, remark?: string): string {
  if (/^H_HS_(?:in|out)(?:_|$)/.test(varName)) return 'kg/h'
  if (/^H_HS(?:_[^_]+)?$/.test(varName)) return 'kg'
  if (varName.startsWith('H_')) return 'kg/h'

  if (/^E_(?:ES|PS|FS|CS)_(?:in|out)(?:_|$)/.test(varName)) return 'kW'
  if (/^E_(?:ES|PS|FS|CS)(?:_[^_]+)?$/.test(varName)) return 'kWh'
  if (remark === 'hydrogen') return 'kg/h'
  if (remark === 'energy') return 'kWh'
  return 'kW'
}

/** 总线瞬时量与时间积分后的累计量采用同一介质口径。 */
export const RESULT_FLOW_QUANTITIES = {
  electric: {
    rateLabel: '功率', rateUnit: 'kW',
    totalLabel: '累计电量', totalUnit: 'kWh', shareLabel: '电量占比'
  },
  thermal: {
    rateLabel: '热功率', rateUnit: 'kW',
    totalLabel: '累计热量', totalUnit: 'kWh', shareLabel: '热量占比'
  },
  hydrogen: {
    rateLabel: '氢流量', rateUnit: 'kg/h',
    totalLabel: '累计氢量', totalUnit: 'kg', shareLabel: '氢量占比'
  }
} as const

export function getResultFlowMedium(varName: string): ResultFlowMedium {
  if (varName.startsWith('H_')) return 'hydrogen'
  if (varName.startsWith('Q_')) return 'thermal'
  return 'electric'
}
