import { describe, expect, test } from 'claude-code/testing'

import { SESSION, START, bandAt, rowOf, textOf, worldOf } from './world'

const ROOT = '/Users/me/.agentbar'
const CONFIG_ON = { [`${ROOT}/mods/config.json`]: JSON.stringify({ band: true }) }
const BENEATH = { type: 'Text', children: ['beneath'] } as const
const EMPTY = { type: 'Box', children: [] } as const

describe('the band above the prompt', () => {
  test('is off by default: a waiting session draws nothing of ours', async ($, on) => {
    const world = worldOf(on, {
      files: { [`${ROOT}/state.d/codex-1.json`]: rowOf({ agent: 'codex' }) },
    })
    on('ui.render', { component: 'AbovePrompt' }, () => BENEATH as never)
    await $.session.start(SESSION)
    await world.clock.advance(5000)
    expect(await $.ui.render(bandAt() as never)).toEqual(BENEATH)
    expect(world.invalidations).toBe(0)
  })

  test('on, with nobody waiting, draws nothing of ours', async ($, on) => {
    const world = worldOf(on, {
      files: {
        ...CONFIG_ON,
        [`${ROOT}/state.d/codex-1.json`]: rowOf({ state: 'tool' }),
        [`${ROOT}/state.d/sess-1.json`]: rowOf({ agent: 'claude', state: 'permission' }), // our own
        [`${ROOT}/state.d/hidden.json`]: rowOf({ started: false }),
        [`${ROOT}/state.d/stale.json`]: rowOf({ ts: Math.floor(START / 1000) - 3600 }),
        [`${ROOT}/state.d/broken.json`]: '{"agent":',
      },
    })
    on('ui.render', { component: 'AbovePrompt' }, () => BENEATH as never)
    await $.session.start(SESSION)
    await world.clock.advance(4000)
    expect(await $.ui.render(bandAt() as never)).toEqual(BENEATH)
  })

  test('on, with another session waiting, draws one line with Jump that opens its focus link', async ($, on) => {
    const world = worldOf(on, {
      files: {
        ...CONFIG_ON,
        [`${ROOT}/state.d/codex-019a.json`]: rowOf({ agent: 'codex', project: 'api' }),
      },
    })
    on('ui.render', { component: 'AbovePrompt' }, () => EMPTY as never)
    await $.session.start(SESSION)
    await world.clock.advance(2000)
    const tree = await $.ui.render(bandAt() as never)
    expect(textOf(tree)).toBe('◆ Codex needs your approval · apiJump')

    await $.ui.press({ plugin: 'agentbar', key: 'agentbar-jump' })
    expect(world.runs).toEqual([['/usr/bin/open', 'agentbar://focus?session=codex-019a']])
  })

  // Another Claude Code session whose mod reports a held call waits on you too,
  // though its row says working — unless the row has moved on since the hold.
  test('a session holding a command for you counts as waiting', async ($, on) => {
    const t = Math.floor(START / 1000)
    const held = (since: number) => JSON.stringify({ v: 1, held: { tool: 'Bash', input: { command: 'rm -r build' }, since } })
    const world = worldOf(on, {
      files: {
        ...CONFIG_ON,
        [`${ROOT}/state.d/other.json`]: rowOf({ agent: 'claude', state: 'tool', project: 'web', ts: t - 20 }),
        [`${ROOT}/mods.d/other.json`]: held(t - 10),
        [`${ROOT}/state.d/moved.json`]: rowOf({ agent: 'claude', state: 'tool', ts: t }),
        [`${ROOT}/mods.d/moved.json`]: held(t - 10),
      },
    })
    on('ui.render', { component: 'AbovePrompt' }, () => EMPTY as never)
    await $.session.start(SESSION)
    await world.clock.advance(2000)
    expect(textOf(await $.ui.render(bandAt() as never))).toBe('◆ Claude is holding a command for you · webJump')
  })

  test('several waiting: the longest-waiting first, and how many more', async ($, on) => {
    const t = Math.floor(START / 1000)
    const world = worldOf(on, {
      files: {
        ...CONFIG_ON,
        [`${ROOT}/state.d/g.json`]: rowOf({ agent: 'gemini', state: 'question', project: 'web', ts: t - 30 }),
        [`${ROOT}/state.d/c.json`]: rowOf({ agent: 'codex', ts: t - 5 }),
        [`${ROOT}/state.d/x.json`]: rowOf({ agent: 'aider', agent_name: 'Aider', ts: t - 1 }),
      },
    })
    on('ui.render', { component: 'AbovePrompt' }, () => EMPTY as never)
    await $.session.start(SESSION)
    await world.clock.advance(2000)
    expect(textOf(await $.ui.render(bandAt() as never))).toBe('◆ Gemini has a question · web · and 2 more' + 'Jump')
  })

  test('keeps what was drawn beneath it, under its own line', async ($, on) => {
    const world = worldOf(on, {
      files: { ...CONFIG_ON, [`${ROOT}/state.d/c.json`]: rowOf({}) },
    })
    on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
      const { Text } = $.ui.resolve(e)
      return Text({ children: 'another band' })
    })
    await $.session.start(SESSION)
    await world.clock.advance(2000)
    const text = textOf(await $.ui.render(bandAt() as never))
    expect(text.startsWith('◆ Codex needs your approval')).toBe(true)
    expect(text.endsWith('another band')).toBe(true)
  })

  test('truncates to the band width', async ($, on) => {
    const world = worldOf(on, {
      files: { ...CONFIG_ON, [`${ROOT}/state.d/c.json`]: rowOf({ project: 'a-very-long-project-name-indeed' }) },
    })
    on('ui.render', { component: 'AbovePrompt' }, () => EMPTY as never)
    await $.session.start(SESSION)
    await world.clock.advance(2000)
    const line = textOf(await $.ui.render(bandAt(40) as never)).replace(/Jump$/, '')
    expect(line.length).toBeLessThanOrEqual(28)
    expect(line.endsWith('…')).toBe(true)
  })

  test('yields to a survey', async ($, on) => {
    const world = worldOf(on, { files: { ...CONFIG_ON, [`${ROOT}/state.d/c.json`]: rowOf({}) } })
    on('ui.render', { component: 'AbovePrompt' }, () => BENEATH as never)
    await $.session.start(SESSION)
    await world.clock.advance(2000)
    expect(await $.ui.render(bandAt(100, true) as never)).toEqual(BENEATH)
  })

  test('off macOS there is no Jump button', async ($, on) => {
    const world = worldOf(on, { mac: false, files: { ...CONFIG_ON, [`${ROOT}/state.d/c.json`]: rowOf({}) } })
    on('ui.render', { component: 'AbovePrompt' }, () => EMPTY as never)
    await $.session.start(SESSION)
    await world.clock.advance(2000)
    expect(textOf(await $.ui.render(bandAt() as never))).toBe('◆ Codex needs your approval · api')
  })

  test('asks for a redraw only when the waiting set changes', async ($, on) => {
    const world = worldOf(on, { files: { ...CONFIG_ON } })
    await $.session.start(SESSION)
    await world.clock.advance(6000)
    expect(world.invalidations, 'nobody, and still nobody').toBe(0)

    world.files.set(`${ROOT}/state.d/c.json`, rowOf({}))
    await world.clock.advance(2000)
    expect(world.invalidations).toBe(1)
    await world.clock.advance(6000)
    expect(world.invalidations, 'the same one still waiting').toBe(1)

    world.files.set(`${ROOT}/state.d/c.json`, rowOf({ state: 'tool' }))
    await world.clock.advance(2000)
    expect(world.invalidations, 'answered: the line goes').toBe(2)
  })

  test('switching it on in config.json takes effect within 30 s, and off again', async ($, on) => {
    const world = worldOf(on, { files: { [`${ROOT}/state.d/c.json`]: rowOf({}) } })
    on('ui.render', { component: 'AbovePrompt' }, () => BENEATH as never)
    await $.session.start(SESSION)
    expect(await $.ui.render(bandAt() as never)).toEqual(BENEATH)

    world.files.set(`${ROOT}/mods/config.json`, '{"band":true}')
    await world.clock.advance(30000)
    expect(textOf(await $.ui.render(bandAt() as never))).toContain('Codex needs your approval')

    world.files.set(`${ROOT}/mods/config.json`, '{"band":false}')
    await world.clock.advance(30000)
    expect(await $.ui.render(bandAt() as never)).toEqual(BENEATH)
  })
})
