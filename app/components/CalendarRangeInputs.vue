<script setup lang="ts">
import {
  CALENDAR_DAY_MINUTES,
  calendarDateToMinuteOffset,
  calendarMinuteToDateOnly
} from '~~/utils/calendarTime'

const props = defineProps<{
  baseDate: string
  start: number
  end: number
  min: number
  max: number
}>()

const emit = defineEmits<{
  'update:start': [value: number]
  'update:end': [value: number]
}>()

const minimumDate = computed(() => calendarMinuteToDateOnly(props.baseDate, props.min))
const maximumDate = computed(() => calendarMinuteToDateOnly(
  props.baseDate,
  Math.max(props.min, props.max - 1)
))
const startDate = computed(() => calendarMinuteToDateOnly(props.baseDate, props.start))
const endDate = computed(() => calendarMinuteToDateOnly(
  props.baseDate,
  Math.max(props.start, props.end - 1)
))

const updateStart = (value: string) => {
  const minute = calendarDateToMinuteOffset(
    props.baseDate,
    value
  )
  if (minute === null) return
  emit('update:start', Math.min(Math.max(props.min, minute), props.end - 1))
}

const updateEnd = (value: string) => {
  const minute = calendarDateToMinuteOffset(
    props.baseDate,
    value
  )
  if (minute === null) return
  const inclusiveEnd = minute + CALENDAR_DAY_MINUTES
  emit('update:end', Math.max(Math.min(props.max, inclusiveEnd), props.start + 1))
}
</script>

<template>
  <div class="mb-2 flex items-center justify-end gap-2 text-xs text-app-muted">
    <span>显示日期</span>
    <AppDateInput
      :model-value="startDate"
      :min="minimumDate"
      :max="endDate"
      compact
      class="w-28 flex-none"
      @change="updateStart"
    />
    <span>至</span>
    <AppDateInput
      :model-value="endDate"
      :min="startDate"
      :max="maximumDate"
      compact
      class="w-28 flex-none"
      @change="updateEnd"
    />
  </div>
</template>
