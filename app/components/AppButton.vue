<script setup lang="ts">
const props = withDefaults(
  defineProps<{
    label?: string
    icon?: string
    type?: 'button' | 'submit'
    size?: 'sm' | 'md'
    tone?: 'primary' | 'neutral' | 'ghost' | 'danger' | 'green'
    disabled?: boolean
    loading?: boolean
    loadingLabel?: string
  }>(),
  {
    label: '',
    icon: '',
    type: 'button',
    size: 'md',
    tone: 'neutral',
    disabled: false,
    loading: false,
    loadingLabel: ''
  }
)

const toneClassMap = {
  primary: 'border-primary bg-primary text-white hover:bg-primary-active',
  green: 'border-app-border bg-green-500 text-white hover:bg-green-600',
  neutral: 'border-app-border bg-white text-app-text hover:text-primary',
  ghost: 'border-transparent bg-transparent text-app-text hover:bg-app-panel-soft',
  danger: 'border-app-danger bg-app-danger text-white hover:bg-red-600'
} as const

const sizeClassMap = {
  sm: 'h-6 px-3 text-xs',
  md: 'h-8 px-4 text-sm'
} as const

const isDisabled = computed(() => props.disabled || props.loading)
const displayLabel = computed(() => {
  if (!props.loading) return props.label
  return props.loadingLabel || props.label
})
</script>

<template>
  <button
    :type="type"
    :disabled="isDisabled"
    class="inline-flex items-center gap-2 rounded-[4px] border font-medium transition disabled:cursor-not-allowed disabled:opacity-30"
    :class="[toneClassMap[tone], sizeClassMap[size]]"
  >
    <svg
      v-if="loading"
      class="animate-spin"
      :class="size === 'sm' ? 'h-3 w-3' : 'h-4 w-4'"
      viewBox="0 0 24 24"
      fill="none"
      aria-hidden="true"
    >
      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="3" />
      <path class="opacity-90" fill="currentColor" d="M4 12a8 8 0 018-8v3a5 5 0 00-5 5H4z" />
    </svg>
    <AppIcon v-else-if="icon" :name="icon" :size="16" />
    <span v-if="displayLabel">{{ displayLabel }}</span>
    <slot />
  </button>
</template>
