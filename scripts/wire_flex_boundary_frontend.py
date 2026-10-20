"""Frontend: pass flexibility boundary IDs instead of expanding H:MM series."""
from pathlib import Path
import re

root = Path(r"C:\Users\Administrator\Desktop\SynerRoll-main")

# ---------- FlexibilityTimeSeriesEditor.vue ----------
p = root / "app" / "components" / "FlexibilityTimeSeriesEditor.vue"
text = p.read_text(encoding="utf-8")

# emit selected boundary id
old = """const emit = defineEmits<{
  'update:modelValue': [value: Record<string, number>]
  validation: [message: string]
}>()"""
new = """const emit = defineEmits<{
  'update:modelValue': [value: Record<string, number>]
  'update:boundaryId': [boundaryId: string]
  validation: [message: string]
}>()"""
assert old in text, "emits not found"
text = text.replace(old, new, 1)

old = """watch(selectedBoundary, () => {
  if (props.mode === 'boundary') applyBoundarySeries()
})"""
new = """watch(selectedBoundary, () => {
  if (props.mode !== 'boundary') return
  const boundaryId = selectedBoundary.value.split(':')[0] ?? ''
  emit('update:boundaryId', boundaryId)
  applyBoundarySeries()
})"""
assert old in text, "selectedBoundary watch not found"
text = text.replace(old, new, 1)

# when switching away from boundary, clear id
old = """watch(() => props.mode, (mode) => {
  if (mode === 'manual') validateManualRows()
  else if (mode === 'file') setValidation(fileLoaded.value ? validationMessage.value : '请选择并导入一个时序文件')
  else if (mode === 'boundary') applyBoundarySeries()
}, { immediate: true })"""
new = """watch(() => props.mode, (mode) => {
  if (mode === 'manual') validateManualRows()
  else if (mode === 'file') setValidation(fileLoaded.value ? validationMessage.value : '请选择并导入一个时序文件')
  else if (mode === 'boundary') applyBoundarySeries()
  else emit('update:boundaryId', '')
}, { immediate: true })"""
assert old in text, "mode watch not found"
text = text.replace(old, new, 1)

p.write_text(text, encoding="utf-8")
print("FlexibilityTimeSeriesEditor.vue OK")

# ---------- tasks/index.vue ----------
p = root / "app" / "pages" / "tasks" / "index.vue"
text = p.read_text(encoding="utf-8")

# add boundary id fields to newTask
old = """  targetPoiPowerSeries: { default: 0 } as Record<string, number>,
  upwardRequirementSeries: { default: 0 } as Record<string, number>,
  downwardRequirementSeries: { default: 0 } as Record<string, number>
})"""
new = """  targetPoiPowerSeries: { default: 0 } as Record<string, number>,
  upwardRequirementSeries: { default: 0 } as Record<string, number>,
  downwardRequirementSeries: { default: 0 } as Record<string, number>,
  targetBoundaryId: '',
  upwardBoundaryId: '',
  downwardBoundaryId: ''
})"""
assert old in text, "newTask series fields not found"
text = text.replace(old, new, 1)

# buildFlexibilityTaskConfig: prefer boundary id in boundary mode
old = """  if (newTask.requirementSource === 'agc_or_schedule') {
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
  else if (newTask.requirementSource === 'user_defined') {
    if (newTask.flexibilityValueMode !== 'constant') {
      if (seriesValidationErrors.upward) throw new Error(seriesValidationErrors.upward)
      if (seriesValidationErrors.downward) throw new Error(seriesValidationErrors.downward)
    }
    config.upwardRequirementKw = parseFlexibilityValueSpec(
      newTask.upwardRequirementKw,
      newTask.upwardRequirementSeries,
      '上调需求',
      true
    )
    config.downwardRequirementKw = parseFlexibilityValueSpec(
      newTask.downwardRequirementKw,
      newTask.downwardRequirementSeries,
      '下调需求',
      true
    )
  }
  return config
}"""
new = """  if (newTask.requirementSource === 'agc_or_schedule') {
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
  }
  else if (newTask.requirementSource === 'user_defined') {
    if (newTask.flexibilityValueMode === 'boundary') {
      if (!newTask.upwardBoundaryId || !newTask.downwardBoundaryId) {
        throw new Error('请选择上调、下调灵活性边界曲线（各一条，从 1 月 1 日起，仿真日期自动截取）')
      }
      config.upwardRequirementBoundaryId = newTask.upwardBoundaryId
      config.downwardRequirementBoundaryId = newTask.downwardBoundaryId
    }
    else {
      if (newTask.flexibilityValueMode !== 'constant') {
        if (seriesValidationErrors.upward) throw new Error(seriesValidationErrors.upward)
        if (seriesValidationErrors.downward) throw new Error(seriesValidationErrors.downward)
      }
      config.upwardRequirementKw = parseFlexibilityValueSpec(
        newTask.upwardRequirementKw,
        newTask.upwardRequirementSeries,
        '上调需求',
        true
      )
      config.downwardRequirementKw = parseFlexibilityValueSpec(
        newTask.downwardRequirementKw,
        newTask.downwardRequirementSeries,
        '下调需求',
        true
      )
    }
  }
  return config
}"""
assert old in text, "buildFlexibilityTaskConfig body not found"
text = text.replace(old, new, 1)

# wire editor @update:boundary-id
text = text.replace(
    """                <FlexibilityTimeSeriesEditor
                  v-if="newTask.flexibilityValueMode !== 'constant'"
                  v-model="newTask.targetPoiPowerSeries"
                  :mode="newTask.flexibilityValueMode"
                  label="目标并网功率"
                  :boundary-options="boundarySeriesOptionsFor('target')"
                  :expected-timestamps="expectedRequirementTimestamps"
                  @validation="seriesValidationErrors.target = $event"
                />""",
    """                <FlexibilityTimeSeriesEditor
                  v-if="newTask.flexibilityValueMode !== 'constant'"
                  v-model="newTask.targetPoiPowerSeries"
                  :mode="newTask.flexibilityValueMode"
                  label="目标并网功率"
                  :boundary-options="boundarySeriesOptionsFor('target')"
                  :expected-timestamps="expectedRequirementTimestamps"
                  @validation="seriesValidationErrors.target = $event"
                  @update:boundary-id="newTask.targetBoundaryId = $event"
                />""",
    1,
)
text = text.replace(
    """                  <FlexibilityTimeSeriesEditor
                    v-else
                    v-model="newTask.upwardRequirementSeries"
                    :mode="newTask.flexibilityValueMode"
                    label="上调需求"
                    :nonnegative="true"
                    :boundary-options="boundarySeriesOptionsFor('up')"
                    :expected-timestamps="expectedRequirementTimestamps"
                    @validation="seriesValidationErrors.upward = $event"
                  />""",
    """                  <FlexibilityTimeSeriesEditor
                    v-else
                    v-model="newTask.upwardRequirementSeries"
                    :mode="newTask.flexibilityValueMode"
                    label="上调需求"
                    :nonnegative="true"
                    :boundary-options="boundarySeriesOptionsFor('up')"
                    :expected-timestamps="expectedRequirementTimestamps"
                    @validation="seriesValidationErrors.upward = $event"
                    @update:boundary-id="newTask.upwardBoundaryId = $event"
                  />""",
    1,
)
text = text.replace(
    """                  <FlexibilityTimeSeriesEditor
                    v-else
                    v-model="newTask.downwardRequirementSeries"
                    :mode="newTask.flexibilityValueMode"
                    label="下调需求"
                    :nonnegative="true"
                    :boundary-options="boundarySeriesOptionsFor('down')"
                    :expected-timestamps="expectedRequirementTimestamps"
                    @validation="seriesValidationErrors.downward = $event"
                  />""",
    """                  <FlexibilityTimeSeriesEditor
                    v-else
                    v-model="newTask.downwardRequirementSeries"
                    :mode="newTask.flexibilityValueMode"
                    label="下调需求"
                    :nonnegative="true"
                    :boundary-options="boundarySeriesOptionsFor('down')"
                    :expected-timestamps="expectedRequirementTimestamps"
                    @validation="seriesValidationErrors.downward = $event"
                    @update:boundary-id="newTask.downwardBoundaryId = $event"
                  />""",
    1,
)

p.write_text(text, encoding="utf-8")
print("tasks/index.vue OK")
