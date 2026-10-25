import tailwindcss from '@tailwindcss/vite'

export default defineNuxtConfig({
  compatibilityDate: '2026-04-13',
  debug: false,
  nitro: { debug: false },
  devtools: { enabled: false },
  ignore: ['**/packaging/**', '**/dist/**', '**/backend/**'],
  css: ['~/assets/css/main.css'],
  runtimeConfig: {
    // 服务端：Julia 后端 HTTP 基地址（可用环境变量 JULIA_BACKEND_URL 覆盖）
    juliaBackendUrl: process.env.JULIA_BACKEND_URL || 'http://127.0.0.1:8080',
    public: {
      apiBase: '/api/v1',
      // 计算任务 WebSocket 直连 Julia（不走 BFF）；可用 NUXT_PUBLIC_JULIA_WS_BASE 覆盖
      juliaWsBase: process.env.NUXT_PUBLIC_JULIA_WS_BASE || process.env.JULIA_WS_URL || 'ws://127.0.0.1:8080'
    }
  },
  vite: {
    plugins: [tailwindcss()],
    // 预打包画布重依赖，降低 dev 下首次打开编辑器时的模块请求数
    optimizeDeps: {
      include: [
        '@vue-flow/core',
        '@vue-flow/controls',
        '@vue-flow/minimap'
      ]
    }
  }
})
