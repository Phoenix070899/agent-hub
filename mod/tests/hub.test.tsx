import { describe, expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { needsHuman } from '../hooks/report'
import { header, toRows } from '../hooks/dashboard'
import type { DispatchRecord } from '../hooks/dashboard'

const REPO = '/repo'
const NOW = Date.parse('2026-10-16T10:00:00Z')

const record = (over: Partial<DispatchRecord>): DispatchRecord => ({
  id: 'ctx_1',
  status: 'dispatched',
  handle: 'term_1',
  title: 'naruto: add subtract',
  worktree: `r::${REPO}`,
  dispatched_at: '2026-10-16 09:58:00',
  completed_at: null,
  last_message_at: null,
  last_type: null,
  last_subject: null,
  open_questions: 0,
  ...over,
})

describe('toRows', () => {
  test('puts blocked Workers first and names the worktree', () => {
    const rows = toRows(
      [
        record({ id: 'a', last_message_at: '2026-10-16T09:59:30Z' }),
        record({
          id: 'b',
          title: 'hinata: map auth',
          worktree: 'r::/w/e2e-auth',
          last_type: 'question',
          last_subject: 'Blocked: permission_prompt',
        }),
      ],
      REPO,
      NOW,
    )
    expect(rows.map(row => [row.dispatchId, row.state, row.profile, row.place])).toEqual([
      ['b', 'needs you', 'hinata', 'e2e-auth'],
      ['a', 'running', 'naruto', 'in place'],
    ])
    expect(rows[1]?.quietSeconds).toBe(30)
  })

  test('an open ask is needs you; settled Workers leave after 10 minutes', () => {
    const rows = toRows(
      [
        record({ id: 'q', open_questions: 1 }),
        record({ id: 'recent', status: 'completed', completed_at: '2026-10-16 09:55:00' }),
        record({ id: 'old', status: 'failed', completed_at: '2026-10-16 09:40:00' }),
      ],
      REPO,
      NOW,
    )
    expect(rows.map(row => [row.dispatchId, row.state])).toEqual([
      ['q', 'needs you'],
      ['recent', 'done'],
    ])
    expect(header(rows)).toBe('Needs you 1 · Running 0 · Done 1')
  })
})

const SQLITE_ROWS = JSON.stringify([
  record({ id: 'ctx_9', handle: 'term_9', title: 'hinata: map auth flow', last_type: 'question', last_subject: 'Blocked: permission_prompt' }),
])

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
  test(`the band lists Workers from Orca on ${surface}`, async ($, on) => {
    world(on)
    const ran: string[][] = []
    on('process.run', ($, e) => {
      ran.push([...e.argv])
      const stdout =
        e.argv[0] === 'git' ? `${REPO}\n` : e.argv[0] === 'printenv' ? '/home/me\n' : e.argv[0] === 'sqlite3' ? SQLITE_ROWS : ''
      return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    })
    await $.session.start({ cwd: REPO, surface, isInteractive: true })

    const ui = await $.ui.mount({ plugin: 'hub', surface, component: 'AbovePrompt', props: band(100) })
    expect(await ui.find({ type: 'Text', text: /◆ Needs you 1/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /● Running 0/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /◆ needs you/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /map auth flow/ })).toBeDefined()

    const query = ran.find(argv => argv[0] === 'sqlite3')
    expect(query?.[1]).toBe('-readonly')
    expect(query?.[3]).toBe('file:/home/me/Library/Application Support/orca/orchestration.db?mode=ro')

    await ui.press({ key: 'go-ctx_9' })
    expect(ran.at(-1)).toEqual(['orca', 'terminal', 'switch', '--terminal', 'term_9'])
  })
}

test('no Workers draws no band', async ($, on) => {
  world(on)
  on('process.run', ($, e) => ({
    value: {
      exitCode: 0,
      stdout: e.argv[0] === 'sqlite3' ? '' : `${REPO}\n`,
      stderr: '',
      isStdoutTruncated: false,
      isStderrTruncated: false,
    },
  }))
  await $.session.start({ cwd: REPO, surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount({ plugin: 'hub', surface: 'terminal', component: 'AbovePrompt', props: band(100) })
  expect(await ui.find({ type: 'Text', text: /Workers ·/ })).toBeUndefined()
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
  const rows = JSON.stringify([
    record({ id: 'n', handle: 'term_n', title: 'hinata: blocked one', open_questions: 1 }),
    record({ id: 'r', handle: 'term_r', title: 'naruto: running one' }),
    record({ id: 'd', handle: 'term_d', title: 'sasuke: done one', status: 'completed', completed_at: '2026-10-16 09:58:00' }),
  ])
  on('process.run', ($, e) => ({
    value: {
      exitCode: 0,
      stdout: e.argv[0] === 'sqlite3' ? rows : e.argv[0] === 'printenv' ? '/home/me\n' : `${REPO}\n`,
      stderr: '',
      isStdoutTruncated: false,
      isStderrTruncated: false,
    },
  }))
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

test('background rows are one dim line; the human prompt is a rounded card', async ($, on) => {
  world(on)
  on('ui.render', { component: 'UserMessage' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>{e.props.text}</Text>
  })
  const row = (text: string, kind: 'composer' | 'task-notification') =>
    $.ui.mount({ plugin: 'hub', surface: 'terminal', component: 'UserMessage', props: { text, origin: { kind }, isExpanded: false } as never })
  const mine = await row('run the tests', 'composer')
  const plain = await mine.find({ type: 'Text', text: /run the tests/ })
  expect(plain?.props.dimColor).toBeUndefined()
  expect((await mine.find({ type: 'Box' }))?.props.borderStyle).toBe('round')
  const task = await row('Background command "Listen" completed\nmore', 'task-notification')
  const dim = await task.find({ type: 'Text', text: /Background command "Listen" completed/ })
  expect(dim?.props.dimColor).toBe(true)
  const nudge = await row('You have 1 orchestration message. Run `orca orchestration check`.', 'composer')
  expect((await nudge.find({ type: 'Text', text: /You have 1 orchestration message/ }))?.props.dimColor).toBe(true)
})
