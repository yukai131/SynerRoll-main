import type {
  CapacityVariableDraft,
  BoundaryDataset,
  BoundaryDatasetSummary,
  ApplyCapacityPlanningRequest,
  ApplyCapacityPlanningResult,
  ApplyCapacityPlanningPreview,
  CapacityPlanningResult,
  CapacityPlanningTask,
  CapacityPlanningFormSchema,
  CapacityPlanningComparison,
  CapacityApplyRecord,
  CapacityEconomicsConfig,
  ClusteringConfig,
  ImportBoundaryDatasetRequest,
  ScenarioPreviewResult,
  CreateCapacityPlanningRequest,
  CapacityVariableValidationRequest,
  CapacityVariableValidationResult
} from '~~/types/capacity-planning'
import { useApiClient } from './useApiClient'

export const useCapacityPlanningApi = () => {
  const apiClient = useApiClient()

  const getFormSchema = (projectId: string, canvasId: string) =>
    apiClient.mutate<CapacityPlanningFormSchema>('/capacity-planning/form-schema', {
      method: 'POST',
      body: { projectId, canvasId }
    })

  const validateVariables = (request: CapacityVariableValidationRequest) =>
    apiClient.mutate<CapacityVariableValidationResult>('/capacity-planning/validate', {
      method: 'POST',
      body: request
    })

  const listDatasets = (projectId: string) =>
    apiClient.get<{ datasets: BoundaryDatasetSummary[] }>(
      `/capacity-planning/datasets?projectId=${encodeURIComponent(projectId)}`
    )

  const getDataset = (projectId: string, datasetId: string) =>
    apiClient.get<BoundaryDataset>(
      `/capacity-planning/datasets/${encodeURIComponent(datasetId)}?projectId=${encodeURIComponent(projectId)}`
    )

  const importDataset = (request: ImportBoundaryDatasetRequest) =>
    apiClient.mutate<BoundaryDataset>('/capacity-planning/datasets/import', {
      method: 'POST',
      body: request
    })

  const previewScenarios = (request: ClusteringConfig) =>
    apiClient.mutate<ScenarioPreviewResult>('/capacity-planning/scenarios/preview', {
      method: 'POST',
      body: request
    })

  const createPlanning = (request: CreateCapacityPlanningRequest) =>
    apiClient.mutate<CapacityPlanningTask>('/capacity-planning', {
      method: 'POST',
      body: request
    })

  const startPlanning = (planningId: string) =>
    apiClient.mutate<CapacityPlanningTask>(`/capacity-planning/${encodeURIComponent(planningId)}/start`, {
      method: 'POST'
    })

  const cancelPlanning = (planningId: string) =>
    apiClient.mutate<CapacityPlanningTask>(`/capacity-planning/${encodeURIComponent(planningId)}/cancel`, {
      method: 'POST'
    })

  const getPlanning = (planningId: string) =>
    apiClient.get<CapacityPlanningTask>(`/capacity-planning/${encodeURIComponent(planningId)}`)

  const getPlanningResult = (planningId: string) =>
    apiClient.get<CapacityPlanningResult>(`/capacity-planning/${encodeURIComponent(planningId)}/result`)

  // C-405 方案比较
  const getPlanningComparison = (planningId: string) =>
    apiClient.get<CapacityPlanningComparison>(`/capacity-planning/${encodeURIComponent(planningId)}/comparison`)

  const listPlannings = (projectId: string) =>
    apiClient.get<{ tasks: CapacityPlanningTask[] }>(
      `/capacity-planning?projectId=${encodeURIComponent(projectId)}`
    )

  const updatePlanningConfig = (planningId: string, config: {
    clustering?: Partial<ClusteringConfig>
    variables?: CapacityVariableDraft[]
    economics?: CapacityEconomicsConfig
  }) =>
    apiClient.mutate<CapacityPlanningTask>(
      `/capacity-planning/${encodeURIComponent(planningId)}/config`,
      {
        method: 'PUT',
        body: config
      }
    )

  const applyAndSimulate = (planningId: string, request: ApplyCapacityPlanningRequest) =>
    apiClient.mutate<ApplyCapacityPlanningResult>(
      `/capacity-planning/${encodeURIComponent(planningId)}/apply-and-simulate`,
      {
        method: 'POST',
        body: request
      }
    )

  const getApplyPreview = (planningId: string) =>
    apiClient.get<ApplyCapacityPlanningPreview>(
      `/capacity-planning/${encodeURIComponent(planningId)}/apply-preview`
    )

  // C-406 安全应用：应用记录与撤销/恢复
  const listApplies = (planningId: string) =>
    apiClient.get<{ applies: CapacityApplyRecord[] }>(
      `/capacity-planning/${encodeURIComponent(planningId)}/applies`
    )

  const undoApply = (applyId: string) =>
    apiClient.mutate<{ applyId: string; status: string; projectUpdatedAt: string }>(
      `/capacity-planning/applies/${encodeURIComponent(applyId)}/undo`,
      { method: 'POST' }
    )

  const redoApply = (applyId: string) =>
    apiClient.mutate<{ applyId: string; status: string; projectUpdatedAt: string }>(
      `/capacity-planning/applies/${encodeURIComponent(applyId)}/redo`,
      { method: 'POST' }
    )

  return {
    getFormSchema,
    validateVariables,
    listDatasets,
    getDataset,
    importDataset,
    previewScenarios,
    createPlanning,
    startPlanning,
    cancelPlanning,
    getPlanning,
    getPlanningResult,
    getPlanningComparison,
    listPlannings,
    updatePlanningConfig,
    applyAndSimulate,
    getApplyPreview,
    listApplies,
    undoApply,
    redoApply
  }
}
