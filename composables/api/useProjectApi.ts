import type {
  CopyProjectRequest,
  CreateProjectRequest,
  ProjectDetailResponse,
  ProjectListResponse,
  SaveCanvasRequest,
  SaveLayerConfigRequest,
  UpdateAlgorithmConfigRequest,
  UpdateProjectRequest
} from '~~/types/api'
import type { AlgorithmConfig, SolverConfig } from '~~/types/simulation'
import { useApiClient } from './useApiClient'

export const useProjectApi = () => {
  const apiClient = useApiClient()

  return {
    listProjects: () => apiClient.get<ProjectListResponse>('/project'),
    getProject: (projectId: string) => apiClient.get<ProjectDetailResponse>(`/project/${projectId}`),
    createProject: (payload: CreateProjectRequest) =>
      apiClient.mutate<ProjectDetailResponse>('/project', { method: 'POST', body: payload }),
    copyProject: (projectId: string, payload: CopyProjectRequest = {}) =>
      apiClient.mutate<ProjectDetailResponse>(`/project/${projectId}/copy`, { method: 'POST', body: payload }),
    updateProject: (projectId: string, payload: UpdateProjectRequest) =>
      apiClient.mutate<ProjectDetailResponse>(`/project/${projectId}`, { method: 'PUT', body: payload }),
    deleteProject: (projectId: string) => apiClient.mutate<{ projectId: string }>(`/project/${projectId}`, { method: 'DELETE' }),
    getCanvas: (projectId: string) => apiClient.get<{ workspace: import('~~/types/canvas').CanvasWorkspace }>(`/project/${projectId}/canvas`),
    saveCanvas: (projectId: string, payload: SaveCanvasRequest) =>
      apiClient.mutate<ProjectDetailResponse>(`/project/${projectId}/canvas`, { method: 'PUT', body: payload }),
    getAlgorithmConfig: (projectId: string) =>
      apiClient.get<{ algorithm: AlgorithmConfig; solverConfig: SolverConfig }>(`/project/${projectId}/algorithm-config`),
    saveAlgorithmConfig: (projectId: string, payload: UpdateAlgorithmConfigRequest) =>
      apiClient.mutate<ProjectDetailResponse>(`/project/${projectId}/algorithm-config`, { method: 'PUT', body: payload }),
    saveBoundaries: (
      projectId: string,
      boundaries: import('~~/types/boundary').BoundaryItem[],
      fittingModels?: import('~~/types/fitting').FittingModel[]
    ) =>
      apiClient.mutate<ProjectDetailResponse>(`/project/${projectId}/boundary`, {
        method: 'PUT',
        body: {
          // 大时序只存 boundary.db，不随元数据上传（与 boundary.put 剥离策略对齐）
          boundaries: boundaries.map(({ rawData: _r, transformedData: _t, ...rest }) => rest),
          ...(fittingModels ? { fittingModels } : {})
        }
      }),
    saveLayerConfig: (projectId: string, payload: SaveLayerConfigRequest) =>
      apiClient.mutate<ProjectDetailResponse>(`/project/${projectId}/layer-config`, { method: 'PUT', body: payload }),
    /** boundary.db 中已提交数据的边界 ID 列表 */
    getBoundaryStatus: (projectId: string) =>
      apiClient.mutate<{ boundaryIds: string[] }>('/boundary/status', {
        method: 'POST',
        body: { projectId }
      }),
  }
}
