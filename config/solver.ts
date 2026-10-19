import type { SolverName } from '~~/types/simulation'

export const DEFAULT_SOLVER: SolverName = 'HiGHS'

export const SOLVER_OPTIONS: Array<{ label: string; value: SolverName }> = [
  { label: 'HiGHS（默认，开源）', value: 'HiGHS' },
  { label: 'COPT（商业，需本机安装许可）', value: 'COPT' },
  { label: 'SCIP（开源 MILP）', value: 'SCIP' },
]

export function isSolverName(value: unknown): value is SolverName {
  return value === 'HiGHS' || value === 'COPT' || value === 'SCIP'
}
