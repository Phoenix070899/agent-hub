import type { WorkerRow, WorkerState } from '../types'

/** Finished Workers leave the Dashboard this long after they settle. */
export const KEEP_SETTLED_SECONDS = 10 * 60

/** One row of the Dashboard query, as `sqlite3 -json` prints it. */
export type DispatchRecord = {
  id: string
  status: string
  handle: string | null
  title: string | null
  worktree: string | null
  dispatched_at: string | null
  completed_at: string | null
  last_message_at: string | null
  last_type: string | null
  last_subject: string | null
  open_questions: number
}

const quote = (text: string) => `'${text.replaceAll("'", "''")}'`

/**
 * Reads Orca's orchestration database without consuming anything: the Run whose
 * objective is `hub: <repo>`, each of its Dispatches with its Task, worktree,
 * last non-heartbeat message, and unanswered `ask` questions.
 */
export const dispatchQuery = (repo: string) => `
with run as (
  select id from runs where objective = ${quote(`hub: ${repo}`)}
  order by created_at desc limit 1
)
select d.id, d.status, d.assignee_handle as handle, t.task_title as title,
  (select w.worktree_id from worker_terminal_resources w
     where w.origin_dispatch_id = d.id order by w.created_at desc limit 1) as worktree,
  d.dispatched_at, d.completed_at,
  (select max(m.created_at) from messages m
     where m.run_id = d.run_id and m.from_handle = d.assignee_handle) as last_message_at,
  (select m.type from messages m where m.run_id = d.run_id
     and m.from_handle = d.assignee_handle and m.type != 'heartbeat'
     order by m.sequence desc limit 1) as last_type,
  (select m.subject from messages m where m.run_id = d.run_id
     and m.from_handle = d.assignee_handle and m.type != 'heartbeat'
     order by m.sequence desc limit 1) as last_subject,
  (select count(*) from question_threads q
     where q.dispatch_id = d.id and q.answered_at is null and q.closed_at is null) as open_questions
from dispatch_contexts d join tasks t on t.id = d.task_id
where d.run_id = (select id from run)
`

/** Orca stores `2026-10-16 03:47:44` and `2026-10-16T03:47:44Z`, both UTC. */
export const parseTime = (value: string | null): number | null => {
  if (!value) return null
  const iso = value.includes('T') ? value : value.replace(' ', 'T')
  const ms = Date.parse(iso.endsWith('Z') ? iso : `${iso}Z`)
  return Number.isNaN(ms) ? null : ms
}

const stateOf = (record: DispatchRecord): WorkerState => {
  if (record.status === 'completed') return 'done'
  if (record.status === 'failed') return 'failed'
  const isBlocked = record.last_type === 'question' && (record.last_subject ?? '').startsWith('Blocked:')
  return record.open_questions > 0 || isBlocked ? 'needs you' : 'running'
}

const ORDER: Record<WorkerState, number> = { 'needs you': 0, running: 1, failed: 2, done: 3 }

export const toRows = (records: DispatchRecord[], repo: string, nowMs: number): WorkerRow[] =>
  records
    .filter(record => {
      if (record.status !== 'completed' && record.status !== 'failed') return true
      const settledAt = parseTime(record.completed_at)
      return settledAt !== null && nowMs - settledAt < KEEP_SETTLED_SECONDS * 1000
    })
    .map(record => {
      const title = record.title ?? record.id
      const split = title.indexOf(': ')
      const path = record.worktree?.split('::').pop() ?? repo
      const lastAt = parseTime(record.last_message_at) ?? parseTime(record.dispatched_at) ?? nowMs
      return {
        dispatchId: record.id,
        handle: record.handle ?? '',
        profile: split > 0 ? title.slice(0, split) : 'worker',
        title: split > 0 ? title.slice(split + 2) : title,
        state: stateOf(record),
        quietSeconds: Math.max(0, Math.round((nowMs - lastAt) / 1000)),
        place: path === repo ? 'in place' : (path.split('/').pop() ?? path),
      }
    })
    .sort((a, b) => ORDER[a.state] - ORDER[b.state] || a.quietSeconds - b.quietSeconds)

export const formatAge = (seconds: number) =>
  seconds < 60 ? `${seconds}s` : seconds < 3600 ? `${Math.floor(seconds / 60)}m` : `${Math.floor(seconds / 3600)}h`

export const header = (rows: WorkerRow[]) => {
  const count = (state: WorkerState) => rows.filter(row => row.state === state).length
  const parts = [`Needs you ${count('needs you')}`, `Running ${count('running')}`, `Done ${count('done')}`]
  if (count('failed') > 0) parts.push(`Failed ${count('failed')}`)
  return parts.join(' · ')
}
