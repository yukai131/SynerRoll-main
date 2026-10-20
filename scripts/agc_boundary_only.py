"""AGC target: boundary-only. Remove constant/file input paths for AGC."""
from pathlib import Path

root = Path(r"C:\Users\Administrator\Desktop\SynerRoll-main")

# ---------- tasks/index.vue ----------
p = root / "app" / "pages" / "tasks" / "index.vue"
text = p.read_text(encoding="utf-8")

old_ui = """              <div class="flex flex-wrap items-center gap-x-4 gap-y-2 text-xs">
                <span class="text-app-muted">数值输入方式</span>
                <label class="inline-flex items-center gap-1.5">
                  <input v-model="newTask.flexibilityValueMode" type="radio" value="constant" class="accent-primary">
                  全时域常数
                </label>
                <label class="inline-flex items-center gap-1.5">
                  <input v-model="newTask.flexibilityValueMode" type="radio" value="file" class="accent-primary">
                  导入文件
                </label>
                <label class="inline-flex items-center gap-1.5">
                  <input v-model="newTask.flexibilityValueMode" type="radio" value="boundary" class="accent-primary">
                  项目边界数据库
                </label>
              </div>

              <div v-if="newTask.requirementSource === 'agc_or_schedule'">
                <label class="space-y-1 text-xs text-app-muted">
                  <span>目标并网功率/kW（正值表示上送）</span>
                  <input v-if="newTask.flexibilityValueMode === 'constant'" v-model.number="newTask.targetPoiPowerKw" type="number" step="100" class="field-input h-8 text-xs">
                </label>
                <FlexibilityTimeSeriesEditor
                  v-if="newTask.flexibilityValueMode !== 'constant'"
                  v-model="newTask.targetPoiPowerSeries"
                  :mode="newTask.flexibilityValueMode"
                  label="目标并网功率"
                  :boundary-options="boundarySeriesOptionsFor('target')"
                  :expected-timestamps="expectedRequirementTimestamps"
                  @validation="seriesValidationErrors.target = $event"
                  @update:boundary-id="newTask.targetBoundaryId = $event"
                />
              </div>"""

new_ui = """              <div v-if="newTask.requirementSource !== 'agc_or_schedule'" class="flex flex-wrap items-center gap-x-4 gap-y-2 text-xs">
                <span class="text-app-muted">数值输入方式</span>
                <label class="inline-flex items-center gap-1.5">
                  <input v-model="newTask.flexibilityValueMode" type="radio" value="constant" class="accent-primary">
                  全时域常数
                </label>
                <label class="inline-flex items-center gap-1.5">
                  <input v-model="newTask.flexibilityValueMode" type="radio" value="file" class="accent-primary">
                  导入文件
                </label>
                <label class="inline-flex items-center gap-1.5">
                  <input v-model="newTask.flexibilityValueMode" type="radio" value="boundary" class="accent-primary">
                  项目边界数据库
                </label>
              </div>

              <div v-if="newTask.requirementSource === 'agc_or_schedule'">
                <div class="text-xs text-app-muted">目标并网功率：请从项目边界数据库选择 AGC/计划曲线（从 1 月 1 日起，按仿真日期自动截取）</div>
                <FlexibilityTimeSeriesEditor
                  v-model="newTask.targetPoiPowerSeries"
                  mode="boundary"
                  label="目标并网功率"
                  :boundary-options="boundarySeriesOptionsFor('target')"
                  @validation="seriesValidationErrors.target = $event"
                  @update:boundary-id="newTask.targetBoundaryId = $event"
                />
              </div>"""

assert old_ui in text, "AGC input UI block not found"
text = text.replace(old_ui, new_ui, 1)

# Force boundary mode when AGC selected
old_watch = """watch(
  [() => newTask.flexibilityValueMode, () => flexibilityEvaluationLayerId.value],
  ([mode]) => {
    if (mode === 'boundary') void refreshBoundarySeriesOptions()
  }
)"""
new_watch = """watch(
  () => newTask.requirementSource,
  (source) => {
    // AGC 目标仅支持项目边界数据库
    if (source === 'agc_or_schedule') newTask.flexibilityValueMode = 'boundary'
  },
  { immediate: true }
)

watch(
  [() => newTask.flexibilityValueMode, () => flexibilityEvaluationLayerId.value, () => newTask.requirementSource],
  ([mode, , source]) => {
    if (source === 'agc_or_schedule' && mode !== 'boundary') {
      newTask.flexibilityValueMode = 'boundary'
    }
    if (newTask.flexibilityValueMode === 'boundary' || source === 'agc_or_schedule') {
      void refreshBoundarySeriesOptions()
    }
  }
)"""
assert old_watch in text, "flexibility mode watch not found"
text = text.replace(old_watch, new_watch, 1)

# buildFlexibilityTaskConfig AGC path: boundary only
old_build = """  if (newTask.requirementSource === 'agc_or_schedule') {
    if (newTask.flexibilityValueMode === 'boundary') {
      if (!newTask.targetBoundaryId) {
        throw new Error('请选择目标并网功率边界曲线（从 1 月 1 日起，仿真日期自动截取）')
      }
      config.targetPoiPowerBoundaryId = newTask.targetBoundaryId
    }
    else {
      if (newTask.flexibilityValueMode !== 'constant' && seriesValidationErrors.target) {
        throw new Error(seriesValidationErrors.target)
      }
      config.targetPoiPowerKw = parseFlexibilityValueSpec(
        newTask.targetPoiPowerKw,
        newTask.targetPoiPowerSeries,
        '目标并网功率',
        false
      )
    }
  }"""
new_build = """  if (newTask.requirementSource === 'agc_or_schedule') {
    // AGC 仅支持项目边界数据库曲线
    if (seriesValidationErrors.target) {
      throw new Error(seriesValidationErrors.target)
    }
    if (!newTask.targetBoundaryId) {
      throw new Error('请选择目标并网功率边界曲线（从 1 月 1 日起，仿真日期自动截取）')
    }
    config.targetPoiPowerBoundaryId = newTask.targetBoundaryId
  }"""
assert old_build in text, "AGC build config not found"
text = text.replace(old_build, new_build, 1)

p.write_text(text, encoding="utf-8")
print("tasks/index.vue OK")

# ---------- backend: AGC requires boundary id only ----------
p = root / "backend" / "services" / "flexibility_evaluation_service.jl"
text = p.read_text(encoding="utf-8")

old = """    if requirement_source == FLEXIBILITY_REQUIREMENT_AGC_SCHEDULE
        target_poi_power_boundary_id = _optional_boundary_id("targetPoiPowerBoundaryId")
        has_target_boundary = target_poi_power_boundary_id !== nothing
        has_target_value = haskey(raw, "targetPoiPowerKw")
        (has_target_boundary || has_target_value) || throw(
            ArgumentError(
                "flexibility.targetPoiPowerBoundaryId or targetPoiPowerKw " *
                "is required for agc_or_schedule.",
            ),
        )
        if !has_target_boundary
            target_poi_power_kw = _normalize_flexibility_value_spec(
                raw["targetPoiPowerKw"],
                "targetPoiPowerKw";
                nonnegative=false,
            )
        end"""
new = """    if requirement_source == FLEXIBILITY_REQUIREMENT_AGC_SCHEDULE
        target_poi_power_boundary_id = _optional_boundary_id("targetPoiPowerBoundaryId")
        target_poi_power_boundary_id === nothing && throw(
            ArgumentError(
                "flexibility.targetPoiPowerBoundaryId is required for agc_or_schedule " *
                "(boundary series from Jan 1, sliced by simulation dates).",
            ),
        )"""
assert old in text, "AGC normalize block not found"
text = text.replace(old, new, 1)

# config dict: AGC only boundary id
old = """    if config.requirement_source == FLEXIBILITY_REQUIREMENT_AGC_SCHEDULE
        if config.target_poi_power_boundary_id !== nothing
            row["targetPoiPowerBoundaryId"] = config.target_poi_power_boundary_id
        else
            row["targetPoiPowerKw"] = config.target_poi_power_kw
        end"""
new = """    if config.requirement_source == FLEXIBILITY_REQUIREMENT_AGC_SCHEDULE
        row["targetPoiPowerBoundaryId"] = config.target_poi_power_boundary_id"""
assert old in text, "AGC config dict not found"
text = text.replace(old, new, 1)

p.write_text(text, encoding="utf-8")
print("flexibility_evaluation_service.jl OK")
