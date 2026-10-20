import type { SolverName } from '~~/types/simulation'

export const DEFAULT_SOLVER: SolverName = 'HiGHS'

export const SOLVER_OPTIONS: Array<{ label: string; value: SolverName }> = [
  { label: 'HiGHS（默认）', value: 'HiGHS' },
  { label: 'COPT（商业）', value: 'COPT' },
]

export function isSolverName(value: unknown): value is SolverName {
  return value === 'HiGHS' || value === 'COPT'
}
