import { apiSuccess } from '#server/utils/response'
import { getJuliaBackendBase, juliaUrl } from '#server/utils/julia'

/**
 * 健康检查：报告 BFF 自身状态，并探测 Julia 计算后端与求解器可用性。
 * 启动器（Electron）轮询本接口判断服务是否就绪。
 */
export default defineEventHandler(async () => {
  const juliaBase = getJuliaBackendBase()
  let juliaStatus: 'ok' | 'unreachable' = 'unreachable'
  let juliaInfo: Record<string, unknown> = {}
  let solvers: Record<string, boolean> = {}

  try {
    const res = await $fetch<{
      status?: string
      service?: string
      version?: string
      port?: number
      solvers?: Record<string, boolean>
      default_solver?: string
    }>(juliaUrl('/health'), {
      method: 'GET',
      timeout: 5000
    })
    if (res?.status === 'ok') {
      juliaStatus = 'ok'
      juliaInfo = {
        service: res.service ?? 'synerroll-backend',
        version: res.version,
        port: res.port,
        defaultSolver: res.default_solver
      }
      solvers = res.solvers ?? {}
    }
  } catch {
    juliaStatus = 'unreachable'
  }

  return apiSuccess({
    bff: 'ok',
    julia: juliaStatus,
    juliaBase,
    juliaInfo,
    solvers,
    ready: juliaStatus === 'ok'
  })
})
