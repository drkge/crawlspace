import { useEffect, useRef, useState } from 'react'

/**
 * Listens to a server-sent event stream. The browser reconnects on its own when the server
 * restarts (an update, say); `onReconnect` lets the page refetch what it may have missed.
 */
export function useEvents(
  path: string | null,
  handlers: Record<string, (data: any) => void>,
  onReconnect?: () => void,
): boolean {
  const [connected, setConnected] = useState(true)
  const latest = useRef(handlers)
  latest.current = handlers
  const reconnect = useRef(onReconnect)
  reconnect.current = onReconnect

  useEffect(() => {
    if (!path) return
    const source = new EventSource(path)
    let dropped = false
    source.onopen = () => {
      setConnected(true)
      if (dropped) reconnect.current?.()
      dropped = false
    }
    source.onerror = () => {
      dropped = true
      setConnected(false)
    }
    const names = Object.keys(latest.current)
    const listeners = names.map((name) => {
      const listener = (event: MessageEvent) => {
        try {
          latest.current[name]?.(JSON.parse(event.data))
        } catch {
          // A malformed event isn't worth breaking the page over.
        }
      }
      source.addEventListener(name, listener)
      return [name, listener] as const
    })
    return () => {
      for (const [name, listener] of listeners) source.removeEventListener(name, listener)
      source.close()
    }
    // The handler names are fixed per caller; only the path changes the stream.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [path])

  return connected
}

/** A value that only settles after `delay` ms without change, for search boxes. */
export function useDebounced<T>(value: T, delay: number): T {
  const [settled, setSettled] = useState(value)
  useEffect(() => {
    const timer = setTimeout(() => setSettled(value), delay)
    return () => clearTimeout(timer)
  }, [value, delay])
  return settled
}

/** Remembers a per-browser preference, such as the inspector's width. */
export function useStoredState<T>(key: string, initial: T): [T, (value: T) => void] {
  const [value, setValue] = useState<T>(() => {
    try {
      const stored = localStorage.getItem(`crawlspace.${key}`)
      return stored === null ? initial : (JSON.parse(stored) as T)
    } catch {
      return initial
    }
  })
  const set = (next: T) => {
    setValue(next)
    try {
      localStorage.setItem(`crawlspace.${key}`, JSON.stringify(next))
    } catch {
      // Private windows can refuse storage; the preference just won't stick.
    }
  }
  return [value, set]
}

export const number = (value: number) => value.toLocaleString()

export function duration(seconds: number): string {
  const s = Math.floor(seconds)
  const hours = Math.floor(s / 3600)
  const minutes = Math.floor((s % 3600) / 60)
  const rest = s % 60
  return [hours, minutes, rest].map((part) => String(part).padStart(2, '0')).join(':')
}

export function relativeDate(iso: string): string {
  const date = new Date(iso)
  const days = Math.floor((Date.now() - date.getTime()) / 86_400_000)
  const time = date.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })
  if (days === 0 && new Date().getDate() === date.getDate()) return `Today, ${time}`
  if (days <= 1) return `Yesterday, ${time}`
  return date.toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' })
}

export const linkTypes = ['Hyperlink', 'Image', 'CSS', 'JavaScript', 'Canonical', 'Hreflang', 'Redirect', 'Iframe', 'Meta refresh']
export const linkPositions = ['Unknown', 'Navigation', 'Header', 'Footer', 'Sidebar', 'Content']
export const isNofollow = (flags: number) => (flags & 1) !== 0

export function plural(count: number, word: string, many = `${word}s`): string {
  return `${number(count)} ${count === 1 ? word : many}`
}
