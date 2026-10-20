import { describe, expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { needsHuman } from '../hooks/report'
import { parseStatus } from '../hooks/dashboard'
import type { WorkerRow } from '../types'

const REPO = '/repo'
const NOW = Date.parse('2026-10-16T10:00:00Z')

const row = (over: Partial<WorkerRow>): WorkerRow => ({
  id: 'w1',
  profile: 'naruto',
  title: 'add subtract',
  state: 'running',
  quietSeconds: 30,
  place: 'in place',
  ...over,
})

/** A `process.run` answer: `hub status --json` prints `rows`; anything else prints nothing. */
const hubStatus = (rows: WorkerRow[], ran: string[][] = []) => ($: unknown, e: { argv: readonly string[] }) => {
  ran.push([...e.argv])
  const stdout = e.argv[0] === 'hub' && e.argv[1] === 'status' ? JSON.stringify(rows) : ''
  return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
}

describe('parseStatus', () => {
  test('keeps well-formed rows in the daemon order', () => {
    const rows = parseStatus(JSON.stringify([row({ id: 'w2', state: 'needs you' }), row({})]))
    expect(rows.map(r => [r.id, r.state])).toEqual([
      ['w2', 'needs you'],
      ['w1', 'running'],
    ])
  })

  test('drops malformed rows and output', () => {
    expect(parseStatus('not json')).toEqual([])
    expect(parseStatus('{}')).toEqual([])
    expect(parseStatus(JSON.stringify([{ id: 'w1', title: 't', state: 'sleeping' }, row({ id: 'w3' })])).map(r => r.id)).toEqual(['w3'])
  })
})

/** What the engine beneath the plugin answers in these tests: session start, commands, the clock. */
const world = (on: On) => {
  mock.clock(on, { now: NOW })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  // The engine's own band, drawn when the plugin passes: an empty row.
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Box } = $.ui.resolve(e)
    return <Box />
  })
}

const band = (columns: number) => ({
  hasSurvey: false,
  isWorking: false,
  maxRows: 10,
  bodyColumns: columns,
  scroll: { offset: 0, bodyRows: 9 },
  view: {},
})

for (const surface of ['terminal', 'desktop'] as const) {
  test(`the band lists Workers from the Hub Daemon on ${surface}`, async ($, on) => {
    world(on)
    const ran: string[][] = []
    on('process.run', hubStatus([row({ id: 'w9', profile: 'hinata', title: 'map auth flow', state: 'needs you' })], ran))
    await $.session.start({ cwd: REPO, surface, isInteractive: true })

    const ui = await $.ui.mount({ plugin: 'hub', surface, component: 'AbovePrompt', props: band(100) })
    expect(await ui.find({ type: 'Text', text: /◆ Needs you 1/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /● Running 0/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /◆ needs you/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /map auth flow/ })).toBeDefined()
    expect(ran[0]).toEqual(['hub', 'status', '--json'])

    await ui.press({ key: 'go-w9' })
    expect(ran.at(-1)).toEqual(['hub', 'open', 'w9'])
  })
}

test('no Workers draws no band', async ($, on) => {
  world(on)
  on('process.run', hubStatus([]))
  await $.session.start({ cwd: REPO, surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount({ plugin: 'hub', surface: 'terminal', component: 'AbovePrompt', props: band(100) })
  expect(await ui.find({ type: 'Text', text: /Workers/ })).toBeUndefined()
})

for (const surface of ['terminal', 'desktop'] as const) {
  test(`tool calls fold until /tools on ${surface}`, async ($, on) => {
    world(on)
    on('ui.render', { component: 'ToolGroup' }, ($, e) => {
      const { Text } = $.ui.resolve(e)
      return <Text>Read 3 files</Text>
    })
    on('ui.render', { component: 'ToolUse' }, ($, e) => {
      const { Text } = $.ui.resolve(e)
      return <Text>Bash(ls)</Text>
    })
    const call = { tool: 'Read', input: {}, isRunning: false, isErrored: false, isInterrupted: false }
    const group = { calls: [call, call, call], isActive: false, isExpanded: false }

    const folded = await $.ui.mount({ plugin: 'hub', surface, component: 'ToolGroup', props: group })
    expect(await folded.find({ type: 'Text', text: '⋯ 3 tool calls' })).toBeDefined()
    const expanded = await $.ui.mount({ plugin: 'hub', surface, component: 'ToolGroup', props: { ...group, isExpanded: true } })
    expect(await expanded.find({ type: 'Text', text: 'Read 3 files' })).toBeDefined()

    const use = { tool_use_id: 't1', tool: 'Bash', input: { command: 'ls' }, isRunning: false, isErrored: false, isInterrupted: false }
    const hidden = await $.ui.mount({ plugin: 'hub', surface, component: 'ToolUse', props: use })
    expect(await hidden.find({ type: 'Text', text: 'Bash(ls)' })).toBeUndefined()

    await $.command.run({ command: 'tools', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: false, columns: 100 } })
    const shown = await $.ui.mount({ plugin: 'hub', surface, component: 'ToolUse', props: use })
    expect(await shown.find({ type: 'Text', text: 'Bash(ls)' })).toBeDefined()
  })
}

test('worker badges are yellow needs you, blue running, green done', async ($, on) => {
  world(on)
  on(
    'process.run',
    hubStatus([
      row({ id: 'w1', profile: 'hinata', title: 'blocked one', state: 'needs you' }),
      row({ id: 'w2', title: 'running one' }),
      row({ id: 'w3', profile: 'sasuke', title: 'done one', state: 'done' }),
    ]),
  )
  await $.session.start({ cwd: REPO, surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount({ plugin: 'hub', surface: 'terminal', component: 'AbovePrompt', props: band(120) })
  expect((await ui.find({ type: 'Text', text: /^◆ needs you/ }))?.props.color).toBe('yellow')
  expect((await ui.find({ type: 'Text', text: /^● running/ }))?.props.color).toBe('blue')
  expect((await ui.find({ type: 'Text', text: /^✓ done/ }))?.props.color).toBe('green')
})

test('needsHuman reads the Needs you section', () => {
  expect(needsHuman('Needs you\n- Nothing.\nDone\n- Task 1')).toBe(false)
  expect(needsHuman('**Needs you**\n- Approve `rm -rf build`\n**Done**\n- none')).toBe(true)
  expect(needsHuman('## Needs you\n1. Merge feat/x?\n## Running\n- naruto')).toBe(true)
  expect(needsHuman('Needs you: nothing\nDone: Task 2')).toBe(false)
  expect(needsHuman('The test passed.')).toBe(false)
})

for (const surface of ['terminal', 'desktop'] as const) {
  test(`replies draw on a background, amber when they need the human, on ${surface}`, async ($, on) => {
    world(on)
    on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
      const { Text } = $.ui.resolve(e)
      return <Text>{e.props.text}</Text>
    })
    const reply = (text: string) =>
      $.ui.mount({ plugin: 'hub', surface, component: 'AssistantMessage', props: { text, isFirstOfReply: true } })
    const calm = await reply('Needs you\n- Nothing.\nDone\n- ok')
    expect((await calm.find({ type: 'Box' }))?.props.backgroundColor).toBe('#1f2d3d')
    expect((await calm.find({ type: 'Box' }))?.props.borderStyle).toBe('round')
    const urgent = await reply('Needs you\n- Approve the merge of feat/x')
    expect((await urgent.find({ type: 'Box' }))?.props.backgroundColor).toBe('#3d3200')
  })
}

test('background rows are one dim line; the human prompt is untouched', async ($, on) => {
  world(on)
  on('ui.render', { component: 'UserMessage' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>{e.props.text}</Text>
  })
  const message = (text: string, kind: 'composer' | 'task-notification') =>
    $.ui.mount({ plugin: 'hub', surface: 'terminal', component: 'UserMessage', props: { text, origin: { kind }, isExpanded: false } as never })
  const mine = await message('run the tests', 'composer')
  const plain = await mine.find({ type: 'Text', text: /run the tests/ })
  expect(plain?.props.dimColor).toBeUndefined()
  const task = await message('Background command "Listen" completed\nmore', 'task-notification')
  const dim = await task.find({ type: 'Text', text: /Background command "Listen" completed/ })
  expect(dim?.props.dimColor).toBe(true)
})
