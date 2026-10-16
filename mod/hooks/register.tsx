import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { WorkerRow, WorkerState } from '../types'
import { dispatchQuery, formatAge, toRows } from './dashboard'
import type { DispatchRecord } from './dashboard'
import { needsHuman } from './report'

const workers = atom({ plugin: 'hub', key: 'workers' } as const, [])
const showTools = atom({ plugin: 'hub', key: 'showTools' } as const, false)
const turnTools = atom({ plugin: 'hub', key: 'turnTools' } as const, 0)

const POLL_MS = 5000

/** Reply cards for a dark terminal theme: navy, or amber when the human must act. */
const REPLY = { background: '#1f2d3d', border: '#4a6d91' }
const REPLY_NEEDS_YOU = { background: '#3d3200', border: '#9a7d00' }

/** Each state's badge color: yellow needs you, blue running, green done, red failed. */
const STATE_BADGE: Record<WorkerState, { icon: string; color: string }> = {
  'needs you': { icon: '◆', color: 'yellow' },
  running: { icon: '●', color: 'blue' },
  failed: { icon: '✗', color: 'red' },
  done: { icon: '✓', color: 'green' },
}

/** One color per Worker row, cycled; none is a badge color (yellow, blue, green, red). */
const ROW_COLORS = ['cyan', 'magenta', 'white', 'cyanBright', 'magentaBright']

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

  // Replies are the content the human reads: drawn on a colored background so they stand
  // apart from folded tool rows. Amber when the reply's Needs you section lists something.
  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    if (!e.props.text.trim()) return next(e)
    const { Box, Markdown } = $.ui.resolve(e)
    if (e.props.isSummary) return <Markdown text={e.props.text} dimColor />
    const card = needsHuman(e.props.text) ? REPLY_NEEDS_YOU : REPLY
    return (
      <Box
        borderStyle="round"
        borderColor={card.border}
        backgroundColor={card.background}
        paddingX={2}
      >
        <Markdown text={e.props.text} />
      </Box>
    )
  })

  // The human's own message keeps the engine's row; everything else that is not a reply is
  // background: one dim line.
  on('ui.render', { component: 'UserMessage' }, async ($, e, next) => {
    const kind = e.props.origin.kind
    const isOrcaNudge = /^You have \d+ orchestration messages?\b/.test(e.props.text.trim())
    const isHuman = (kind === 'composer' || kind === 'bridge') && !isOrcaNudge
    if (e.props.isExpanded || isHuman) return next(e)
    const { Text } = $.ui.resolve(e)
    const line = e.props.text.trim().split('\n')[0] ?? ''
    return <Text dimColor wrap="truncate-end">⏺ {line}</Text>
  })

  on('ui.render', { component: 'CommandOutput' }, async ($, e, next) => {
    if (!e.props.text.trim()) return next(e)
    const { Markdown } = $.ui.resolve(e)
    return <Markdown text={e.props.text} dimColor />
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const rows: WorkerRow[] = await read($, workers)
    if (e.props.hasSurvey || rows.length === 0) return next(e)

    const { Box, Button, Text } = $.ui.resolve(e)
    // The border takes 2 columns and 2 rows, the header and its rule 2 rows.
    const width = e.props.bodyColumns - 4
    const shown = rows.slice(0, Math.max(1, Math.min(9, e.props.maxRows - 4)))
    const divider = <Text dimColor> │ </Text>
    // "1: " hotkey + "↗ " + profile 8 + badge 11 + age 4 + place 16 + four dividers of 3.
    const titleWidth = Math.max(10, width - (3 + 2 + 8 + 11 + 4 + 16 + 4 * 3))
    const count = (state: WorkerState) => rows.filter(row => row.state === state).length
    const metric = (state: WorkerState, label: string) => {
      const n = count(state)
      const badge = STATE_BADGE[state]
      return (
        <Text color={n > 0 ? badge.color : undefined} dimColor={n === 0} bold={n > 0 && state === 'needs you'}>
          {badge.icon} {label} {n}
        </Text>
      )
    }

    return (
      <Box flexDirection="column" borderStyle="round" borderDimColor paddingX={1}>
        <Text wrap="truncate-end">
          <Text bold>Workers</Text>
          {'   '}
          {metric('needs you', 'Needs you')}
          {'   '}
          {metric('running', 'Running')}
          {'   '}
          {metric('done', 'Done')}
          {count('failed') > 0 ? <Text>{'   '}{metric('failed', 'Failed')}</Text> : null}
        </Text>
        <Text dimColor>{'─'.repeat(Math.max(0, width))}</Text>
        {shown.map((row, index) => {
          const color = ROW_COLORS[index % ROW_COLORS.length]
          const badge = STATE_BADGE[row.state]
          return (
            <Box key={row.dispatchId} flexDirection="row">
              <Button
                key={`go-${row.dispatchId}`}
                hotkey={String(index + 1)}
                plain
                label="↗"
                onPress={() => void $.process.run(['orca', 'terminal', 'switch', '--terminal', row.handle])}
              />
              <Text wrap="truncate-end">
                {' '}
                <Text color={color} bold>{fit(row.profile, 8)}</Text>
                {divider}
                <Text color={badge.color} bold={row.state === 'needs you'}>
                  {fit(`${badge.icon} ${row.state}`, 11)}
                </Text>
                {divider}
                <Text color={color}>{fit(row.title, titleWidth)}</Text>
                {divider}
                <Text dimColor>{formatAge(row.quietSeconds).padStart(4)}</Text>
                {divider}
                <Text dimColor>{fit(row.place, 16)}</Text>
              </Text>
            </Box>
          )
        })}
      </Box>
    )
  })
}
