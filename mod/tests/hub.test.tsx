import { describe, expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { needsHuman } from '../hooks/report'

const REPO = '/repo'
const NOW = Date.parse('2026-10-16T10:00:00Z')

/** What the engine beneath the plugin answers in these tests: session start, commands, the clock. */
const world = (on: On) => {
  mock.clock(on, { now: NOW })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
}

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

test('needsHuman reads the Needs you section', () => {
  expect(needsHuman('Needs you\n- Nothing.\nDone\n- Task 1')).toBe(false)
  expect(needsHuman('**Needs you**\n- Approve `rm -rf build`\n**Done**\n- none')).toBe(true)
  expect(needsHuman('## Needs you\n1. Merge feat/x?\n## Running\n- naruto')).toBe(true)
  expect(needsHuman('Needs you: nothing\nDone: Task 2')).toBe(false)
  expect(needsHuman('The test passed.')).toBe(false)
})

for (const surface of ['terminal', 'desktop'] as const) {
  test(`replies draw on a half-tint card, amber when they need the human, on ${surface}`, async ($, on) => {
    world(on)
    on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
      const { Text } = $.ui.resolve(e)
      return <Text>{e.props.text}</Text>
    })
    const reply = (text: string) =>
      $.ui.mount({ plugin: 'hub', surface, component: 'AssistantMessage', props: { text, isFirstOfReply: true } })
    const calm = await reply('Needs you\n- Nothing.\nDone\n- ok')
    expect((await calm.find({ type: 'Box' }))?.props.backgroundColor).toBe('#0f161e')
    expect((await calm.find({ type: 'Box' }))?.props.borderStyle).toBe('round')
    const urgent = await reply('Needs you\n- Approve the merge of feat/x')
    expect((await urgent.find({ type: 'Box' }))?.props.backgroundColor).toBe('#1e1900')
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
