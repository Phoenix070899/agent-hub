import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { WorkerRow, WorkerState } from '../types'
import { dispatchQuery, formatAge, header, toRows } from './dashboard'
import type { DispatchRecord } from './dashboard'

const workers = atom({ plugin: 'hub', key: 'workers' } as const, [])
const showTools = atom({ plugin: 'hub', key: 'showTools' } as const, false)
const turnTools = atom({ plugin: 'hub', key: 'turnTools' } as const, 0)

const POLL_MS = 5000

const STATE_COLOR: Record<WorkerState, string | undefined> = {
  'needs you': 'yellow',
  running: undefined,
  failed: 'red',
  done: undefined,
}

const formatDuration = (ms: number) => {
  const seconds = Math.round(ms / 1000)
  return seconds < 60 ? `${seconds}s` : `${Math.floor(seconds / 60)}m ${seconds % 60}s`
}

const fit = (text: string, width: number) =>
  text.length <= width ? text.padEnd(width) : `${text.slice(0, Math.max(0, width - 1))}…`

async function poll($: EngineInterface, repo: string, database: string) {
  const { exitCode, stdout } = await $.process.run(
    ['sqlite3', '-readonly', '-json', `file:${database}?mode=ro`, dispatchQuery(repo)],
    { timeoutMs: 4000 },
  )
  if (exitCode !== 0) return
  const records: DispatchRecord[] = stdout.trim() ? JSON.parse(stdout) : []
  const rows = toRows(records, repo, await $.clock.now())
  await update($, workers, () => rows)
}

export const register: Register = on => {
  const toolsByLine = new Map<string, number>()
  let finishedTurnTools: number | null = null

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'tools',
      description: 'Show or fold the Orchestrator tool calls in the transcript',
    })

    const top = await $.process.run(['git', 'rev-parse', '--show-toplevel'])
    const repo = top.exitCode === 0 ? top.stdout.trim() : (await $.process.run(['pwd'])).stdout.trim()
    const home = (await $.process.run(['printenv', 'HOME'])).stdout.trim()
    const database = `${home}/Library/Application Support/orca/orchestration.db`

    const refresh = () => poll($, repo, database).catch(() => undefined)
    await refresh()
    $.clock.every(POLL_MS, () => void refresh())

    return next(e)
  })

  on('command.run', { command: 'tools' }, async $ => {
    const isShown = await update($, showTools, shown => !shown)
    $.ui.invalidate('ui.render')
    return { text: isShown ? 'Tool calls shown.' : 'Tool calls folded.' }
  })

  // Counting must never block a prompt or a tool call: on any failure, pass through.
  on('prompt.submit', async ($, e, next) => {
    await update($, turnTools, () => 0)
    return next(e)
  }).catch(($, e, next) => next(e))

  on('tool.call', async ($, e, next) => {
    await update($, turnTools, count => count + 1)
    return next(e)
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'ToolUse' }, async ($, e, next) => {
    if (await read($, showTools)) return next(e)
    const { Box } = $.ui.resolve(e)
    return <Box display="none" />
  })

  on('ui.render', { component: 'ToolResult' }, async ($, e, next) => {
    if (await read($, showTools)) return next(e)
    const { Box } = $.ui.resolve(e)
    return <Box display="none" />
  })

  on('ui.render', { component: 'ToolProgress' }, async ($, e, next) =>
    (await read($, showTools)) ? next(e) : next({ ...e, props: { ...e.props, hint: '' } }),
  )

  on('ui.render', { component: 'ToolGroup' }, async ($, e, next) => {
    if (e.props.isExpanded || (await read($, showTools))) return next(e)
    const { Text } = $.ui.resolve(e)
    const count = e.props.calls.length
    return <Text dimColor>⋯ {count} tool {count === 1 ? 'call' : 'calls'}</Text>
  })

  on('turn.complete', async ($, e, next) => {
    finishedTurnTools = await read($, turnTools)
    return next(e)
  })

  on('ui.render', { component: 'TurnDuration' }, async ($, e, next) => {
    // Drawing is pure: no $.state writes here. The first draw of a turn's line takes the
    // count the turn finished with; a line first drawn after a reload shows the engine's own.
    let count = toolsByLine.get(e.requestId)
    if (count === undefined && finishedTurnTools !== null) {
      count = finishedTurnTools
      finishedTurnTools = null
      toolsByLine.set(e.requestId, count)
    }
    if (!count) return next(e)
    const { Text } = $.ui.resolve(e)
    const hint = (await read($, showTools)) ? '/tools to fold' : '/tools to show'
    return (
      <Text dimColor>
        ✻ {e.props.word} for {formatDuration(e.props.durationMs)} · {count} tool{' '}
        {count === 1 ? 'call' : 'calls'} · {hint}
      </Text>
    )
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const rows: WorkerRow[] = await read($, workers)
    if (e.props.hasSurvey || rows.length === 0) return next(e)

    const { Box, Button, Text } = $.ui.resolve(e)
    const width = e.props.bodyColumns
    const shown = rows.slice(0, Math.max(1, Math.min(9, e.props.maxRows - 1)))
    // hotkey "1: " (3) + profile (8) + gaps; the title takes what is left.
    const fixed = 3 + 8 + 1 + 10 + 1 + 5 + 2 + 16
    const titleWidth = Math.max(10, width - fixed)

    return (
      <Box flexDirection="column">
        <Text bold>Workers · {header(rows)}</Text>
        {shown.map((row, index) => (
          <Box key={row.dispatchId} flexDirection="row">
            <Button
              key={`go-${row.dispatchId}`}
              hotkey={String(index + 1)}
              plain
              label={fit(row.profile, 8)}
              onPress={() => void $.process.run(['orca', 'terminal', 'switch', '--terminal', row.handle])}
            />
            <Text wrap="truncate-end">
              {' '}
              <Text color={STATE_COLOR[row.state]} bold={row.state === 'needs you'} dimColor={row.state === 'done'}>
                {fit(row.state, 10)}
              </Text>{' '}
              <Text dimColor={row.state === 'done'}>{fit(row.title, titleWidth)}</Text>
              <Text dimColor>
                {formatAge(row.quietSeconds).padStart(5)}  {fit(row.place, 16)}
              </Text>
            </Text>
          </Box>
        ))}
      </Box>
    )
  })
}
