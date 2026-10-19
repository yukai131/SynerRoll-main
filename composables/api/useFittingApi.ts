import type {
  FittingCurvePoint,
  FittingScatterPoint,
  FittingStats,
  FittingType,
  PvFittingParams,
  WindFittingParams
} from '~~/types/fitting'

export interface FitFittingRequest {
  type: FittingType
  filePath: string
  powerColumn: string
  inputColumns: string[]
}

export interface FitFittingResult {
  type: FittingType
  params: WindFittingParams | PvFittingParams
  formulaText: string
  scatter: FittingScatterPoint[]
  curve: FittingCurvePoint[]
  stats: FittingStats
}

export function useFittingApi() {
  const fit = async (payload: FitFittingRequest): Promise<FitFittingResult> => {
    const res = await $fetch<{ success: boolean; data?: FitFittingResult; message?: string }>(
      '/api/v1/fitting/fit',
      { method: 'POST', body: payload }
    )
    if (!res.success || !res.data) {
      throw new Error(res.message || '拟合失败')
    }
    return res.data
  }

  return { fit }
}
