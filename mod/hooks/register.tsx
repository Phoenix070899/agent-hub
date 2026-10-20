import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import { needsHuman } from './report'

const showTools = atom({ plugin: 'hub', key: 'showTools' } as const, false)
const turnTools = atom({ plugin: 'hub', key: 'turnTools' } as const, 0)

/**
 * Reply cards: navy, or amber when the human must act. A terminal cell holds one solid color,
 * so "50% opacity" is the card color mixed half-and-half with black, and there is no blur.
 */
const REPLY = { background: '#0f161e', border: '#4a6d91' }
const REPLY_NEEDS_YOU = { background: '#1e1900', border: '#9a7d00' }

const formatDuration = (ms: number) => {
  const seconds = Math.round(ms / 1000)
  return seconds < 60 ? `${seconds}s` : `${Math.floor(seconds / 60)}m ${seconds % 60}s`
}

export const register: Register = on => {
  const toolsByLine = new Map<string, number>()
  let finishedTurnTools: number | null = null

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'tools',
      description: 'Show or fold the Orchestrator tool calls in the transcript',
    })

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

  // Replies are the content the human reads: drawn on a tinted card so they stand
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
    const isHuman = kind === 'composer' || kind === 'bridge'
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
}
