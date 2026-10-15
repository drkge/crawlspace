import { useCallback, useEffect, useState } from 'react'
import { useNavigate, useParams, useSearchParams } from 'react-router'
import { api, crawlPath, downloadFrom, type CheckProgress, type CheckResult, type Counts, type CrawlConfig, type CrawlState, type Issue, type RowList } from '../api'
import ConfigDialog from '../components/ConfigDialog'
import { IssueBanner, Overview, Sidebar, StatusBar } from '../components/CrawlParts'
import { ClickUpDialog, CompareDialog, ReportDialog } from '../components/Dialogs'
import Inspector from '../components/Inspector'
import URLTable from '../components/URLTable'
import { number, useDebounced, useEvents, useStoredState } from '../hooks'
import { Menu, messageOf, useAction, useToast } from '../ui'

type Sheet = 'config' | 'report' | 'summary' | 'compare' | 'clickup' | null

export default function CrawlPage() {
  const id = useParams().id!
  const navigate = useNavigate()
  const run = useAction()
  const toast = useToast()
  const [params, setParams] = useSearchParams()
  const selection = params.get('view') ?? 'overview'
  const [state, setState] = useState<CrawlState | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [counts, setCounts] = useState<Counts | null>(null)
  const [rows, setRows] = useState<RowList | null>(null)
  /** What the last check found, until it's dismissed or another starts. */
  const [checkResult, setCheckResult] = useState<CheckResult | null>(null)
  const [version, setVersion] = useState(0)
  const [search, setSearch] = useState('')
  const query = useDebounced(search, 250)
  const [sort, setSort] = useState<{ column: string; ascending: boolean } | null>(null)
  const [selected, setSelected] = useState<number | null>(null)
  const [sheet, setSheet] = useState<Sheet>(null)
  const [showInspector, setShowInspector] = useStoredState('inspector', true)
  const [inspectorWidth, setInspectorWidth] = useStoredState('inspectorWidth', 380)
  const path = crawlPath(id)

  const loadState = useCallback(
    () =>
      api
        .get<CrawlState>(path)
        .then((loaded) => (setState(loaded), setError(null)))
        .catch((failure) => setError(messageOf(failure))),
    [path],
  )
  const loadCounts = useCallback(() => api.get<Counts>(`${path}/counts`).then(setCounts).catch(() => {}), [path])

  useEffect(() => {
    setState(null)
    setCounts(null)
    setRows(null)
    setSelected(null)
    setCheckResult(null)
    loadState()
    loadCounts()
  }, [loadState, loadCounts])

  // Rows for the table on screen. Refetched when the crawl's data moves on.
  useEffect(() => {
    if (selection === 'overview') {
      setRows(null)
      return
    }
    const search = new URLSearchParams({ selection, q: query })
    if (sort) {
      search.set('sort', sort.column)
      search.set('asc', String(sort.ascending))
    }
    let current = true
    api
      .get<RowList>(`${path}/rows?${search}`)
      .then((list) => current && setRows(list))
      .catch((failure) => current && toast(messageOf(failure), true))
    return () => {
      current = false
    }
  }, [path, selection, query, sort, version, toast])

  const dataChanged = () => {
    setVersion((value) => value + 1)
    loadCounts()
  }

  useEvents(
    `${path}/events`,
    {
      state: setState,
      progress: (progress) => setState((current) => (current ? { ...current, progress } : current)),
      lighthouse: (progress) =>
        setState((current) => (current ? { ...current, lighthouse: { ...current.lighthouse, running: true, progress } } : current)),
      check: (progress: CheckProgress) =>
        setState((current) => (current ? { ...current, check: { ...current.check, running: true, progress } } : current)),
      'check-finished': (result: CheckResult) => setCheckResult(result),
      changed: dataChanged,
      error: (event) => toast(event.message, true),
    },
    () => {
      loadState()
      dataChanged()
    },
  )

  const select = (next: string) => {
    setParams(next === 'overview' ? {} : { view: next })
    setSort(null)
    setSelected(null)
  }

  const control = (action: string) => run(async () => setState(await api.post<CrawlState>(`${path}/${action}`)))

  const runLighthouse = async (body: { top?: number; rowIds?: number[] }) => {
    const next = await run(() => api.post<CrawlState>(`${path}/lighthouse`, body))
    if (next) {
      setState(next)
      toast(body.rowIds ? `Measuring ${body.rowIds.length === 1 ? 'the page' : `${body.rowIds.length} pages`} on mobile and desktop…` : `Lighthouse is measuring ${next.speedPlan}…`)
    }
  }

  /** Checks pages again for one issue, in place: it leaves the pages it's resolved on, and nothing else changes. */
  const checkIssue = async (ids: number[], code: string, title: string) => {
    if (ids.length > 500 && !window.confirm(`Check all ${number(ids.length)} pages for ${title}? Each is fetched again.`)) return
    const next = await run(() => api.post<CrawlState>(`${path}/check`, { rowIds: ids, issue: code }))
    if (next) {
      setState(next)
      setCheckResult(null)
      toast(`Checking ${ids.length === 1 ? 'the page' : `${number(ids.length)} pages`} for ${title}…`)
    }
  }

  const checkDisabled = !state || state.isRunning || state.check.running

  const selectURL = async (url: string) => {
    const found = await api.get<{ id: number | null }>(`${path}/lookup?url=${encodeURIComponent(url)}`).catch(() => null)
    if (found?.id) {
      if (selection === 'overview') select('filter:all')
      setSelected(found.id)
    } else {
      window.open(url, '_blank', 'noopener')
    }
  }

  const exportTable = (format: 'csv' | 'xlsx', view: string) => {
    const search = new URLSearchParams({ format, selection: view, q: view === selection ? query : '' })
    if (sort && view === selection) {
      search.set('sort', sort.column)
      search.set('asc', String(sort.ascending))
    }
    run(() => downloadFrom('GET', `${path}/export/table?${search}`))
  }

  // Keyboard shortcuts from the Mac app, where the browser leaves them free.
  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      if (!state || !(event.metaKey || event.ctrlKey)) return
      const target = event.target as HTMLElement
      if (['INPUT', 'TEXTAREA', 'SELECT'].includes(target.tagName)) return
      if (event.key === '.' && state.isRunning) {
        event.preventDefault()
        control('stop')
      } else if (event.shiftKey && event.key.toLowerCase() === 'k') {
        event.preventDefault()
        setSheet('clickup')
      } else if (event.shiftKey && event.key.toLowerCase() === 'e') {
        event.preventDefault()
        setSheet('report')
      } else if (event.key.toLowerCase() === 'e' && !event.shiftKey && selection !== 'overview') {
        event.preventDefault()
        exportTable('csv', selection)
      }
    }
    window.addEventListener('keydown', key)
    return () => window.removeEventListener('keydown', key)
  })

  if (error) {
    return (
      <div className="empty">
        <div className="stack">
          <p className="error-text">{error}</p>
          <button onClick={() => navigate('/')}>Back to crawls</button>
        </div>
      </div>
    )
  }
  if (!state) return <div className="empty">Opening…</div>

  const issueCount = rows?.issue ? (counts?.issues.find((entry) => entry.issue.code === rows.issue!.code)?.count ?? rows.ids.length) : 0
  const busy = state.isRunning || state.isPaused

  const exportMenu = (
    <Menu label="Export">
      <button onClick={() => setSheet('clickup')}>Issues to ClickUp…</button>
      <hr />
      <button onClick={() => exportTable('csv', 'filter:internalHTML')}>Internal HTML as CSV</button>
      <button onClick={() => exportTable('xlsx', 'filter:internalHTML')}>Internal HTML as Excel</button>
      {selection !== 'overview' && selection !== 'filter:internalHTML' && (
        <>
          <button onClick={() => exportTable('csv', selection)}>This table as CSV</button>
          <button onClick={() => exportTable('xlsx', selection)}>This table as Excel</button>
        </>
      )}
      <hr />
      <button onClick={() => setSheet('summary')}>Client Summary…</button>
      <button onClick={() => setSheet('report')}>Audit Report…</button>
    </Menu>
  )

  const startInspectorResize = (event: React.MouseEvent) => {
    event.preventDefault()
    const startX = event.clientX
    const start = inspectorWidth
    const move = (moveEvent: MouseEvent) => setInspectorWidth(Math.min(720, Math.max(260, start - (moveEvent.clientX - startX))))
    const up = () => {
      window.removeEventListener('mousemove', move)
      window.removeEventListener('mouseup', up)
    }
    window.addEventListener('mousemove', move)
    window.addEventListener('mouseup', up)
  }

  return (
    <div className="crawl">
      <div className="toolbar">
        <span className="title" title={state.name}>
          {state.site} <span className="hint" style={{ fontWeight: 400 }}>· {state.name}</span>
        </span>
        <span className="spacer" />
        {state.canStart && (
          <button className="primary" onClick={() => control('start')}>
            {state.status === 'new' ? 'Start Crawl' : 'Resume Crawl'}
          </button>
        )}
        {state.isRunning && <button onClick={() => control('pause')}>Pause</button>}
        {state.isPaused && (
          <button className="primary" onClick={() => control('resume')}>
            Resume
          </button>
        )}
        {busy && <button onClick={() => control('stop')}>Stop</button>}
        {state.lighthouse.running && <button onClick={() => run(async () => setState(await api.delete<CrawlState>(`${path}/lighthouse`)))}>Stop Lighthouse</button>}
        <button onClick={() => setSheet('config')}>Configuration</button>
        <Menu label="Crawl">
          <button onClick={() => setSheet('compare')}>Compare with Earlier Crawl…</button>
          <button disabled={busy} onClick={() => control('analyse')}>
            Run Crawl Analysis Again
          </button>
          <button
            disabled={busy || state.lighthouse.running}
            onClick={() => runLighthouse({ top: state.config.lighthouseTopPages || 25 })}
          >
            Run Speed Check ({state.speedPlan})
          </button>
          <hr />
          <button
            disabled={busy}
            onClick={async () => {
              const next = await run(() => api.post<CrawlState>(`${path}/rescan`))
              if (next) navigate(`/crawls/${encodeURIComponent(next.id)}`)
            }}
          >
            Rescan Into a New Crawl
          </button>
          <button onClick={() => run(() => api.post(`${path}/reveal`))}>Show in Finder</button>
        </Menu>
        {exportMenu}
        <button className="plain" title="Show or hide the inspector" onClick={() => setShowInspector(!showInspector)}>
          ◧
        </button>
      </div>

      {checkResult ? (
        <div className="check-result">
          <div className="check-result-lines">
            <span>{checkSummary(checkResult)}</span>
            {checkResult.elsewhere.length > 0 && (
              <span className="row" style={{ gap: 8 }}>
                <span>
                  {number(checkResult.elsewhere.length)} other {checkResult.elsewhere.length === 1 ? 'page still has' : 'pages still have'} it: the same
                  fix may have reached {checkResult.elsewhere.length === 1 ? 'it' : 'them'}.
                </span>
                <button
                  className="small"
                  disabled={checkDisabled}
                  onClick={() => checkIssue(checkResult.elsewhere, checkResult.code, checkResult.title)}
                >
                  {checkResult.elsewhere.length === 1 ? 'Check It' : `Check Those ${number(checkResult.elsewhere.length)}`}
                </button>
              </span>
            )}
          </div>
          <button className="plain" title="Dismiss" onClick={() => setCheckResult(null)}>
            ×
          </button>
        </div>
      ) : (
        <div />
      )}

      <div className="crawl-body" style={{ gridTemplateColumns: `250px 1fr ${showInspector ? `${inspectorWidth}px` : ''}` }}>
        <Sidebar counts={counts} selection={selection} onSelect={select} />
        {selection === 'overview' ? (
          <Overview
            counts={counts}
            state={state}
            onSelect={select}
            onSelectURL={selectURL}
            onRunLighthouse={() => runLighthouse({ top: state.config.lighthouseTopPages || 25 })}
            exportMenu={null}
            version={version}
          />
        ) : (
          <div className="main">
            <div className="table-toolbar">
              <strong style={{ overflow: 'hidden', textOverflow: 'ellipsis' }} title={rows?.title}>
                {rows?.title ?? ''}
              </strong>
              <span className="hint">{rows ? `${number(rows.ids.length)} URLs` : ''}</span>
              <span className="spacer" />
              {rows?.issue && !rows.issue.code.startsWith('lh_') && rows.ids.length > 0 && (
                <button
                  className="small"
                  disabled={checkDisabled}
                  title="Fetch each again to see whether this issue is resolved: the pages it's resolved on leave the list"
                  onClick={() => checkIssue(rows.ids, rows.issue!.code, issueTitle(rows.issue!))}
                >
                  Check all {number(rows.ids.length)}
                </button>
              )}
              <input type="search" placeholder="Search URL, title or H1" value={search} onChange={(event) => setSearch(event.target.value)} />
            </div>
            {rows?.issue ? <IssueBanner issue={rows.issue} count={issueCount} /> : <div />}
            {rows ? (
              <URLTable
                crawlID={id}
                ids={rows.ids}
                columns={rows.columns}
                version={version}
                sort={sort}
                onSort={setSort}
                selected={selected}
                onSelect={setSelected}
                onRunLighthouse={(ids) => runLighthouse({ rowIds: ids })}
                onCheck={rows.issue && !rows.issue.code.startsWith('lh_') ? (ids) => checkIssue(ids, rows.issue!.code, issueTitle(rows.issue!)) : undefined}
              />
            ) : (
              <div className="empty">Loading…</div>
            )}
          </div>
        )}
        {showInspector && (
          <aside className="inspector">
            <div className="divider" onMouseDown={startInspectorResize} />
            <Inspector
              crawlID={id}
              rowID={selected}
              version={version}
              lighthouseRunning={state.lighthouse.running}
              checkDisabled={checkDisabled}
              onCheck={(ids, issue) => checkIssue(ids, issue.code, issueTitle(issue))}
              onSelectURL={selectURL}
              onRunLighthouse={(ids) => runLighthouse({ rowIds: ids })}
            />
          </aside>
        )}
      </div>

      <StatusBar state={state} />

      {sheet === 'config' && (
        <ConfigDialog
          config={state.config}
          editable={state.isConfigurable ? 'all' : 'speed'}
          onCancel={() => setSheet(null)}
          onSave={async (config: CrawlConfig) => {
            setSheet(null)
            await run(async () => setState(await api.put<CrawlState>(`${path}/config`, { config })), 'Settings saved')
          }}
        />
      )}
      {sheet === 'report' && <ReportDialog crawlID={id} site={state.site} kind="audit" onClose={() => setSheet(null)} />}
      {sheet === 'summary' && <ReportDialog crawlID={id} site={state.site} kind="summary" onClose={() => setSheet(null)} />}
      {sheet === 'compare' && <CompareDialog crawlID={id} site={state.site} onClose={() => setSheet(null)} />}
      {sheet === 'clickup' && <ClickUpDialog crawlID={id} onClose={() => setSheet(null)} />}
    </div>
  )
}

/** "Canonicals: Canonicalised", as the sidebar lists it. */
function issueTitle(issue: Issue) {
  return `${issue.category}: ${issue.title}`
}

/** "Canonicals: Canonicalised is resolved on 3 of the 7 pages checked, and still on 4." */
function checkSummary(result: CheckResult) {
  const slowDown = (pages: number) =>
    `the site asked to slow down, so ${pages === 1 ? (result.checked ? "it's" : "the page is") : result.checked ? "they're" : 'the pages are'} as before. Try again in a minute.`
  if (result.checked === 0) return `${result.title} wasn't checked: ${slowDown(result.unanswered)}`
  let text =
    result.checked === 1
        ? `${result.title} is ${result.resolved ? 'resolved on the page' : 'still on the page'}.`
        : !result.resolved
          ? `${result.title} is still on all ${number(result.checked)} pages checked.`
          : !result.remaining
            ? `${result.title} is resolved on all ${number(result.checked)} pages checked.`
            : `${result.title} is resolved on ${number(result.resolved)} of the ${number(result.checked)} pages checked, and still on ${number(result.remaining)}.`
  if (result.unanswered) text += ` ${number(result.unanswered)} ${result.unanswered === 1 ? "page wasn't" : "pages weren't"} checked: ${slowDown(result.unanswered)}`
  return text
}
