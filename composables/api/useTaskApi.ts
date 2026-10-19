import type {
  ComputeTask,
  ComputeTaskListResponse,
  CreateTaskRequest,
  EconomyEvaluationResult,
  TaskDataResponse,
  TaskFlexibilityResponse,
  TaskTraceDataResponse,
  TaskTraceStepsResponse
} from '~~/types/api'
import { useApiClient } from './useApiClient'

/**
 * 计算任务 API 封装
 * 文档：docs/compute-task-architecture.md
 *
 * REST 部分：透传到 Julia 后端
 * WebSocket：直接连 Julia（不走 BFF），URL 在 useTaskWebSocket 中配置
 */
export const useTaskApi = () => {
  const apiClient = useApiClient()

  return {
    createTask: (payload: CreateTaskRequest) =>
      apiClient.mutate<ComputeTask>(`/task/create`, {
        method: 'POST',
        body: payload
      }),

    listTasks: (params?: { projectId?: string; status?: string }) => {
      const q = new URLSearchParams()
      if (params?.projectId) q.set('projectId', params.projectId)
      if (params?.status) q.set('status', params.status)
      const qs = q.toString()
      return apiClient.get<ComputeTaskListResponse>(
        `/task/list${qs ? `?${qs}` : ''}`
      )
    },

    getState: (taskId: string) =>
      apiClient.get<ComputeTask>(`/task/${taskId}/state`),

    getConnection: (taskId: string) =>
      apiClient.get<Array<{ busLabel: string; busCode: string; variables: string[] }>>(
        `/task/${taskId}/connection`
      ),

    pause: (taskId: string) =>
      apiClient.mutate<Record<string, unknown>>(`/task/${taskId}/pause`, {
        method: 'POST'
      }),

    resume: (taskId: string) =>
      apiClient.mutate<Record<string, unknown>>(`/task/${taskId}/resume`, {
        method: 'POST'
      }),

    cancel: (taskId: string) =>
      apiClient.mutate<Record<string, unknown>>(`/task/${taskId}/cancel`, {
        method: 'POST'
      }),

    cleanup: (taskId: string) =>
      apiClient.mutate<Record<string, unknown>>(`/task/${taskId}`, {
        method: 'DELETE'
      }),

    getData: (taskId: string, params?: {
      layerId?: string
      varName?: string
      sourceId?: string
      remark?: string
      /** 只拉 ts 分钟数 >= minMinutes 的增量点 */
      minMinutes?: number
      /** 增量时跳过边界序列 b_* */
      skipBoundary?: boolean
    }) => {
      const q = new URLSearchParams()
      if (params?.layerId) q.set('layerId', params.layerId)
      if (params?.varName) q.set('varName', params.varName)
      if (params?.sourceId) q.set('sourceId', params.sourceId)
      if (params?.remark) q.set('remark', params.remark)
      if (typeof params?.minMinutes === 'number' && params.minMinutes > 0) {
        q.set('minMinutes', String(params.minMinutes))
      }
      if (params?.skipBoundary) q.set('skipBoundary', '1')
      const qs = q.toString()
      return apiClient.get<TaskDataResponse>(
        `/task/${taskId}/data${qs ? `?${qs}` : ''}`
      )
    },

    getFlexibility: (taskId: string, layerId?: string, minMinutes?: number) => {
      const q = new URLSearchParams()
      if (layerId) q.set('layerId', layerId)
      if (typeof minMinutes === 'number' && minMinutes > 0) {
        q.set('minMinutes', String(minMinutes))
      }
      const qs = q.toString()
      return apiClient.get<TaskFlexibilityResponse>(
        `/task/${taskId}/flexibility${qs ? `?${qs}` : ''}`
      )
    },

    getTraceSteps: (taskId: string) =>
      apiClient.get<TaskTraceStepsResponse>(`/task/${taskId}/trace`),

    getTraceData: (taskId: string, step: number) =>
      apiClient.get<TaskTraceDataResponse>(`/task/${taskId}/trace/${step}`),

    getEconomy: (taskId: string) =>
      apiClient.get<EconomyEvaluationResult>(`/task/${taskId}/economy`)
  }
}