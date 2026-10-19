<script setup lang="ts">
const props = withDefaults(defineProps<{
  modelValue?: string | null
  min?: string
  max?: string
  disabled?: boolean
  compact?: boolean
  placeholder?: string
}>(), {
  modelValue: '',
  min: undefined,
  max: undefined,
  disabled: false,
  compact: false,
  placeholder: '年/月/日'
})

const emit = defineEmits<{
  'update:modelValue': [value: string]
  change: [value: string]
}>()

const inputRef = ref<HTMLInputElement | null>(null)
const normalizedValue = computed(() => props.modelValue ?? '')

const emitValue = (event: Event, eventName: 'update:modelValue' | 'change') => {
  const value = (event.target as HTMLInputElement).value
  if (eventName === 'update:modelValue') emit('update:modelValue', value)
  else emit('change', value)
}

const openPicker = () => {
  if (props.disabled) return
  try {
    inputRef.value?.showPicker()
  }
  catch {
    // 浏览器不支持 showPicker 时仍保留原生日期输入行为。
  }
}
</script>

<template>
  <div class="relative min-w-0">
    <input
      ref="inputRef"
      :value="normalizedValue"
      type="date"
      :min="min"
      :max="max"
      :disabled="disabled"
      class="app-date-input w-full rounded border border-app-border outline-none focus:border-primary"
      :class="[
        compact ? 'h-8 px-2 text-xs' : 'h-9 px-3 text-sm',
        disabled ? 'bg-app-panel-soft text-app-muted' : 'bg-white text-app-text',
        { 'app-date-input--empty': !normalizedValue }
      ]"
      :aria-label="placeholder"
      @click="openPicker"
      @input="emitValue($event, 'update:modelValue')"
      @change="emitValue($event, 'change')"
    >
    <span
      v-if="!normalizedValue"
      class="pointer-events-none absolute top-1/2 -translate-y-1/2 text-app-muted"
      :class="compact ? 'left-2 text-xs' : 'left-3 text-sm'"
    >{{ placeholder }}</span>
  </div>
</template>

<style scoped>
.app-date-input--empty::-webkit-datetime-edit,
.app-date-input--empty::-webkit-datetime-edit-fields-wrapper,
.app-date-input--empty::-webkit-datetime-edit-text,
.app-date-input--empty::-webkit-datetime-edit-year-field,
.app-date-input--empty::-webkit-datetime-edit-month-field,
.app-date-input--empty::-webkit-datetime-edit-day-field {
  color: transparent;
}
</style>
