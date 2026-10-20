from pathlib import Path

root = Path(r"C:\Users\Administrator\Desktop\SynerRoll-main")

# Skip expected-timestamp validation in boundary mode (date slice happens at seed)
p = root / "app" / "components" / "FlexibilityTimeSeriesEditor.vue"
text = p.read_text(encoding="utf-8")
old = """  if (!Object.prototype.hasOwnProperty.call(result, 'default') && props.expectedTimestamps?.length) {
    const missing = props.expectedTimestamps.filter(timestamp =>
      !Object.prototype.hasOwnProperty.call(result, timestamp)
    )
    if (missing.length) {
      const preview = missing.slice(0, 3).join('、')
      return {
        value: null,
        error: `缺少 ${missing.length} 个评价时点（如 ${preview}），请补齐或增加 default`
      }
    }
  }"""
new = """  // 边界模式：曲线从 1/1 起连续存储，仿真日期由 seed 自动截取，
  // 不必用评价时刻 H:MM 做齐全性校验。
  if (
    props.mode !== 'boundary' &&
    !Object.prototype.hasOwnProperty.call(result, 'default') &&
    props.expectedTimestamps?.length
  ) {
    const missing = props.expectedTimestamps.filter(timestamp =>
      !Object.prototype.hasOwnProperty.call(result, timestamp)
    )
    if (missing.length) {
      const preview = missing.slice(0, 3).join('、')
      return {
        value: null,
        error: `缺少 ${missing.length} 个评价时点（如 ${preview}），请补齐或增加 default`
      }
    }
  }"""
assert old in text, "expected timestamp check not found"
text = text.replace(old, new, 1)
p.write_text(text, encoding="utf-8")
print("FlexibilityTimeSeriesEditor validation OK")

# types/api.ts
p = root / "types" / "api.ts"
text = p.read_text(encoding="utf-8")
old = """export interface FlexibilityTaskConfig {
  enabled: boolean
  layerId?: string
  requirementSource?: string
  networkMode?: string
  [key: string]: unknown
}"""
new = """export type FlexibilityValueSpec = number | Record<string, number>

export interface FlexibilityTaskConfig {
  enabled: boolean
  layerId?: string
  requirementSource?: string
  networkMode?: string
  /** AGC 目标：边界引用（从 1/1 起，按仿真日期截取） */
  targetPoiPowerBoundaryId?: string
  /** AGC 目标：常数或时间戳序列（兼容） */
  targetPoiPowerKw?: FlexibilityValueSpec
  /** 用户自定义上调需求边界 */
  upwardRequirementBoundaryId?: string
  upwardRequirementKw?: FlexibilityValueSpec
  /** 用户自定义下调需求边界 */
  downwardRequirementBoundaryId?: string
  downwardRequirementKw?: FlexibilityValueSpec
  [key: string]: unknown
}"""
assert old in text, "FlexibilityTaskConfig not found"
text = text.replace(old, new, 1)
p.write_text(text, encoding="utf-8")
print("types/api.ts OK")
