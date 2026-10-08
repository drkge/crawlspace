import { useEffect, useState, type ReactNode } from 'react'
import { api, type About, type Settings } from '../api'
import { relativeDate } from '../hooks'
import { Confirm, Dialog, useAction } from '../ui'

type TokenKind = 'clickup'

interface TokenEntry {
  kind: TokenKind
  service: string
  purpose: string
  /** Masked by the server (pk_…X4qZ); absent when none has been added. */
  masked?: string
  addedAt?: string
}

interface SettingsResponse {
  settings: Settings
  tokens: TokenEntry[]
}

/** What the service said when asked whether a token works. */
interface TokenCheck {
  status: 'working' | 'rejected' | 'unknown'
  detail: string
  checkedAt: string
}

/** Tokens, updates and where things live. */
export default function SettingsPage({ about, onChange }: { about: About | null; onChange: () => void }) {
  const run = useAction()
  const [state, setState] = useState<SettingsResponse | null>(null)

  const reload = () => api.get<SettingsResponse>('/api/settings').then(setState)
  useEffect(() => {
    reload()
  }, [])

  const update = about?.update
  return (
    <div className="page">
      <div className="page-inner stack" style={{ maxWidth: 880 }}>
        <h1>Settings</h1>

        <section className="card stack">
          <h2>Updates</h2>
          <p className="hint">
            Crawlspace updates itself from GitHub whenever there's a new version, installing it once no crawl is running.
          </p>
          <div className="row">
            <span>
              Version {about?.version ?? '…'}
              {update?.latest && update.latest !== about?.version ? ` · ${update.latest} available` : ''}
            </span>
            <span className="spacer" />
            <button className="small" disabled={update?.phase === 'disabled'} onClick={() => run(() => api.post('/api/update/check')).then(onChange)}>
              Check Now
            </button>
          </div>
          {update?.message && <p className="hint">{update.message}</p>}
          {update?.lastChecked && <p className="hint">Last checked {relativeDate(update.lastChecked)}.</p>}
          {state && (
            <label className="check">
              <input
                type="checkbox"
                checked={state.settings.automaticUpdates}
                onChange={(event) =>
                  run(async () => {
                    const next = await api.put<SettingsResponse>('/api/settings', { ...state.settings, automaticUpdates: event.target.checked })
                    setState(next)
                  })
                }
              />
              Check for updates automatically
            </label>
          )}
        </section>

        {state && (
          <TokensCard
            tokens={state.tokens}
            onChange={setState}
          />
        )}

        <section className="card stack">
          <h2>Speed reports</h2>
          <dl className="kv">
            <dt>Lighthouse</dt>
            <dd>{about?.lighthouse ?? '…'}</dd>
            {about?.lighthouseRuntime && (
              <>
                <dt>Runtime</dt>
                <dd>{about.lighthouseRuntime}</dd>
              </>
            )}
          </dl>
          <p className="hint">
            Lighthouse runs on this Mac with its own copy of Node, which arrives with updates, and the Chrome you already have (or a
            headless Chrome it downloads if there isn't one).
          </p>
        </section>

        <section className="card stack">
          <h2>Storage</h2>
          <dl className="kv">
            <dt>Crawls</dt>
            <dd className="mono">{about?.crawlsFolder}</dd>
            {about?.freeDiskGigabytes !== undefined && (
              <>
                <dt>Free space</dt>
                <dd>{about.freeDiskGigabytes.toFixed(0)} GB</dd>
              </>
            )}
          </dl>
        </section>
      </div>
    </div>
  )
}

/** What stops when a token is deleted. */
const withoutToken: Record<TokenKind, string> = {
  clickup: 'Exports to ClickUp stop working until you add a ClickUp token again.',
}

/** Where each token comes from, and how to get one. */
const tokenHelp: Record<TokenKind, ReactNode> = {
  clickup: (
    <>
      In ClickUp, open{' '}
      <a href="https://app.clickup.com/settings/apps" target="_blank" rel="noopener noreferrer">
        Settings ▸ Apps ↗
      </a>{' '}
      and copy your personal API token (it starts <code>pk_</code>).
    </>
  ),
}

/**
 * The API tokens the app holds, laid out like ClickUp's own token page: Add token at the top, and a
 * table of each service's token, masked, with when it was added. One token per service, so adding
 * one where there's already a token replaces it.
 */
function TokensCard(props: { tokens: TokenEntry[]; onChange: (next: SettingsResponse) => void }) {
  const run = useAction()
  const [adding, setAdding] = useState<TokenKind | null>(null)
  const [removing, setRemoving] = useState<TokenEntry | null>(null)
  const [checks, setChecks] = useState<Partial<Record<TokenKind, TokenCheck | 'checking'>>>({})

  const check = async (kind: TokenKind) => {
    setChecks((current) => ({ ...current, [kind]: 'checking' }))
    const result = await api
      .post<TokenCheck>(`/api/tokens/${kind}/check`)
      .catch((error): TokenCheck => ({ status: 'unknown', detail: String(error.message ?? error), checkedAt: new Date().toISOString() }))
    setChecks((current) => ({ ...current, [kind]: result }))
  }

  // Each saved token is checked when Settings opens, so one that's stopped working shows up here
  // rather than as a failed update or export later.
  const savedKey = props.tokens.map((entry) => `${entry.kind}:${entry.masked ?? ''}`).join('|')
  useEffect(() => {
    for (const entry of props.tokens) {
      if (entry.masked) check(entry.kind)
      else setChecks((current) => ({ ...current, [entry.kind]: undefined }))
    }
    // Re-check only when a token is added, replaced or deleted.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [savedKey])

  return (
    <section className="card stack">
      <div className="row">
        <div className="stack" style={{ gap: 2 }}>
          <h2>Tokens</h2>
          <span className="hint">Tokens for the services Crawlspace connects to. Kept on this Mac only; never shown in full.</span>
        </div>
        <span className="spacer" />
        <button className="primary small" onClick={() => setAdding(props.tokens.find((entry) => !entry.masked)?.kind ?? 'clickup')}>
          + Add token
        </button>
      </div>

      <table className="simple tokens">
        <thead>
          <tr>
            <th>Service</th>
            <th>Token</th>
            <th>Status</th>
            <th>Added</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {props.tokens.map((entry) => (
            <tr key={entry.kind}>
              <td>
                <strong>{entry.service}</strong>
                <div className="hint">{entry.purpose}</div>
              </td>
              <td>{entry.masked ? <code>{entry.masked}</code> : <span className="hint">Not added</span>}</td>
              <td>{entry.masked && <TokenStatus check={checks[entry.kind]} />}</td>
              <td className="hint">{entry.addedAt ? relativeDate(entry.addedAt) : entry.masked ? '—' : ''}</td>
              <td className="actions">
                {entry.masked ? (
                  <>
                    <button className="small" disabled={checks[entry.kind] === 'checking'} onClick={() => check(entry.kind)}>
                      Check
                    </button>
                    <button className="small" onClick={() => setAdding(entry.kind)}>
                      Replace
                    </button>
                    <button className="small danger" onClick={() => setRemoving(entry)}>
                      Delete
                    </button>
                  </>
                ) : (
                  <button className="small" onClick={() => setAdding(entry.kind)}>
                    Add
                  </button>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      {adding && (
        <AddTokenDialog
          kind={adding}
          tokens={props.tokens}
          onCancel={() => setAdding(null)}
          onAdded={(next) => {
            setAdding(null)
            props.onChange(next)
          }}
        />
      )}
      {removing && (
        <Confirm
          title={`Delete the ${removing.service} token?`}
          message={`${withoutToken[removing.kind]} The token itself stays valid on ${removing.service}; revoke it there too if you no longer need it.`}
          action="Delete"
          danger
          onCancel={() => setRemoving(null)}
          onConfirm={async () => {
            const entry = removing
            setRemoving(null)
            const next = await run(() => api.delete<SettingsResponse>(`/api/tokens/${entry.kind}`), 'Token deleted')
            if (next) props.onChange(next)
          }}
        />
      )}
    </section>
  )
}

function TokenStatus({ check }: { check?: TokenCheck | 'checking' }) {
  if (!check) return null
  if (check === 'checking') return <span className="hint">Checking…</span>
  const look = { working: ['ok', 'Working'], rejected: ['bad', 'Rejected'], unknown: ['', "Couldn't check"] }[
    check.status
  ]
  return (
    <div className="token-status">
      <span className={`chip ${look[0]}`}>{look[1]}</span>
      <div className="hint">{check.detail}</div>
    </div>
  )
}

function AddTokenDialog(props: {
  kind: TokenKind
  tokens: TokenEntry[]
  onCancel: () => void
  onAdded: (next: SettingsResponse) => void
}) {
  const run = useAction()
  const [kind, setKind] = useState<TokenKind>(props.kind)
  const [value, setValue] = useState('')
  const [busy, setBusy] = useState(false)
  const existing = props.tokens.find((entry) => entry.kind === kind)

  const add = async () => {
    setBusy(true)
    const next = await run(() => api.put<SettingsResponse>(`/api/tokens/${kind}`, { value: value.trim() }), 'Token added')
    setBusy(false)
    if (next) props.onAdded(next)
  }

  return (
    <Dialog
      title="Add token"
      size="narrow"
      onClose={props.onCancel}
      busy={busy}
      footer={
        <>
          <button onClick={props.onCancel} disabled={busy}>
            Cancel
          </button>
          <button className="primary" disabled={!value.trim() || busy} onClick={add}>
            {busy ? 'Adding…' : existing?.masked ? 'Replace token' : 'Add token'}
          </button>
        </>
      }
    >
      <label className="field">
        <span>Service</span>
        <select value={kind} onChange={(event) => setKind(event.target.value as TokenKind)}>
          {props.tokens.map((entry) => (
            <option key={entry.kind} value={entry.kind}>
              {entry.service} ({entry.purpose})
            </option>
          ))}
        </select>
      </label>
      <form
        className="field"
        onSubmit={(event) => {
          event.preventDefault()
          if (value.trim()) add()
        }}
      >
        <span>Token</span>
        <input
          type="password"
          autoComplete="off"
          autoFocus
          placeholder="pk_…"
          value={value}
          onChange={(event) => setValue(event.target.value)}
        />
      </form>
      <p className="hint">{tokenHelp[kind]}</p>
      {existing?.masked && (
        <p className="hint">
          This replaces the {existing.service} token you have now (<code>{existing.masked}</code>).
        </p>
      )}
    </Dialog>
  )
}
