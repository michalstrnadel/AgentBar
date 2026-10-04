import type { On } from 'claude-code'
import { mock } from 'claude-code/testing'

/**
 * Everything beneath the mod, in memory: a filesystem, the session's identity
 * and usage, a mocked clock, and a record of what the mod asked the host to do.
 * Nothing here touches the real disk: every `$.fs` call is answered from `files`.
 */
export type World = {
  files: Map<string, string>
  writes: { path: string; text: string }[]
  runs: (readonly string[])[]
  invalidations: number
  clock: ReturnType<typeof mock.clock>
  sessionId: { value: string }
  failWrites: { value: boolean }
}

export type WorldOptions = {
  env?: Record<string, string>
  files?: Record<string, string>
  sessionId?: string
  mac?: boolean
  usage?: unknown
}

export const START = 1_791_146_000_000

export const SESSION = { cwd: '/work/api', surface: 'terminal', isInteractive: true } as const

export function worldOf(on: On, options: WorldOptions = {}): World {
  const world: World = {
    files: new Map(Object.entries(options.files ?? {})),
    writes: [],
    runs: [],
    invalidations: 0,
    clock: mock.clock(on, { now: START }),
    sessionId: { value: options.sessionId ?? 'sess-1' },
    failWrites: { value: false },
  }

  mock.env(on, options.env ?? { HOME: '/Users/me' })

  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.end', ($, e) => ({ sessionId: e.sessionId }))
  on('session.measure', ($, e) => ({ changed: e.changed }))
  on('turn.complete', ($, e) => ({ text: e.answer }))
  on('session.id', () =>
    world.sessionId.value ? { value: world.sessionId.value } : { deny: 'no session yet' })
  on('session.cwd', () => ({ value: '/work/api' }))
  on('session.usage', () => ({
    value: (options.usage ?? { context: { window: 200000 }, rateLimits: [] }) as never,
  }))

  on('fs.write', ($, e) => {
    if (world.failWrites.value) return { deny: 'disk full' }
    world.files.set(e.path, e.text)
    world.writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('fs.read', ($, e) => {
    const text = world.files.get(e.path)
    return text === undefined ? { deny: `ENOENT ${e.path}` } : { value: text }
  })
  on('fs.list', ($, e) => {
    const prefix = `${e.path}/`
    const names = [...world.files.keys()]
      .filter(p => p.startsWith(prefix) && !p.slice(prefix.length).includes('/'))
      .map(p => p.slice(prefix.length))
    if (names.length === 0) return { deny: `ENOENT ${e.path}` }
    return { value: names.map(name => ({ name, kind: 'file' as const, size: 1, isLink: false })) }
  })
  on('fs.exists', () => ({ value: options.mac ?? true }))
  on('ui.invalidate', () => {
    world.invalidations += 1
    return { value: undefined }
  })
  on('process.run', ($, e) => {
    world.runs.push(e.argv)
    return { value: { exitCode: 0, stdout: '', stderr: '' } }
  })

  return world
}

/** The sidecar the mod last wrote for a session, parsed. */
export function sidecarOf(world: World, root = '/Users/me/.agentbar', id = world.sessionId.value): any {
  const text = world.files.get(`${root}/mods.d/${id}.json`)
  return text === undefined ? undefined : JSON.parse(text)
}

/** A state.d row, as the hooks write one. */
export function rowOf(fields: Record<string, unknown>): string {
  return JSON.stringify({
    agent: 'codex', state: 'permission', label: 'Approve command', project: 'api',
    cwd: '/work/api', sessionId: 'x', entrypoint: 'cli', pid: 0, started: true,
    ts: Math.floor(START / 1000), ...fields,
  })
}

/** The AbovePrompt band on a terminal `columns` wide. */
export function bandAt(columns = 100, hasSurvey = false) {
  return {
    component: 'AbovePrompt' as const,
    surface: 'terminal' as const,
    requestId: 'above-prompt',
    viewport: { columns, rows: 40, isFullscreen: true },
    props: {
      hasSurvey,
      isWorking: false,
      maxRows: 6,
      bodyColumns: columns,
      scroll: { offset: 0, bodyRows: 5 },
      view: {},
    },
  }
}

/** A drawn tree's text: its strings and its labels, in order. */
export function textOf(tree: unknown): string {
  if (typeof tree === 'string' || typeof tree === 'number') return String(tree)
  if (Array.isArray(tree)) return tree.map(textOf).join('')
  if (typeof tree !== 'object' || !tree) return ''
  const props: any = Reflect.get(tree, 'props') ?? {}
  const label = typeof props.label === 'string' ? props.label : ''
  return `${label}${textOf(Reflect.get(tree, 'children') ?? props.children ?? [])}`
}
