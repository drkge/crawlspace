import { useEffect, useState, type ReactNode } from 'react'
import { api, crawlPath, type Bucket, type Counts, type CrawlState, type Issue, type MeasuredPage } from '../api'
import { duration, number, plural } from '../hooks'
import { ScoreGauge, Severity } from '../ui'

const pageFilters: [string, string][] = [
  ['filter:internalHTML', 'Internal HTML'],
  ['filter:internalAll', 'Internal'],
  ['filter:external', 'External'],
  ['filter:images', 'Images'],
  ['filter:cssAndJavaScript', 'CSS & JavaScript'],
  ['filter:notCrawled', 'Not Crawled'],
]

const reports: [string, string][] = [
  ['filter:redirectChains', 'Redirect Chains'],
  ['filter:inSitemap', 'In XML Sitemap'],
  ['filter:nearDuplicates', 'Near Duplicates'],
]

const severities = [
  ['error', 'Errors'],
  ['warning', 'Warnings'],
  ['notice', 'Notices'],
] as const

/** Overview, the page tables, every issue found by severity, custom extraction and the reports. */
export function Sidebar(props: { counts: Counts | null; selection: string; onSelect: (selection: string) => void }) {
  const { counts } = props
  const item = (key: string, label: ReactNode, count?: number, icon?: ReactNode) => (
    <button key={key} className={`sidebar-item ${props.selection === key ? 'selected' : ''}`} onClick={() => props.onSelect(key)} title={typeof label === 'string' ? label : undefined}>
      {icon}
      <span className="label">{label}</span>
      {count !== undefined && <span className="count">{number(count)}</span>}
    </button>
  )
  return (
    <aside className="sidebar">
      {item('overview', 'Overview')}
      <h3>All pages</h3>
      {pageFilters.map(([key, label]) => item(key, label, counts?.filters[key.slice(7)]))}
      {severities.map(([severity, title]) => {
        const issues = counts?.issues.filter((entry) => entry.issue.severity === severity) ?? []
        if (!issues.length) return null
        return (
          <div key={severity}>
            <h3>{title}</h3>
            {issues.map(({ issue, count }) =>
              item(`issue:${issue.code}`, `${issue.category}: ${issue.title}`, count, <Severity severity={severity} />),
            )}
          </div>
        )
      })}
      {!!counts?.extractions.length && (
        <>
          <h3>Custom extraction</h3>
          {counts.extractions.map((entry) => item(`extraction:${entry.name}`, entry.name, entry.count))}
        </>
      )}
      {!!counts?.searches.length && (
        <>
          <h3>Custom search</h3>
          {counts.searches.map((entry) => item(`search:${entry.name}`, entry.name, entry.count))}
        </>
      )}
      {reports.some(([key]) => (counts?.filters[key.slice(7)] ?? 0) > 0) && (
        <>
          <h3>Reports</h3>
          {reports.filter(([key]) => (counts?.filters[key.slice(7)] ?? 0) > 0).map(([key, label]) => item(key, label, counts?.filters[key.slice(7)]))}
        </>
      )}
    </aside>
  )
}

export function IssueBanner({ issue, count }: { issue: Issue; count: number }) {
  return (
    <details className="issue-banner">
      <summary>
        <Severity severity={issue.severity} />
        {issue.category}: {issue.title}
        <span className="hint" style={{ fontWeight: 400 }}>
          {plural(count, 'URL')}
        </span>
      </summary>
      <p style={{ margin: '8px 0 4px' }}>{issue.description}</p>
      <p style={{ margin: 0 }}>
        <strong>How to fix: </strong>
        {issue.howToFix}
      </p>
    </details>
  )
}

function Bars({ buckets }: { buckets: Bucket[] }) {
  const max = Math.max(1, ...buckets.map((bucket) => bucket.count))
  if (!buckets.length) return <p className="hint">Nothing yet.</p>
  return (
    <div className="bars">
      {buckets.map((bucket) => (
        <div key={bucket.label}>
          <span>{bucket.label}</span>
          <div className="bar" style={{ width: `${(bucket.count / max) * 100}%` }} />
          <span className="n">{number(bucket.count)}</span>
        </div>
      ))}
    </div>
  )
}

/** The dashboard: headline numbers, three charts, the biggest issues, and speed. */
export function Overview(props: {
  counts: Counts | null
  state: CrawlState
  onSelect: (selection: string) => void
  onSelectURL: (url: string) => void
  onRunLighthouse: () => void
  exportMenu: ReactNode
  version: number
}) {
  const { counts, state } = props
  const [measured, setMeasured] = useState<MeasuredPage[]>([])
  useEffect(() => {
    if (!counts?.hasLighthouse) return setMeasured([])
    api.get<MeasuredPage[]>(`${crawlPath(state.id)}/speed`).then(setMeasured).catch(() => {})
  }, [state.id, counts?.hasLighthouse, props.version])
  if (!counts) return <div className="empty">Loading…</div>
  const overview = counts.overview
  const bySeverity = (severity: string) =>
    counts.issues.filter((entry) => entry.issue.severity === severity).reduce((sum, entry) => sum + entry.count, 0)
  const biggest = [...counts.issues]
    .sort((a, b) => ['error', 'warning', 'notice'].indexOf(a.issue.severity) - ['error', 'warning', 'notice'].indexOf(b.issue.severity) || b.count - a.count)
    .slice(0, 10)
  const speedIssues = counts.issues.filter((entry) => entry.issue.category === 'Speed')
  const lighthouse = state.lighthouse

  return (
    <div className="overview">
      <div className="row">
        <h2>Overview</h2>
        <span className="spacer" />
        {props.exportMenu}
      </div>
      {state.ecommerceNote && <div className="card hint">{state.ecommerceNote}</div>}
      <div className="tiles">
        <div className="tile">
          <span className="value">{number(overview.crawled)}</span>
          <span className="label">URLs crawled · {number(overview.internalHTML)} internal HTML</span>
        </div>
        <div className="tile">
          <span className="value">{number(overview.indexable)}</span>
          <span className="label">Indexable · {number(overview.nonIndexable)} not</span>
        </div>
        <div className="tile">
          <span className="value" style={{ color: 'var(--error)' }}>
            {number(bySeverity('error'))}
          </span>
          <span className="label">Errors</span>
        </div>
        <div className="tile">
          <span className="value" style={{ color: 'var(--warning)' }}>
            {number(bySeverity('warning'))}
          </span>
          <span className="label">Warnings</span>
        </div>
        <div className="tile">
          <span className="value" style={{ color: 'var(--notice)' }}>
            {number(bySeverity('notice'))}
          </span>
          <span className="label">Notices</span>
        </div>
        <div className="tile">
          <span className="value">{overview.averageResponseMs ? `${Math.round(overview.averageResponseMs)} ms` : '–'}</span>
          <span className="label">Average response</span>
        </div>
      </div>

      <div className="charts">
        <div className="card stack">
          <h3>Response codes</h3>
          <Bars buckets={overview.statusClasses} />
        </div>
        <div className="card stack">
          <h3>Crawl depth</h3>
          <Bars buckets={overview.depths} />
        </div>
        <div className="card stack">
          <h3>Response times</h3>
          <Bars buckets={overview.responseTimes} />
        </div>
      </div>

      <div className="card stack">
        <div className="row">
          <h3>Speed</h3>
          <span className="spacer" />
          <button className="small" disabled={lighthouse.running || state.isRunning} onClick={props.onRunLighthouse}>
            {lighthouse.running ? 'Lighthouse is running…' : counts.hasLighthouse ? 'Measure again' : 'Run speed check'}
          </button>
        </div>
        {lighthouse.running && lighthouse.progress && (
          <p className="hint">
            Measuring {lighthouse.progress.currentURL ?? '…'} on {lighthouse.progress.currentDevice ?? 'mobile'} · {lighthouse.progress.done} of{' '}
            {lighthouse.progress.total} runs done
          </p>
        )}
        {lighthouse.message && !lighthouse.running && <p className="hint">{lighthouse.message}</p>}
        {!counts.hasLighthouse && !lighthouse.running && (
          <p className="hint">
            Lighthouse measures {state.speedPlan} on mobile and desktop
            {state.config.lighthouseTopPages > 0 ? ' when the crawl finishes' : ''}. Their scores join the table, and slow pages show up as Speed issues.
          </p>
        )}
        {measured.length > 0 && (
          <div style={{ overflowX: 'auto' }}>
            <SpeedTable pages={measured} onSelectURL={props.onSelectURL} />
          </div>
        )}
        {counts.hasLighthouse && (
          <div className="issue-list">
            {speedIssues.length === 0 && <p className="hint">No speed problems on the pages measured.</p>}
            {speedIssues.map(({ issue, count }) => (
              <button key={issue.code} onClick={() => props.onSelect(`issue:${issue.code}`)} className="row">
                <Severity severity={issue.severity} />
                <span style={{ flex: 1 }}>{issue.title}</span>
                <span className="hint">{plural(count, 'page')}</span>
              </button>
            ))}
            <button className="row" onClick={() => props.onSelect('filter:internalHTML')}>
              <span style={{ flex: 1 }}>See every page's scores in Internal HTML</span>
              <span className="hint">→</span>
            </button>
          </div>
        )}
      </div>

      <div className="card stack">
        <h3>Biggest issues</h3>
        <div className="issue-list">
          {biggest.length === 0 && <p className="hint">No issues found.</p>}
          {biggest.map(({ issue, count }) => (
            <button key={issue.code} onClick={() => props.onSelect(`issue:${issue.code}`)} className="row">
              <Severity severity={issue.severity} />
              <span style={{ flex: 1 }}>
                {issue.category}: {issue.title}
              </span>
              <span className="hint">{plural(count, 'URL')}</span>
            </button>
          ))}
        </div>
      </div>
    </div>
  )
}

const phaseText: Record<string, string> = {
  starting: 'Starting',
  crawling: 'Crawling',
  paused: 'Paused',
  stopping: 'Stopping',
  analysing: 'Analysing',
  failed: 'Failed',
}

export function StatusBar({ state }: { state: CrawlState }) {
  const progress = state.progress
  const idle = progress.phase === 'idle' || progress.phase === 'finished'
  const phase = idle
    ? state.status === 'completed'
      ? 'Completed'
      : state.status === 'stopped' || state.status === 'paused'
        ? 'Stopped'
        : 'Ready'
    : (phaseText[progress.phase] ?? progress.phase)
  const total = progress.crawled + progress.queued
  return (
    <footer className="statusbar">
      <span className="phase">
        <span className={`dot ${state.isRunning ? 'running' : ''}`} />
        {phase}
      </span>
      {!idle && (
        <>
          <span>{number(progress.crawled)} crawled</span>
          <span>{number(progress.queued)} queued</span>
          <span>{progress.urlsPerSecond.toFixed(1)} URLs/s</span>
          <span title={state.config.automaticConcurrency ? 'Chosen automatically, up to the maximum you set' : 'Fixed'}>
            {progress.concurrency} connection{progress.concurrency === 1 ? '' : 's'}
          </span>
          <span>{duration(progress.elapsedSeconds)}</span>
          {total > 0 && (
            <div className="progress">
              <div style={{ width: `${(progress.crawled / total) * 100}%` }} />
            </div>
          )}
        </>
      )}
      {state.lighthouse.running && state.lighthouse.progress && (
        <span>
          Lighthouse {state.lighthouse.progress.done}/{state.lighthouse.progress.total}
        </span>
      )}
      <span className="spacer" />
      {state.exporting && <span>Exporting {state.exporting}…</span>}
    </footer>
  )
}

/** Each measured page's scores, labelled by the Shopify template it stands for when it does. */
function SpeedTable({ pages, onSelectURL }: { pages: MeasuredPage[]; onSelectURL: (url: string) => void }) {
  const byTemplate = pages.some((page) => page.template)
  const path = (url: string) => {
    try {
      const parsed = new URL(url)
      return decodeURIComponent(parsed.pathname + parsed.search)
    } catch {
      return url
    }
  }
  const ms = (value?: number) => (value === undefined || value === null ? '–' : value >= 1000 ? `${(value / 1000).toFixed(1)} s` : `${Math.round(value)} ms`)
  return (
    <table className="simple speed-table">
      <thead>
        <tr>
          {byTemplate && <th>Template</th>}
          <th>Page</th>
          <th className="num">Mobile</th>
          <th className="num">Desktop</th>
          <th className="num">Mobile LCP</th>
        </tr>
      </thead>
      <tbody>
        {pages.map((page) => (
          <tr key={page.id}>
            {byTemplate && <td>{page.template ?? <span className="hint">Other</span>}</td>}
            <td>
              <a
                href={page.url}
                onClick={(event) => {
                  event.preventDefault()
                  onSelectURL(page.url)
                }}
              >
                {path(page.url)}
              </a>
            </td>
            <td className="num">
              <ScoreGauge score={page.mobile.score ?? undefined} />
            </td>
            <td className="num">
              <ScoreGauge score={page.desktop.score ?? undefined} />
            </td>
            <td className="num hint">{ms(page.mobile.lcpMs)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}
