import { describe, expect, test } from 'claude-code/testing'

import { SESSION, START, sidecarOf, worldOf } from './world'

const S0 = Math.floor(START / 1000)

const check = (tool: string, input: Record<string, unknown>, id: string) =>
  ({ tool, input, tool_use_id: id }) as never

const end = (id = 'sess-1') =>
  ({ reason: 'other', sessionId: id, resume: { id } }) as never

const turn = (agentId?: string) =>
  ({ answer: '', durationMs: 1, isAborted: false, turnId: 't', reason: 'answer', ...(agentId ? { agentId } : {}) }) as never

const spawn = (background: boolean) =>
  ({
    tool_use_id: 'toolu_agent', prompt: 'p', description: 'd', subagentType: 'general-purpose',
    provider: { plugin: 'engine', tier: 'core' }, parentModel: 'haiku', background, fork: false,
  }) as never

describe('every hook hands back what was beneath it', () => {
  for (const verdict of [
    { decision: 'allow', rule: 'Bash(git status:*)' },
    { decision: 'allow' },
    { decision: 'ask', reason: 'touch needs approval' },
    { decision: 'deny', rule: 'Bash(rm:*)', reason: 'Permission to use Bash with command rm x has been denied.' },
    { decision: 'allow', hook: 'PreToolUse' },
    { decision: 'deny', reason: 'a later mod said no' },
  ] as const) {
    test(`tool.check ${JSON.stringify(verdict)}`, async ($, on) => {
      worldOf(on)
      on('tool.check', () => ({ ...verdict }) as never)
      await $.session.start(SESSION)
      expect(await $.tool.check(check('Bash', { command: 'x' }, 'toolu_1'))).toEqual(verdict)
    })
  }

  test('tool.call: a later hook refusing is returned as it refused', async ($, on) => {
    worldOf(on)
    on('tool.call', () => ({ deny: 'held by another mod' }))
    await $.session.start(SESSION)
    expect(await $.tool.call({ tool: 'Bash', command: 'rm -rf build', tool_use_id: 'toolu_9' } as never))
      .toEqual({ deny: 'held by another mod' })
  })

  test('tool.call: a result is returned as it came', async ($, on) => {
    worldOf(on)
    on('tool.call', () => ({ result: 'ok', text: 'ok' }) as never)
    await $.session.start(SESSION)
    expect(await $.tool.call({ tool: 'Bash', command: 'ls', tool_use_id: 'toolu_8' } as never))
      .toMatchObject({ result: 'ok' })
  })

  test('agent.spawn and session.start hand back what beneath answered', async ($, on) => {
    worldOf(on)
    on('agent.spawn', () => ({ model: 'haiku', agentId: 'a1' }))
    expect(await $.session.start(SESSION)).toEqual({ cwd: SESSION.cwd })
    expect(await $.agent.spawn(spawn(true))).toEqual({ model: 'haiku', agentId: 'a1' })
  })
})

describe('what a decision row says', () => {
  test('a rule allow, written a second later under the session id', async ($, on) => {
    const world = worldOf(on)
    on('tool.check', () => ({ decision: 'allow', rule: 'Bash(git status:*)' }))
    await $.session.start(SESSION)
    await world.clock.advance(1000)
    const before = world.writes.length
    await $.tool.check(check('Bash', { command: 'git status --short', description: 'Status', timeout: 5 }, 'toolu_1'))
    expect(world.writes.length, 'debounced: nothing yet').toBe(before)
    await world.clock.advance(1000)
    const file = sidecarOf(world)
    expect(file).toMatchObject({
      v: 1, agent: 'claude', session_id: 'sess-1', mod: '1.37.0', cwd: '/work/api', ended: false,
      context: { window: 200000 }, rate_limits: [], subagents: 0,
    })
    expect(file.decisions).toEqual([{
      id: 'toolu_1', ts: S0 + 1, tool: 'Bash',
      input: { command: 'git status --short', description: 'Status' },
      verdict: 'allow', by: 'rule', rule: 'Bash(git status:*)', reason: '',
    }])
  })

  test('attribution: rule, mode, hook by name, hook by reason', async ($, on) => {
    const world = worldOf(on)
    const answers: Record<string, unknown> = {
      t_rule: { decision: 'deny', rule: 'Bash(rm:*)', reason: 'Permission to use Bash with command rm x has been denied.' },
      t_mode: { decision: 'allow' },
      t_hook: { decision: 'allow', hook: 'PreToolUse' },
      t_mod: { decision: 'deny', reason: 'sec policy: no curl here' },
    }
    on('tool.check', ($, e) => answers[e.tool_use_id ?? ''] as never)
    await $.session.start(SESSION)
    for (const id of Object.keys(answers)) await $.tool.check(check('Bash', { command: id }, id))
    await world.clock.advance(1000)
    const rows = sidecarOf(world).decisions.map((d: any) => [d.id, d.verdict, d.by, d.rule, d.reason])
    expect(rows).toEqual([
      ['t_rule', 'deny', 'rule', 'Bash(rm:*)', 'Permission to use Bash with command rm x has been denied.'],
      ['t_mode', 'allow', 'mode', '', ''],
      ['t_hook', 'allow', 'hook', '', ''],
      ['t_mod', 'deny', 'hook', '', 'sec policy: no curl here'],
    ])
  })

  test('an ask is never written, nor the deny that the prompt then returns', async ($, on) => {
    const world = worldOf(on)
    on('tool.check', () => ({ decision: 'ask', reason: 'needs approval' }))
    on('tool.call', () => ({ deny: 'the user said no' }))
    await $.session.start(SESSION)
    await $.tool.check(check('Bash', { command: 'touch x' }, 'toolu_ask'))
    await $.tool.call({ tool: 'Bash', command: 'touch x', tool_use_id: 'toolu_ask' } as never)
    await world.clock.advance(1000)
    expect(sidecarOf(world).decisions).toEqual([])
  })

  test('read-only tools are left out, in tool.check and tool.call alike', async ($, on) => {
    const world = worldOf(on)
    on('tool.check', () => ({ decision: 'allow' }))
    on('tool.call', () => ({ deny: 'nope' }))
    await $.session.start(SESSION)
    const quiet = ['Read', 'Glob', 'Grep', 'LS', 'TodoWrite', 'NotebookRead', 'WebSearch', 'ToolSearch', 'BashOutput']
    for (const [i, tool] of quiet.entries()) {
      await $.tool.check(check(tool, { file_path: '/x' }, `r${i}`))
      await $.tool.call({ tool, file_path: '/x', tool_use_id: `c${i}` } as never)
    }
    await $.tool.check(check('Edit', { file_path: '/x' }, 'e1'))
    await world.clock.advance(1000)
    expect(sidecarOf(world).decisions.map((d: any) => d.tool)).toEqual(['Edit'])
  })

  test('a query ($.tool.check with no call id) is not a decision', async ($, on) => {
    const world = worldOf(on)
    on('tool.check', () => ({ decision: 'allow', rule: 'Bash(ls:*)' }))
    await $.session.start(SESSION)
    await $.tool.check({ tool: 'Bash', input: { command: 'ls' } } as never)
    await world.clock.advance(1000)
    expect(sidecarOf(world).decisions).toEqual([])
  })

  test('input keeps four fields, each capped at 2 KB of UTF-8; reason at 300 characters', async ($, on) => {
    const world = worldOf(on)
    on('tool.check', () => ({ decision: 'deny', reason: 'r'.repeat(500) }))
    await $.session.start(SESSION)
    await $.tool.check(check('WebFetch', {
      command: 'a'.repeat(5000),
      file_path: 'é'.repeat(2000),           // 2 bytes each
      url: '😀'.repeat(1000),                 // 4 bytes each, a surrogate pair
      description: 'short',
      content: 'never kept',
      prompt: 'never kept',
    }, 'toolu_big'))
    await world.clock.advance(1000)
    const row = sidecarOf(world).decisions[0]
    expect(Object.keys(row.input).sort()).toEqual(['command', 'description', 'file_path', 'url'])
    expect(row.input.command).toHaveLength(2048)
    expect(row.input.file_path).toBe('é'.repeat(1024))
    expect(row.input.url).toBe('😀'.repeat(512))
    expect(row.reason).toHaveLength(300)
  })

  test('the ring keeps the newest 200', async ($, on) => {
    const world = worldOf(on)
    on('tool.check', () => ({ decision: 'allow' }))
    await $.session.start(SESSION)
    for (let i = 0; i < 205; i++) await $.tool.check(check('Bash', { command: `c${i}` }, `id${i}`))
    await world.clock.advance(1000)
    const ids = sidecarOf(world).decisions.map((d: any) => d.id)
    expect(ids).toHaveLength(200)
    expect(ids[0]).toBe('id5')
    expect(ids[199]).toBe('id204')
  })

  test('a deny from a hook beneath tool.call is written as by: hook', async ($, on) => {
    const world = worldOf(on)
    on('tool.call', () => ({ deny: `Blast Radius held this command: ${'x'.repeat(400)}` }))
    await $.session.start(SESSION)
    await $.tool.call({ tool: 'Bash', command: 'rm -rf build', description: 'Clean', tool_use_id: 'toolu_held' } as never)
    await world.clock.advance(1000)
    const [row] = sidecarOf(world).decisions
    expect(row).toMatchObject({
      id: 'toolu_held', tool: 'Bash', input: { command: 'rm -rf build', description: 'Clean' },
      verdict: 'deny', by: 'hook', rule: '',
    })
    expect(row.reason.startsWith('Blast Radius held this command')).toBe(true)
    expect(row.reason).toHaveLength(300)
  })

  test('a call already decided in tool.check is not written twice', async ($, on) => {
    const world = worldOf(on)
    on('tool.check', () => ({ decision: 'deny', rule: 'Bash(rm:*)', reason: 'denied' }))
    on('tool.call', () => ({ deny: 'denied' }))
    await $.session.start(SESSION)
    await $.tool.check(check('Bash', { command: 'rm x' }, 'toolu_r'))
    await $.tool.call({ tool: 'Bash', command: 'rm x', tool_use_id: 'toolu_r' } as never)
    await world.clock.advance(1000)
    expect(sidecarOf(world).decisions.map((d: any) => d.by)).toEqual(['rule'])
  })
})

describe('what Claude Code measures', () => {
  test('usage lands snake_case, and a missing figure is left out, never zeroed', async ($, on) => {
    const world = worldOf(on)
    await $.session.start(SESSION)
    await world.clock.advance(1000)
    expect(sidecarOf(world).context).toEqual({ window: 200000 })
    expect(sidecarOf(world).rate_limits).toEqual([])

    await $.session.measure({
      context: { tokens: 31310, window: 200000, percent: 16 },
      rateLimits: [
        { kind: 'five_hour', percentUsed: 62, resetsAt: '2026-10-04T23:00:00.000Z' },
        { kind: 'seven_day', percentUsed: 28 },
        { kind: 'weird' },
      ],
      cost: { usd: 0.01 },
      changed: ['context', 'rateLimits'],
    } as never)
    await world.clock.advance(1000)
    const file = sidecarOf(world)
    expect(file.context).toEqual({ percent: 16, tokens: 31310, window: 200000 })
    expect(file.rate_limits).toEqual([
      { kind: 'five_hour', percent_used: 62, resets_at: '2026-10-04T23:00:00.000Z' },
      { kind: 'seven_day', percent_used: 28 },
    ])
    expect(JSON.stringify(file)).not.toContain('percentUsed')
  })

  test('a measure without tokens keeps the window alone', async ($, on) => {
    const world = worldOf(on, { usage: { context: { window: 0 }, rateLimits: [] } })
    await $.session.start(SESSION)
    await $.session.measure({ context: { window: 1000000 }, rateLimits: [], changed: ['context'] } as never)
    await world.clock.advance(1000)
    expect(sidecarOf(world).context).toEqual({ window: 1000000 })
  })

  test('subagents: counted from spawn to their turn.complete, never below zero', async ($, on) => {
    const world = worldOf(on)
    let next = 0
    on('agent.spawn', () => ({ model: 'haiku', agentId: `a${++next}` }))
    await $.session.start(SESSION)

    await $.agent.spawn(spawn(true))
    await $.agent.spawn(spawn(false))
    await world.clock.advance(1000)
    expect(sidecarOf(world).subagents).toBe(2)

    await $.turn.complete(turn('a1'))
    await $.turn.complete(turn('a1'))            // twice: no double count
    await $.turn.complete(turn('nobody'))        // unknown: no effect
    await world.clock.advance(1000)
    expect(sidecarOf(world).subagents).toBe(1)

    await $.turn.complete(turn())                // main turn ends: the foreground one cannot outlive it
    await world.clock.advance(1000)
    expect(sidecarOf(world).subagents).toBe(0)
  })

  test('a subagent that finishes before its spawn resolves is never counted', async ($, on) => {
    const world = worldOf(on)
    on('agent.spawn', () => ({ model: 'haiku', agentId: 'quick' }))
    await $.session.start(SESSION)
    // Its turn.complete arrives first: the spawn's result is read only after it.
    await $.turn.complete(turn('quick'))
    await $.agent.spawn(spawn(false))
    await world.clock.advance(1000)
    expect(sidecarOf(world).subagents).toBe(0)
  })
})

describe('when the file is written', () => {
  test('changes inside a second share one write; the last change always lands', async ($, on) => {
    const world = worldOf(on)
    on('tool.check', () => ({ decision: 'allow' }))
    await $.session.start(SESSION)
    await world.clock.advance(1000)
    const before = world.writes.length
    for (let i = 0; i < 5; i++) {
      await $.tool.check(check('Bash', { command: `c${i}` }, `id${i}`))
      await world.clock.advance(100)
    }
    await world.clock.advance(1000)
    expect(world.writes.length - before).toBe(1)
    expect(sidecarOf(world).decisions).toHaveLength(5)

    await $.tool.check(check('Bash', { command: 'late' }, 'late'))
    await world.clock.advance(1000)
    expect(world.writes.length - before).toBe(2)
    expect(sidecarOf(world).decisions.at(-1).id).toBe('late')
  })

  test('session.end writes ended: true at once, and nothing after it', async ($, on) => {
    const world = worldOf(on)
    on('tool.check', () => ({ decision: 'allow' }))
    await $.session.start(SESSION)
    await $.tool.check(check('Bash', { command: 'make' }, 'toolu_1'))
    await $.session.end(end())
    const file = sidecarOf(world)
    expect(file.ended).toBe(true)
    expect(file.decisions.map((d: any) => d.id)).toEqual(['toolu_1'])
    const after = world.writes.length
    await world.clock.advance(5000)
    expect(world.writes.length, 'the pending debounce was cancelled').toBe(after)
  })

  test('an event straggling in after the end never un-ends the file', async ($, on) => {
    const world = worldOf(on)
    on('tool.check', () => ({ decision: 'allow' }))
    await $.session.start(SESSION)
    await $.tool.check(check('Bash', { command: 'make' }, 'toolu_1'))
    await $.session.end(end())
    const final = world.files.get('/Users/me/.agentbar/mods.d/sess-1.json')
    await $.tool.check(check('Bash', { command: 'late' }, 'toolu_late'))
    await $.session.measure({ context: { tokens: 1, window: 2, percent: 50 }, rateLimits: [], changed: ['context'] } as never)
    await world.clock.advance(3000)
    expect(world.files.get('/Users/me/.agentbar/mods.d/sess-1.json')).toBe(final)
  })

  test('after /clear the next session writes its own file', async ($, on) => {
    const world = worldOf(on)
    on('tool.check', () => ({ decision: 'allow' }))
    await $.session.start(SESSION)
    await $.tool.check(check('Bash', { command: 'one' }, 'toolu_1'))
    await $.session.end(end('sess-1'))
    world.sessionId.value = 'sess-2'
    await $.tool.check(check('Bash', { command: 'two' }, 'toolu_2'))
    await world.clock.advance(1000)
    expect(sidecarOf(world, undefined, 'sess-1').ended).toBe(true)
    const second = sidecarOf(world, undefined, 'sess-2')
    expect(second.ended).toBe(false)
    expect(second.decisions.map((d: any) => d.id)).toEqual(['toolu_2'])
  })

  for (const [home, root] of [
    ['/tmp/ab-test///', '/tmp/ab-test'],
    ['/tmp/ab-test', '/tmp/ab-test'],
    ['relative/dir', '/Users/me/.agentbar'],
    ['', '/Users/me/.agentbar'],
  ] as const) {
    test(`AGENTBAR_HOME=${JSON.stringify(home)} writes under ${root}`, async ($, on) => {
      const world = worldOf(on, { env: { HOME: '/Users/me', AGENTBAR_HOME: home } })
      await $.session.start(SESSION)
      await world.clock.advance(1000)
      expect(world.writes.map(w => w.path)).toEqual([`${root}/mods.d/sess-1.json`])
    })
  }

  test('a filesystem that refuses every write breaks nothing', async ($, on) => {
    const world = worldOf(on)
    world.failWrites.value = true
    on('tool.check', () => ({ decision: 'allow', rule: 'Bash(make:*)' }))
    on('tool.call', () => ({ deny: 'held' }))
    expect(await $.session.start(SESSION)).toEqual({ cwd: SESSION.cwd })
    expect(await $.tool.check(check('Bash', { command: 'make' }, 'toolu_1'))).toEqual({ decision: 'allow', rule: 'Bash(make:*)' })
    expect(await $.tool.call({ tool: 'Bash', command: 'rm', tool_use_id: 'toolu_2' } as never)).toEqual({ deny: 'held' })
    await world.clock.advance(3000)
    expect(await $.session.end(end())).toEqual({ sessionId: 'sess-1' })
    expect(world.writes).toEqual([])
  })

  test('a session that cannot say who it is answers everything as if the mod were absent', async ($, on) => {
    const world = worldOf(on, { sessionId: '' })
    on('tool.check', () => ({ decision: 'allow' }))
    expect(await $.session.start(SESSION)).toEqual({ cwd: SESSION.cwd })
    expect(await $.tool.check(check('Bash', { command: 'x' }, 't'))).toEqual({ decision: 'allow' })
    await world.clock.advance(2000)
    expect(world.writes).toEqual([])
  })
})
