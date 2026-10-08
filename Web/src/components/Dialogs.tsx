import { useEffect, useState } from 'react'
import {
  api,
  crawlPath,
  downloadFrom,
  type Change,
  type Comparison,
  type CrawlListItem,
  type Settings,
  type Severity as SeverityName,
} from '../api'
import { number, relativeDate, useStoredState, useEvents } from '../hooks'
import { Dialog, Severity, messageOf, useAction, useToast } from '../ui'

// MARK: Report

interface ReportSettings {
  title: string
  clientName: string
  preparedBy: string
  notes: string
  accent: string
  maxIssues: number
  examplesPerIssue: number
  format: 'pdf' | 'html'
}

/** The client-facing audit report, as a PDF or a self-contained web page. */
export function ReportDialog({ crawlID, onClose }: { crawlID: string; onClose: () => void }) {
  const toast = useToast()
  const [settings, setSettings] = useStoredState<ReportSettings>('report', {
    title: 'SEO Audit',
    clientName: '',
    preparedBy: '',
    notes: '',
    accent: '#2E70EB',
    maxIssues: 25,
    examplesPerIssue: 5,
    format: 'pdf',
  })
  const [logo, setLogo] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const set = (patch: Partial<ReportSettings>) => setSettings({ ...settings, ...patch })

  const chooseLogo = (file: File | undefined) => {
    if (!file) return
    const reader = new FileReader()
    reader.onload = () => setLogo(String(reader.result).split(',')[1] ?? null)
    reader.readAsDataURL(file)
  }

  const build = async () => {
    setBusy(true)
    try {
      await downloadFrom('POST', `${crawlPath(crawlID)}/export/report`, { ...settings, logo })
      onClose()
    } catch (error) {
      toast(messageOf(error), true)
    } finally {
      setBusy(false)
    }
  }

  return (
    <Dialog
      title="Audit Report"
      onClose={onClose}
      busy={busy}
      footer={
        <>
          <div className="segmented">
            <button className={settings.format === 'pdf' ? 'on' : ''} onClick={() => set({ format: 'pdf' })}>
              PDF
            </button>
            <button className={settings.format === 'html' ? 'on' : ''} onClick={() => set({ format: 'html' })}>
              Web page
            </button>
          </div>
          <span className="spacer" />
          <button onClick={onClose} disabled={busy}>
            Cancel
          </button>
          <button className="primary" onClick={build} disabled={busy}>
            {busy ? 'Building…' : 'Download Report'}
          </button>
        </>
      }
    >
      <div className="form-grid">
        <label className="field">
          <span>Title</span>
          <input type="text" value={settings.title} onChange={(event) => set({ title: event.target.value })} />
        </label>
        <label className="field">
          <span>Client</span>
          <input type="text" value={settings.clientName} onChange={(event) => set({ clientName: event.target.value })} />
        </label>
        <label className="field">
          <span>Prepared by</span>
          <input type="text" value={settings.preparedBy} onChange={(event) => set({ preparedBy: event.target.value })} />
        </label>
      </div>
      <label className="field">
        <span>Introduction</span>
        <textarea rows={3} style={{ fontFamily: 'inherit', fontSize: 13 }} value={settings.notes} onChange={(event) => set({ notes: event.target.value })} />
      </label>
      <div className="row wrap" style={{ gap: 20 }}>
        <label className="field">
          <span>Accent colour</span>
          <input type="color" value={settings.accent} onChange={(event) => set({ accent: event.target.value.toUpperCase() })} />
        </label>
        <label className="field">
          <span>Logo (PNG or JPEG)</span>
          <input type="file" accept="image/png,image/jpeg" onChange={(event) => chooseLogo(event.target.files?.[0])} />
        </label>
        <label className="field">
          <span>Issues to include</span>
          <input type="number" min={5} max={80} value={settings.maxIssues} onChange={(event) => set({ maxIssues: Number(event.target.value) })} />
        </label>
        <label className="field">
          <span>Examples per issue</span>
          <input type="number" min={1} max={20} value={settings.examplesPerIssue} onChange={(event) => set({ examplesPerIssue: Number(event.target.value) })} />
        </label>
      </div>
    </Dialog>
  )
}

// MARK: Compare

/** What changed since an earlier crawl of the same site. */
export function CompareDialog({ crawlID, site, onClose }: { crawlID: string; site: string; onClose: () => void }) {
  const [crawls, setCrawls] = useState<CrawlListItem[]>([])
  const [baseline, setBaseline] = useState<string | null>(null)
  const [comparison, setComparison] = useState<Comparison | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [section, setSection] = useState<'issues' | 'urls' | 'changes'>('issues')

  useEffect(() => {
    api.get<CrawlListItem[]>('/api/crawls').then((all) => {
      const others = all.filter((crawl) => crawl.id !== crawlID && crawl.readable)
      // The same site first: that's nearly always the comparison wanted.
      others.sort((a, b) => Number(b.site === site) - Number(a.site === site))
      setCrawls(others)
      const same = others.find((crawl) => crawl.site === site)
      if (same) setBaseline(same.id)
    })
  }, [crawlID, site])

  useEffect(() => {
    if (!baseline) return
    setComparison(null)
    setError(null)
    api
      .get<Comparison>(`${crawlPath(crawlID)}/compare/${encodeURIComponent(baseline)}`)
      .then(setComparison)
      .catch((failure) => setError(messageOf(failure)))
  }, [baseline, crawlID])

  const changes = (title: string, list: Change[], total: number) =>
    list.length > 0 && (
      <section className="stack" style={{ gap: 6 }} key={title}>
        <h3>
          {title} ({number(total)})
        </h3>
        <table className="simple">
          <tbody>
            {list.slice(0, 500).map((change, index) => (
              <tr key={index}>
                <td style={{ wordBreak: 'break-all' }}>{change.url}</td>
                {(change.before !== undefined || change.after !== undefined) && (
                  <td>
                    {change.before ?? '–'} → {change.after ?? '–'}
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
        {total > 500 && <span className="hint">…and {number(total - 500)} more</span>}
      </section>
    )

  return (
    <Dialog title="Compare with an Earlier Crawl" size="wide" onClose={onClose} footer={<button onClick={onClose}>Done</button>}>
      <label className="field">
        <span>Compare with</span>
        <select value={baseline ?? ''} onChange={(event) => setBaseline(event.target.value || null)}>
          <option value="">Choose a crawl…</option>
          {crawls.map((crawl) => (
            <option key={crawl.id} value={crawl.id}>
              {crawl.site} · {relativeDate(crawl.modified)} · {number(crawl.crawled)} URLs
            </option>
          ))}
        </select>
      </label>
      {error && <p className="error-text">{error}</p>}
      {baseline && !comparison && !error && <p className="hint">Comparing…</p>}
      {comparison && (
        <>
          <div className="tiles">
            {[
              ['New URLs', comparison.counts.added],
              ['Gone', comparison.counts.removed],
              ['New issues', comparison.counts.newIssues],
              ['Fixed', comparison.counts.fixedIssues],
              ['Status changes', comparison.counts.statusChanged],
            ].map(([label, value]) => (
              <div className="tile" key={label}>
                <span className="value">{number(value as number)}</span>
                <span className="label">{label}</span>
              </div>
            ))}
          </div>
          <div className="segmented">
            {(['issues', 'urls', 'changes'] as const).map((name) => (
              <button key={name} className={section === name ? 'on' : ''} onClick={() => setSection(name)}>
                {name === 'issues' ? 'Issues' : name === 'urls' ? 'URLs' : 'Changes'}
              </button>
            ))}
          </div>
          {section === 'issues' && (
            <table className="simple">
              <thead>
                <tr>
                  <th>Issue</th>
                  <th className="num">Before</th>
                  <th className="num">After</th>
                  <th className="num">Change</th>
                </tr>
              </thead>
              <tbody>
                {comparison.issueDeltas.map((delta) => (
                  <tr key={delta.code}>
                    <td>
                      <Severity severity={['error', 'warning', 'notice'][delta.severity]} /> {delta.title}
                    </td>
                    <td className="num">{number(delta.before)}</td>
                    <td className="num">{number(delta.after)}</td>
                    <td className="num" style={{ color: delta.after > delta.before ? 'var(--error)' : 'var(--good)' }}>
                      {delta.after - delta.before > 0 ? '+' : ''}
                      {number(delta.after - delta.before)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          {section === 'urls' && (
            <>
              {changes('Added', comparison.added, comparison.counts.added)}
              {changes('Removed', comparison.removed, comparison.counts.removed)}
            </>
          )}
          {section === 'changes' && (
            <>
              {changes('Status', comparison.statusChanges, comparison.counts.statusChanged)}
              {changes('Indexability', comparison.indexabilityChanges, comparison.counts.indexabilityChanged)}
              {changes('Title', comparison.titleChanges, comparison.counts.titleChanged)}
              {changes('Canonical', comparison.canonicalChanges, comparison.counts.canonicalChanged)}
            </>
          )}
        </>
      )}
    </Dialog>
  )
}

// MARK: ClickUp

interface SpaceChoice {
  id: string
  name: string
  workspace?: string
}

/** A list in the chosen space; no folder when it sits directly in the space. */
interface ListChoice {
  id: string
  folderName?: string
  listName: string
}

/** Where one severity goes: a list that's there, or one to make (in a folder, or in the space). */
interface ListTarget {
  listID?: string
  folderName: string | null
  listName: string
}

const listNames: Record<SeverityName, string> = { error: 'Errors', warning: 'Warnings', notice: 'Notices' }
const standardTarget = (severity: SeverityName): ListTarget => ({ folderName: 'Crawlspace', listName: listNames[severity] })
const pathOf = (target: { folderName?: string | null; listName: string }) => [target.folderName, target.listName].filter(Boolean).join(' › ')
const same = (a?: string | null, b?: string | null) => (a ?? '').trim().toLowerCase() === (b ?? '').trim().toLowerCase()

/**
 * Files the crawl's issues into ClickUp: choose a space, then where each severity goes, any list
 * in the space or a new one (Crawlspace › Errors, Warnings, Notices by default). Remembered for
 * the site, so a rescan goes to the same places.
 */
export function ClickUpDialog({ crawlID, onClose }: { crawlID: string; onClose: () => void }) {
  const run = useAction()
  const toast = useToast()
  const [settings, setSettings] = useState<Settings | null>(null)
  const [hasToken, setHasToken] = useState(false)
  const [token, setToken] = useState('')
  const [site, setSite] = useState('')
  const [spaces, setSpaces] = useState<SpaceChoice[] | null>(null)
  const [spaceID, setSpaceID] = useState('')
  const [lists, setLists] = useState<ListChoice[] | null>(null)
  const [targets, setTargets] = useState<Record<SeverityName, ListTarget>>({
    error: standardTarget('error'),
    warning: standardTarget('warning'),
    notice: standardTarget('notice'),
  })
  const [remembered, setRemembered] = useState<{ spaceID: string; targets: Partial<Record<SeverityName, ListTarget>> } | null>(null)
  const [severities, setSeverities] = useState<SeverityName[]>(['error', 'warning'])
  const [tables, setTables] = useState<SeverityName[]>(['notice'])
  const [everyPage, setEveryPage] = useState(true)
  const [cap, setCap] = useState(25)
  const [attach, setAttach] = useState(true)
  const [tag, setTag] = useState('')
  const [plan, setPlan] = useState('')
  const [busy, setBusy] = useState(false)
  const [progress, setProgress] = useState<{ title: string; fraction: number } | null>(null)
  const [result, setResult] = useState<string | null>(null)

  useEvents(busy ? `${crawlPath(crawlID)}/events` : null, { clickup: setProgress })

  useEffect(() => {
    api.get<{ settings: Settings; tokens: { kind: string; masked?: string }[] }>('/api/settings').then(({ settings, tokens }) => {
      setSettings(settings)
      setHasToken(tokens.some((entry) => entry.kind === 'clickup' && !!entry.masked))
      setSeverities(settings.clickUpSeverities)
      setTables(settings.clickUpTableSeverities)
      setEveryPage(settings.clickUpSubtaskLimit <= 0)
      if (settings.clickUpSubtaskLimit > 0) setCap(settings.clickUpSubtaskLimit)
    })
  }, [])

  // The spaces, and where this site went last time.
  const loadSpaces = async () => {
    const [found, saved] = await Promise.all([
      run(() => api.get<SpaceChoice[]>('/api/clickup/spaces')),
      api.get<{ site: string; destination?: { spaceID: string; spaceName: string; targets: Partial<Record<SeverityName, ListTarget>> } }>(
        `${crawlPath(crawlID)}/clickup/destination`,
      ),
    ])
    setSite(saved.site)
    if (!found) return
    setSpaces(found)
    if (!found.length) toast('That token works, but there are no spaces in the workspace.', true)
    const known = saved.destination && found.find((space) => space.id === saved.destination!.spaceID)
    if (known) {
      setRemembered({ spaceID: known.id, targets: saved.destination!.targets })
      setSpaceID(known.id)
    } else {
      // A space named like the site is the likely home for its issues.
      const words = saved.site.replace(/^www\./, '').split('.')[0].toLowerCase()
      setSpaceID(found.find((space) => space.name.toLowerCase().replace(/\s+/g, '').includes(words))?.id ?? '')
    }
  }

  useEffect(() => {
    if (hasToken) loadSpaces()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [hasToken])

  // A space's lists, and where each severity goes in it: as remembered for this site, else the
  // Crawlspace folder's matching list if it's there, else a new one there.
  useEffect(() => {
    setLists(null)
    if (!spaceID) return
    api
      .get<ListChoice[]>(`/api/clickup/spaces/${spaceID}/lists`)
      .then((found) => {
        setLists(found)
        const saved = remembered?.spaceID === spaceID ? remembered.targets : {}
        const pick = (severity: SeverityName): ListTarget => {
          const previous = saved[severity]
          const existing =
            (previous?.listID && found.find((list) => list.id === previous.listID)) ||
            (previous && found.find((list) => same(list.folderName, previous.folderName) && same(list.listName, previous.listName)))
          if (existing) return { listID: existing.id, folderName: existing.folderName ?? null, listName: existing.listName }
          if (previous) return { folderName: previous.folderName, listName: previous.listName }
          const standard = found.find((list) => same(list.folderName, 'Crawlspace') && same(list.listName, listNames[severity]))
          return standard ? { listID: standard.id, folderName: 'Crawlspace', listName: standard.listName } : standardTarget(severity)
        }
        setTargets({ error: pick('error'), warning: pick('warning'), notice: pick('notice') })
      })
      .catch(() => setLists([]))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [spaceID])

  const setTarget = (severity: SeverityName, target: ListTarget) => setTargets({ ...targets, [severity]: target })
  const space = spaces?.find((entry) => entry.id === spaceID)
  const destination = { spaceID, spaceName: space?.name ?? '', targets }
  const request = { destination, severities, tableSeverities: tables, subtaskLimit: everyPage ? 0 : cap, attachFullList: attach, extraTag: tag }
  const requestKey = JSON.stringify(request)
  useEffect(() => {
    if (!settings) return
    api.post<{ message: string }>(`${crawlPath(crawlID)}/clickup/plan`, request).then((answer) => setPlan(answer.message))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [requestKey, settings, crawlID])

  const saveToken = async () => {
    const saved = await run(() => api.put('/api/tokens/clickup', { value: token }))
    if (!saved) return
    setToken('')
    setHasToken(true)
  }

  const exportNow = async () => {
    setBusy(true)
    setResult(null)
    const answer = await run(() => api.post<{ message: string }>(`${crawlPath(crawlID)}/clickup/export`, request))
    setBusy(false)
    setProgress(null)
    if (answer) setResult(answer.message)
  }

  const toggle = (list: SeverityName[], value: SeverityName, set: (next: SeverityName[]) => void) =>
    set(list.includes(value) ? list.filter((item) => item !== value) : [...list, value])

  return (
    <Dialog
      title="Export to ClickUp"
      onClose={onClose}
      busy={busy}
      footer={
        <>
          <span className="spacer" />
          <button onClick={onClose} disabled={busy}>
            {result ? 'Done' : 'Cancel'}
          </button>
          <button
            className="primary"
            disabled={busy || !hasToken || !spaceID || lists === null || !severities.length || severities.some((severity) => !targets[severity].listName.trim())}
            onClick={exportNow}
          >
            {busy ? 'Filing…' : 'Export to ClickUp'}
          </button>
        </>
      }
    >
      {!hasToken ? (
        <div className="stack">
          <p>
            Paste a personal API token from ClickUp ▸ Settings ▸ Apps. It's kept with Crawlspace's other secrets on this Mac, never in a
            crawl.
          </p>
          <div className="row">
            <input type="password" style={{ flex: 1 }} placeholder="pk_…" value={token} onChange={(event) => setToken(event.target.value)} />
            <button className="primary" disabled={!token.trim()} onClick={saveToken}>
              Save Token
            </button>
          </div>
        </div>
      ) : (
        <>
          <label className="field">
            <span>Space</span>
            <select value={spaceID} onChange={(event) => setSpaceID(event.target.value)} disabled={!spaces}>
              {!spaces && <option>Reading your workspace…</option>}
              {spaces && <option value="">Choose a space…</option>}
              {spaces?.map((choice) => (
                <option key={choice.id} value={choice.id}>
                  {choice.workspace ? `${choice.workspace} ▸ ` : ''}
                  {choice.name}
                </option>
              ))}
            </select>
            {site && <span className="hint">Remembered for {site}, so rescans go to the same places.</span>}
          </label>

          <fieldset>
            <legend>What to file, and where</legend>
            {spaceID && lists === null && <p className="hint">Reading the lists in {space?.name}…</p>}
            {(['error', 'warning', 'notice'] as const).map((severity) => {
              const target = targets[severity]
              const isNew = !target.listID
              const on = severities.includes(severity)
              return (
                <div className="severity-row" key={severity}>
                  <label className="check">
                    <input type="checkbox" checked={on} onChange={() => toggle(severities, severity, setSeverities)} />
                    <Severity severity={severity} /> {listNames[severity]}
                  </label>
                  <div className="stack" style={{ gap: 6 }}>
                    <select
                      disabled={!on || !spaceID || lists === null}
                      value={isNew ? 'new' : target.listID}
                      onChange={(event) => {
                        const value = event.target.value
                        if (value === 'new') return setTarget(severity, standardTarget(severity))
                        const list = lists?.find((entry) => entry.id === value)
                        if (list) setTarget(severity, { listID: list.id, folderName: list.folderName ?? null, listName: list.listName })
                      }}
                    >
                      {lists?.map((list) => (
                        <option key={list.id} value={list.id}>
                          {pathOf(list)}
                        </option>
                      ))}
                      <option value="new">{isNew ? `New list: ${pathOf(target) || '…'}` : 'New list…'}</option>
                    </select>
                    {on && isNew && spaceID && lists !== null && (
                      <div className="row">
                        <input
                          type="text"
                          placeholder="Folder (blank for none)"
                          value={target.folderName ?? ''}
                          onChange={(event) => setTarget(severity, { ...target, folderName: event.target.value || null })}
                          style={{ width: 150 }}
                        />
                        <span className="hint">›</span>
                        <input
                          type="text"
                          placeholder="List"
                          value={target.listName}
                          onChange={(event) => setTarget(severity, { ...target, listName: event.target.value })}
                          style={{ flex: 1 }}
                        />
                      </div>
                    )}
                    {on && isNew && spaceID && lists !== null && (
                      <span className="hint">
                        Made in {space?.name} when you export
                        {target.folderName && !lists.some((list) => same(list.folderName, target.folderName))
                          ? `, along with the ${target.folderName} folder`
                          : ''}
                        .
                      </span>
                    )}
                  </div>
                  <div className="segmented">
                    <button disabled={!on} className={!tables.includes(severity) ? 'on' : ''} onClick={() => setTables(tables.filter((item) => item !== severity))}>
                      Subtasks
                    </button>
                    <button disabled={!on} className={tables.includes(severity) ? 'on' : ''} onClick={() => !tables.includes(severity) && setTables([...tables, severity])}>
                      Table
                    </button>
                  </div>
                </div>
              )
            })}
          </fieldset>
          <label className="check">
            <input type="checkbox" checked={everyPage} onChange={(event) => setEveryPage(event.target.checked)} />
            Every affected page as a subtask
          </label>
          {!everyPage && (
            <div className="row wrap">
              <span>Subtasks for the</span>
              <input type="number" min={5} max={500} value={cap} onChange={(event) => setCap(Number(event.target.value))} />
              <span>most-linked pages</span>
              <label className="check">
                <input type="checkbox" checked={attach} onChange={(event) => setAttach(event.target.checked)} />
                Attach the rest as a CSV
              </label>
            </div>
          )}
          <label className="field">
            <span>Extra tag (optional)</span>
            <input type="text" value={tag} onChange={(event) => setTag(event.target.value)} />
          </label>
          <p className="hint">{plan}</p>
          {progress && (
            <div className="stack" style={{ gap: 4 }}>
              <span>{progress.title}</span>
              <div className="progress" style={{ width: '100%' }}>
                <div style={{ width: `${progress.fraction * 100}%` }} />
              </div>
            </div>
          )}
          {result && <p>{result}</p>}
        </>
      )}
    </Dialog>
  )
}
