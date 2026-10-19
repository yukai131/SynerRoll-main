/**
 * Julia 后端 HTTP 基地址。
 * 优先级：环境变量 JULIA_BACKEND_URL > 默认 http://127.0.0.1:8080
 * 可在模块顶层调用；打包启动器通过设置 JULIA_BACKEND_URL 注入实际端口。
 */
export const getJuliaBackendBase = (): string => {
  const envUrl = process.env.JULIA_BACKEND_URL
  if (envUrl) return envUrl.replace(/\/$/, '')
  return 'http://127.0.0.1:8080'
}

/** 拼接 Julia API 完整 URL，path 以 / 开头 */
export const juliaUrl = (path: string): string => {
  const base = getJuliaBackendBase()
  return `${base}${path.startsWith('/') ? path : `/${path}`}`
}

/** 常用 API 前缀（模块顶层可调用） */
export const JULIA = {
  task: () => juliaUrl('/api/task'),
  taskList: () => juliaUrl('/api/task/list'),
  taskCreate: () => juliaUrl('/api/task/create'),
  boundary: () => juliaUrl('/api/boundary'),
  boundaryImport: () => juliaUrl('/api/boundary/import'),
  boundaryLoad: () => juliaUrl('/api/boundary/load'),
  boundarySubmit: () => juliaUrl('/api/boundary/submit'),
  boundaryTransform: () => juliaUrl('/api/boundary/transform'),
  boundaryDelete: () => juliaUrl('/api/boundary/delete'),
  fittingFit: () => juliaUrl('/api/fitting/fit'),
  capacityPlanning: () => juliaUrl('/api/capacity-planning'),
  capacityValidate: () => juliaUrl('/api/capacity-planning/validate'),
  capacityFormSchema: () => juliaUrl('/api/capacity-planning/form-schema'),
  capacityScenariosPreview: () => juliaUrl('/api/capacity-planning/scenarios/preview'),
  ingestTs: () => juliaUrl('/api/ingest/ts'),
  ingestProject: () => juliaUrl('/api/ingest/project'),
  health: () => juliaUrl('/api/health')
} as const
