/** 同一任务、同一代页面的同类请求最多一个在途；失败后允许重试。 */
export function createTaskRequestGate() {
  const pending = new Map<string, Promise<unknown>>()
  return {
    run<T>(key: string, action: () => Promise<T>): Promise<T> {
      const existing = pending.get(key)
      if (existing) return existing as Promise<T>
      const request = Promise.resolve().then(action).finally(() => {
        if (pending.get(key) === request) pending.delete(key)
      })
      pending.set(key, request)
      return request
    },
  }
}
