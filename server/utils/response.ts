import type { ApiResponse } from '~~/types/api'

export const apiSuccess = <T>(data: T, message?: string): ApiResponse<T> => ({
  success: true,
  data,
  message
})

/**
 * 业务失败（参数错、列名错、数据不合法等）→ 400，message 为可直接展示的中文原因。
 * 已是 H3Error 则原样抛出，避免被外层再包成 500。
 */
export function throwUserError(message: string, statusCode = 400): never {
  throw createError({ statusCode, message })
}

/** 后端返回 success=false 时调用 */
export function throwBackendBizError(message: string | undefined, fallback: string): never {
  throwUserError(message || fallback, 400)
}

/**
 * 捕获异常后抛出可展示错误：
 * - 已有 statusCode 的业务错误原样抛出
 * - 网络/连接问题 → 502，提示启动后端
 * - 其它 → 尽量展示原始中文原因，不加 "Julia backend error" 前缀
 */
export function rethrowAsApiError(error: unknown, fallback: string): never {
  if (error && typeof error === 'object' && 'statusCode' in error) {
    throw error
  }
  const raw = error instanceof Error ? error.message : String(error)
  const message = raw.replace(/^Julia backend error:\s*/i, '').trim() || fallback
  const isNetwork =
    /fetch failed|ECONNREFUSED|ECONNRESET|network|socket hang up|AggregateError/i.test(raw)
  throwUserError(
    isNetwork ? '无法连接计算后端，请确认 Julia 服务已启动' : message,
    isNetwork ? 502 : 400,
  )
}
