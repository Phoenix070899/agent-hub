import type { WorkerRow, WorkerState } from '../types'

const STATES: readonly WorkerState[] = ['needs you', 'running', 'failed', 'done']

/**
 * The Dashboard rows from `hub status --json`: the Hub Daemon already filters, orders, and
 * names them. Anything malformed is dropped rather than drawn.
 */
export const parseStatus = (stdout: string): WorkerRow[] => {
  let parsed: unknown
  try {
    parsed = JSON.parse(stdout)
  } catch {
    return []
  }
  if (!Array.isArray(parsed)) return []
  return parsed.flatMap((row): WorkerRow[] => {
    if (typeof row !== 'object' || row === null) return []
    const { id, profile, title, state, quietSeconds, place } = row as Record<string, unknown>
    if (typeof id !== 'string' || typeof title !== 'string' || !STATES.includes(state as WorkerState)) return []
    return [
      {
        id,
        profile: typeof profile === 'string' ? profile : 'worker',
        title,
        state: state as WorkerState,
        quietSeconds: typeof quietSeconds === 'number' ? quietSeconds : 0,
        place: typeof place === 'string' ? place : '',
      },
    ]
  })
}

export const formatAge = (seconds: number) =>
  seconds < 60 ? `${seconds}s` : seconds < 3600 ? `${Math.floor(seconds / 60)}m` : `${Math.floor(seconds / 3600)}h`
