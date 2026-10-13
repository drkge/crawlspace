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
  summaryTitle?: string
  clientName: string
  preparedBy: string
  notes: string
  accent: string
  maxIssues: number
  examplesPerIssue: number
  format: 'pdf' | 'html'
}

/**
 * The full audit report, or the short client summary in plain words, as a PDF or a self-contained
 * web page. Both share the branding; the summary can show progress since an earlier crawl.
 */
export function ReportDialog({
  crawlID,
  site,
  kind,
  onClose,
}: {
  crawlID: string
  site: string
  kind: 'audit' | 'summary'
  onClose: () => void
}) {
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
  const [earlier, setEarlier] = useState<CrawlListItem[]>([])
  const [baseline, setBaseline] = useState('')
  const set = (patch: Partial<ReportSettings>) => setSettings({ ...settings, ...patch })
  const isSummary = kind === 'summary'
  const title = isSummary ? (settings.summaryTitle ?? 'Website Summary') : settings.title
  const setTitle = (value: string) => set(isSummary ? { summaryTitle: value } : { title: value })

  // Earlier crawls of the same site, newest first, the latest picked to show progress since.
  useEffect(() => {
    if (!isSummary) return
    api.get<CrawlListItem[]>('/api/crawls').then((all) => {
      const current = all.find((crawl) => crawl.id === crawlID)
      const before = all.filter(
        (crawl) => crawl.id !== crawlID && crawl.readable && crawl.site === site && (!current || crawl.modified < current.modified),
      )
      setEarlier(before)
      setBaseline(before[0]?.id ?? '')
    })
  }, [crawlID, site, isSummary])

  const chooseLogo = (file: File | undefined) => {
    if (!file) return
    const reader = new FileReader()
    reader.onload = () => setLogo(String(reader.result).split(',')[1] ?? null)
    reader.readAsDataURL(file)
  }

  const build = async () => {
    setBusy(true)
    try {
      await downloadFrom('POST', `${crawlPath(crawlID)}/export/report`, {
        ...settings,
        title,
        logo,
        kind,
        baseline: isSummary ? baseline : undefined,
      })
      onClose()
    } catch (error) {
      toast(messageOf(error), true)
    } finally {
      setBusy(false)
    }
  }

  return (
    <Dialog
      title={isSummary ? 'Client Summary' : 'Audit Report'}
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
            {busy ? 'Building…' : isSummary ? 'Download Summary' : 'Download Report'}
          </button>
        </>
      }
    >
      <div className="form-grid">
        <label className="field">
          <span>Title</span>
          <input type="text" value={title} onChange={(event) => setTitle(event.target.value)} />
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
        {!isSummary && (
          <>
            <label className="field">
              <span>Issues to include</span>
              <input type="number" min={5} max={80} value={settings.maxIssues} onChange={(event) => set({ maxIssues: Number(event.target.value) })} />
            </label>
            <label className="field">
              <span>Examples per issue</span>
              <input
                type="number"
                min={1}
                max={20}
                value={settings.examplesPerIssue}
                onChange={(event) => set({ examplesPerIssue: Number(event.target.value) })}
              />
            </label>
          </>
        )}
      </div>
      {isSummary && (
        <label className="field">
          <span>Show progress since</span>
          <select value={baseline} onChange={(event) => setBaseline(event.target.value)}>
            <option value="">Nothing — this crawl only</option>
            {earlier.map((crawl) => (
              <option key={crawl.id} value={crawl.id}>
                {crawl.name} · {relativeDate(crawl.modified)}
              </option>
            ))}
          </select>
          <span className="hint">
            {isSummary && earlier.length === 0
              ? `No earlier crawl of ${site} to compare with.`
              : 'Plain words, no URL lists: what to fix first, by area, and what has changed since.'}
          </span>
        </label>
      )}
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

/** Where one topic goes: a list that's there, or one to make (in a folder, or in the space). */
interface ListTarget {
  listID?: string
  folderName: string | null
  listName: string
}

/** The lists issues are filed into, in the order the panel shows them. */
const topics = ['links', 'images', 'siteSettings', 'duplicates', 'speed', 'products', 'errors', 'warnings', 'notices'] as const
type Topic = (typeof topics)[number]
const topicNames: Record<Topic, string> = {
  links: 'Links',
  images: 'Images',
  siteSettings: 'Site settings',
  duplicates: 'Duplicates',
  speed: 'Speed',
  products: 'Products',
  errors: 'Errors',
  warnings: 'Warnings',
  notices: 'Notices',
}
const topicHints: Record<Topic, string> = {
  links: 'A task per broken or redirecting URL, with every page linking to it, and per link in the theme.',
  images: 'A task per image, with every page showing it.',
  siteSettings: 'A task per setting, such as a security header, rather than per page.',
  duplicates: 'A task per group of pages sharing a title, description, H1 or content.',
  speed: 'A task per template Lighthouse measured.',
  products: 'A task per product page, with what its data is missing.',
  errors: 'A task per page, with the rest of its errors.',
  warnings: 'A task per page, with the rest of its warnings.',
  notices: 'A task per page, with the rest of its notices.',
}
const severityNames: Record<SeverityName, string> = { error: 'Errors', warning: 'Warnings', notice: 'Notices' }
const standardTarget = (topic: Topic): ListTarget => ({ folderName: 'Crawlspace', listName: topicNames[topic] })
const pathOf = (target: { folderName?: string | null; listName: string }) => [target.folderName, target.listName].filter(Boolean).join(' › ')
const same = (a?: string | null, b?: string | null) => (a ?? '').trim().toLowerCase() === (b ?? '').trim().toLowerCase()
const standardTargets = () => Object.fromEntries(topics.map((topic) => [topic, standardTarget(topic)])) as Record<Topic, ListTarget>

/**
 * Files the crawl's issues into ClickUp, a task per thing to fix: choose a space, then where each
 * topic goes, any list in the space or a new one (Crawlspace › Links, Images… by default).
 * Remembered for the site, so a rescan goes to the same places.
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
  const [targets, setTargets] = useState<Record<Topic, ListTarget>>(standardTargets)
  const [remembered, setRemembered] = useState<{ spaceID: string; targets: Partial<Record<Topic, ListTarget>> } | null>(null)
  const [severities, setSeverities] = useState<SeverityName[]>(['error', 'warning'])
  const [chosen, setChosen] = useState<Topic[]>([...topics])
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
      setChosen(topics.filter((topic) => settings.clickUpTopics.includes(topic)))
    })
  }, [])

  // The spaces, and where this site went last time.
  const loadSpaces = async () => {
    const [found, saved] = await Promise.all([
      run(() => api.get<SpaceChoice[]>('/api/clickup/spaces')),
      api.get<{ site: string; destination?: { spaceID: string; spaceName: string; targets: Partial<Record<Topic, ListTarget>> } }>(
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

  // A space's lists, and where each topic goes in it: as remembered for this site, else the
  // Crawlspace folder's matching list if it's there, else a new one there.
  useEffect(() => {
    setLists(null)
    if (!spaceID) return
    api
      .get<ListChoice[]>(`/api/clickup/spaces/${spaceID}/lists`)
      .then((found) => {
        setLists(found)
        const saved = remembered?.spaceID === spaceID ? remembered.targets : {}
        const pick = (topic: Topic): ListTarget => {
          const previous = saved[topic]
          const existing =
            (previous?.listID && found.find((list) => list.id === previous.listID)) ||
            (previous && found.find((list) => same(list.folderName, previous.folderName) && same(list.listName, previous.listName)))
          if (existing) return { listID: existing.id, folderName: existing.folderName ?? null, listName: existing.listName }
          if (previous) return { folderName: previous.folderName, listName: previous.listName }
          const standard = found.find((list) => same(list.folderName, 'Crawlspace') && same(list.listName, topicNames[topic]))
          return standard ? { listID: standard.id, folderName: 'Crawlspace', listName: standard.listName } : standardTarget(topic)
        }
        setTargets(Object.fromEntries(topics.map((topic) => [topic, pick(topic)])) as Record<Topic, ListTarget>)
      })
      .catch(() => setLists([]))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [spaceID])

  const setTarget = (topic: Topic, target: ListTarget) => setTargets({ ...targets, [topic]: target })
  const space = spaces?.find((entry) => entry.id === spaceID)
  const destination = { spaceID, spaceName: space?.name ?? '', targets }
  const request = { destination, severities, topics: chosen, extraTag: tag }
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

  const toggle = <T,>(list: T[], value: T, set: (next: T[]) => void) =>
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
            disabled={busy || !hasToken || !spaceID || lists === null || !severities.length || !chosen.length || chosen.some((topic) => !targets[topic].listName.trim())}
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
            {topics.map((topic) => {
              const target = targets[topic]
              const isNew = !target.listID
              const on = chosen.includes(topic)
              return (
                <div className="severity-row" key={topic}>
                  <label className="check" title={topicHints[topic]}>
                    <input type="checkbox" checked={on} onChange={() => toggle(chosen, topic, setChosen)} />
                    {topicNames[topic]}
                  </label>
                  <div className="stack" style={{ gap: 6 }}>
                    <select
                      disabled={!on || !spaceID || lists === null}
                      value={isNew ? 'new' : target.listID}
                      onChange={(event) => {
                        const value = event.target.value
                        if (value === 'new') return setTarget(topic, standardTarget(topic))
                        const list = lists?.find((entry) => entry.id === value)
                        if (list) setTarget(topic, { listID: list.id, folderName: list.folderName ?? null, listName: list.listName })
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
                          onChange={(event) => setTarget(topic, { ...target, folderName: event.target.value || null })}
                          style={{ width: 150 }}
                        />
                        <span className="hint">›</span>
                        <input
                          type="text"
                          placeholder="List"
                          value={target.listName}
                          onChange={(event) => setTarget(topic, { ...target, listName: event.target.value })}
                          style={{ flex: 1 }}
                        />
                      </div>
                    )}
                    {on && <span className="hint">{topicHints[topic]}</span>}
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
                </div>
              )
            })}
          </fieldset>
          <div className="row wrap">
            <span>Include</span>
            {(['error', 'warning', 'notice'] as const).map((severity) => (
              <label className="check" key={severity}>
                <input type="checkbox" checked={severities.includes(severity)} onChange={() => toggle(severities, severity, setSeverities)} />
                <Severity severity={severity} /> {severityNames[severity]}
              </label>
            ))}
          </div>
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
