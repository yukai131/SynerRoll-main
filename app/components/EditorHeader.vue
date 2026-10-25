<script setup lang="ts">
import brand from '~~/config/brand.json'
withDefaults(
  defineProps<{
    projectName: string
    isFullscreen: boolean
    logoSrc?: string
    logoText?: string
    userName?: string
  }>(),
  {
    logoSrc: '/logo.png',
    logoText: brand.displayName,
    userName: brand.publisher
  }
)

defineEmits<{
  navigateHome: []
  navigateBack: []
  docs: []
  repo: []
  fullscreen: []
  settings: []
  profile: []
}>()
</script>

<template>
  <header class="bg-primary text-white px-4">
    <div class="grid min-h-14 grid-cols-[minmax(0,1fr)_auto] items-center gap-x-4 gap-y-1 py-2 xl:h-14 xl:grid-cols-[minmax(0,1.3fr)_minmax(80px,0.7fr)_auto] xl:py-0">
      <div class="flex min-w-0 items-center gap-3">
        <button
          type="button"
          class="inline-flex h-9 shrink-0 items-center gap-1.5 rounded-[9px] px-2 text-sm text-white transition hover:bg-white/12"
          title="返回项目管理"
          @click="$emit('navigateHome')"
        >
          <span class="text-lg leading-none" aria-hidden="true">←</span>
          <span>返回</span>
        </button>
        <span class="h-5 w-px bg-white/30" aria-hidden="true" />
        <button type="button" class="flex min-w-0 items-center gap-2.5 text-left" @click="$emit('navigateHome')">
          <img
            v-if="logoSrc"
            :src="logoSrc"
            alt="软件主标志"
            class="h-9 w-auto max-h-10 shrink-0 object-contain"
          >
          <span :title="logoText" class="inline-flex min-w-0 items-center text-sm font-semibold text-white lg:text-base">
            <span class="truncate">{{ logoText }}</span>
          </span>
        </button>
      </div>

      <div class="order-3 col-span-2 min-w-0 text-center xl:order-2 xl:col-span-1">
        <p class="truncate text-base text-white">{{ projectName }}</p>
      </div>

      <div class="order-2 flex items-center justify-end gap-1 xl:order-3">
        <button
          type="button"
          class="inline-flex h-10 w-9 items-center justify-center rounded-[10px] text-white transition hover:bg-white/12"
          title="产品文档"
          @click="$emit('docs')"
        >
          <AppIcon name="docs" :size="20" />
        </button>
        <button
          type="button"
          class="inline-flex h-10 w-9 items-center justify-center rounded-[10px] text-white transition hover:bg-white/12"
          title="代码仓库"
          @click="$emit('repo')"
        >
          <AppIcon name="github" :size="20" />
        </button>
        <button
          type="button"
          class="inline-flex h-10 w-9 items-center justify-center rounded-[10px] text-white transition hover:bg-white/12"
          :title="isFullscreen ? '退出全屏' : '进入全屏'"
          @click="$emit('fullscreen')"
        >
          <AppIcon name="fullscreen" :size="20" />
        </button>
        <button
          type="button"
          class="inline-flex h-10 w-9 items-center justify-center rounded-[10px] text-white transition hover:bg-white/12"
          title="系统设置"
          @click="$emit('settings')"
        >
          <AppIcon name="settings" :size="20" />
        </button>
        <button
          type="button"
          class="inline-flex h-10 items-center gap-2 rounded-[10px] text-sm font-medium text-white transition hover:bg-white/12"
          :title="userName ? `${userName} · 个人中心` : '个人中心'"
          @click="$emit('profile')"
        >
          <span class="inline-flex h-8 w-8 items-center justify-center rounded-full bg-white/16">
            <AppIcon name="user" :size="18" />
          </span>
          <span class="hidden 2xl:inline">{{ userName }}</span>
        </button>
      </div>
    </div>
  </header>
</template>
