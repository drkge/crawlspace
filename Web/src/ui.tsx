import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from 'react'

/** A modal sheet. Escape and clicking outside close it unless `busy`. */
export function Dialog(props: {
  title: ReactNode
  onClose: () => void
  children: ReactNode
  footer?: ReactNode
  size?: 'narrow' | 'wide'
  busy?: boolean
}) {
  const { onClose, busy } = props
  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && !busy) onClose()
    }
    window.addEventListener('keydown', key)
    return () => window.removeEventListener('keydown', key)
  }, [onClose, busy])
  return (
    <div className="backdrop" onMouseDown={(event) => event.target === event.currentTarget && !busy && onClose()}>
      <div className={`dialog ${props.size ?? ''}`} role="dialog" aria-modal="true">
        <header>
          <h2>{props.title}</h2>
        </header>
        <div className="content">{props.children}</div>
        {props.footer && <footer>{props.footer}</footer>}
      </div>
    </div>
  )
}

/** Asks before doing something that can't easily be undone. */
export function Confirm(props: {
  title: string
  message: ReactNode
  action: string
  danger?: boolean
  onConfirm: () => void
  onCancel: () => void
}) {
  return (
    <Dialog
      title={props.title}
      onClose={props.onCancel}
      size="narrow"
      footer={
        <>
          <button onClick={props.onCancel}>Cancel</button>
          <button className={props.danger ? 'primary danger-fill' : 'primary'} onClick={props.onConfirm} autoFocus>
            {props.action}
          </button>
        </>
      }
    >
      <div>{props.message}</div>
    </Dialog>
  )
}

/** A button that opens a small menu of actions below it. */
export function Menu(props: { label: ReactNode; children: ReactNode; disabled?: boolean; className?: string }) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!open) return
    const close = (event: MouseEvent) => {
      if (!ref.current?.contains(event.target as Node)) setOpen(false)
    }
    const key = (event: KeyboardEvent) => event.key === 'Escape' && setOpen(false)
    window.addEventListener('mousedown', close)
    window.addEventListener('keydown', key)
    return () => {
      window.removeEventListener('mousedown', close)
      window.removeEventListener('keydown', key)
    }
  }, [open])
  return (
    <div className="menu" ref={ref}>
      <button className={props.className} disabled={props.disabled} onClick={() => setOpen(!open)} aria-haspopup="menu">
        {props.label} <span aria-hidden>▾</span>
      </button>
      {open && (
        <div className="menu-panel" role="menu" onClick={() => setOpen(false)}>
          {props.children}
        </div>
      )}
    </div>
  )
}

/** A menu at the pointer, for right-clicks. */
export function ContextMenu(props: { x: number; y: number; onClose: () => void; children: ReactNode }) {
  const { onClose } = props
  useEffect(() => {
    const close = () => onClose()
    window.addEventListener('mousedown', close)
    window.addEventListener('blur', close)
    window.addEventListener('keydown', close)
    return () => {
      window.removeEventListener('mousedown', close)
      window.removeEventListener('blur', close)
      window.removeEventListener('keydown', close)
    }
  }, [onClose])
  return (
    <div
      className="menu-panel context-menu"
      style={{ left: Math.min(props.x, window.innerWidth - 240), top: Math.min(props.y, window.innerHeight - 120) }}
      onMouseDown={(event) => event.stopPropagation()}
      onClick={onClose}
    >
      {props.children}
    </div>
  )
}

type Toast = { message: string; error: boolean; id: number }
const ToastContext = createContext<(message: string, error?: boolean) => void>(() => {})

/** Short messages at the bottom of the window: "Copied", or what went wrong. */
export function ToastProvider({ children }: { children: ReactNode }) {
  const [toast, setToast] = useState<Toast | null>(null)
  const show = useCallback((message: string, error = false) => {
    const id = Date.now()
    setToast({ message, error, id })
    setTimeout(() => setToast((current) => (current?.id === id ? null : current)), error ? 7000 : 3000)
  }, [])
  return (
    <ToastContext.Provider value={show}>
      {children}
      {toast && (
        <div className={`toast ${toast.error ? 'error' : ''}`} role="status" onClick={() => setToast(null)}>
          {toast.message}
        </div>
      )}
    </ToastContext.Provider>
  )
}

export const useToast = () => useContext(ToastContext)

/** Turns any thrown thing into a message worth showing. */
export const messageOf = (error: unknown) => (error instanceof Error ? error.message : String(error))

/** Wraps an action so a failure shows as a toast rather than vanishing. */
export function useAction() {
  const toast = useToast()
  return useCallback(
    async <T,>(work: () => Promise<T>, success?: string): Promise<T | undefined> => {
      try {
        const result = await work()
        if (success) toast(success)
        return result
      } catch (error) {
        toast(messageOf(error), true)
        return undefined
      }
    },
    [toast],
  )
}

export function Severity({ severity }: { severity: string }) {
  return <span className={`dot ${severity}`} aria-label={severity} />
}

export function ScoreGauge({ score }: { score?: number }) {
  if (score === undefined || score === null) return <span className="gauge">–</span>
  const band = score >= 90 ? 'good' : score >= 50 ? 'average' : 'poor'
  return <span className={`gauge ${band}`}>{Math.round(score)}</span>
}
