export type WorkerState = 'needs you' | 'running' | 'failed' | 'done'

export type WorkerRow = {
  /** The Worker id, e.g. `w12`. */
  id: string
  profile: string
  title: string
  state: WorkerState
  /** Seconds since the Worker's last message (or start, before any). */
  quietSeconds: number
  /** Worktree folder name, or "in place". */
  place: string
}

declare module 'claude-code' {
  interface PluginState {
    hub: {
      workers: WorkerRow[]
      showTools: boolean
      turnTools: number
    }
  }
}
