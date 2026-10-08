import { useEffect, useMemo, useState } from 'react'
import { Link, useNavigate } from 'react-router'
import { api, crawlPath, type About, type CrawlConfig, type CrawlListItem, type CrawlState } from '../api'
import ConfigDialog from '../components/ConfigDialog'
import { number, relativeDate, useStoredState } from '../hooks'
import { Confirm, Menu, useAction } from '../ui'

const statusText: Record<string, string> = {
  new: 'Not started',
  running: 'Running',
  paused: 'Paused · can be resumed',
  stopped: 'Stopped · can be resumed',
  completed: 'Completed',
}

export default function StartPage({ about }: { about: About | null }) {
  const navigate = useNavigate()
  const run = useAction()
  const [crawls, setCrawls] = useState<CrawlListItem[] | null>(null)
  const [config, setConfig] = useState<CrawlConfig | null>(null)
  const [savedDraft, setSavedDraft] = useStoredState<Partial<CrawlConfig> | null>('draftConfig', null)
  const [listText, setListText] = useState('')
  const [configuring, setConfiguring] = useState(false)
  const [starting, setStarting] = useState(false)
  const [trashing, setTrashing] = useState<CrawlListItem | null>(null)

  const reload = () => api.get<CrawlListItem[]>('/api/crawls').then(setCrawls)

  useEffect(() => {
    reload()
    api.get<CrawlConfig>('/api/defaults').then((defaults) => {
      // The settings last used for a new crawl carry over, apart from where to start.
      setConfig({ ...defaults, ...(savedDraft ?? {}), startURL: '', listURLs: [], sitemapURLs: [] })
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => {
    const listener = () => reload()
    window.addEventListener('crawlspace:crawls', listener)
    return () => window.removeEventListener('crawlspace:crawls', listener)
  }, [])

  const groups = useMemo(() => {
    const bySite = new Map<string, CrawlListItem[]>()
    for (const crawl of crawls ?? []) {
      const site = crawl.site || 'Unreadable crawls'
      bySite.set(site, [...(bySite.get(site) ?? []), crawl])
    }
    return [...bySite.entries()]
  }, [crawls])

  if (!config) return <div className="page" />

  const update = (patch: Partial<CrawlConfig>) => setConfig({ ...config, ...patch })

  const start = async () => {
    const lines = listText
      .split('\n')
      .map((line) => line.trim())
      .filter(Boolean)
    let next = { ...config }
    if (next.mode === 'list') next.listURLs = lines
    if (next.mode === 'sitemap') next.sitemapURLs = lines
    if (!next.startURL.trim() && lines.length) next.startURL = lines[0]
    if (next.startURL && !/^https?:\/\//i.test(next.startURL.trim())) next.startURL = `https://${next.startURL.trim()}`
    setStarting(true)
    const state = await run(() => api.post<CrawlState>('/api/crawls', { config: next }))
    setStarting(false)
    if (state) {
      const { startURL: _s, listURLs: _l, sitemapURLs: _m, ...rest } = next
      setSavedDraft(rest)
      navigate(`/crawls/${encodeURIComponent(state.id)}`)
    }
  }

  const rescan = async (crawl: CrawlListItem) => {
    const state = await run(() => api.post<CrawlState>(`${crawlPath(crawl.id)}/rescan`))
    if (state) navigate(`/crawls/${encodeURIComponent(state.id)}`)
  }

  const summary = [
    `${config.concurrency} connection${config.concurrency === 1 ? '' : 's'}${config.automaticConcurrency ? ' (automatic)' : ''}`,
    config.respectRobotsTxt ? 'respecting robots.txt' : 'ignoring robots.txt',
    `up to ${number(config.maxURLs)} URLs`,
    config.renderJavaScript ? 'rendering JavaScript' : null,
    config.lighthouseTopPages > 0 ? `Lighthouse on ${config.lighthouseTopPages} pages` : 'no Lighthouse',
    config.platformProfile === 'automatic' ? null : `${config.platformProfile} profile`,
  ]
    .filter(Boolean)
    .join(' · ')

  const lowDisk = about?.freeDiskGigabytes !== undefined && about.freeDiskGigabytes < 20

  return (
    <div className="page">
      <div className="page-inner">
        <section className="start-hero">
          <h1>New crawl</h1>
          <div className="segmented" role="tablist">
            {(['spider', 'list', 'sitemap'] as const).map((mode) => (
              <button key={mode} className={config.mode === mode ? 'on' : ''} onClick={() => update({ mode })}>
                {mode === 'spider' ? 'Spider' : mode === 'list' ? 'List of URLs' : 'XML Sitemap'}
              </button>
            ))}
          </div>
          {config.mode !== 'spider' && (
            <textarea
              rows={5}
              placeholder={config.mode === 'list' ? 'One URL per line' : 'One sitemap URL per line'}
              value={listText}
              onChange={(event) => setListText(event.target.value)}
            />
          )}
          <form
            className="start-url"
            onSubmit={(event) => {
              event.preventDefault()
              start()
            }}
          >
            <input
              type="text"
              autoFocus
              placeholder={config.mode === 'spider' ? 'https://www.example.com/' : 'Start URL (optional: defaults to the first URL above)'}
              value={config.startURL}
              onChange={(event) => update({ startURL: event.target.value })}
            />
            <button className="primary" type="submit" disabled={starting}>
              {starting ? 'Checking the site…' : 'Start Crawl'}
            </button>
          </form>
          <div className="row hint">
            <button className="plain small" onClick={() => setConfiguring(true)}>
              Configuration…
            </button>
            <span>{summary}</span>
          </div>
          {lowDisk && (
            <div className="hint error-text">
              Only {about!.freeDiskGigabytes!.toFixed(0)} GB free on this Mac. Large crawls can use several gigabytes.
            </div>
          )}
        </section>

        <section>
          <div className="row" style={{ marginBottom: 8 }}>
            <h2>Recent crawls</h2>
            <span className="hint">
              {crawls && `${crawls.length} crawl${crawls.length === 1 ? '' : 's'} of ${groups.length} site${groups.length === 1 ? '' : 's'}`}
            </span>
          </div>
          {crawls?.length === 0 && <p className="hint">Nothing crawled yet. Enter a site above to start.</p>}
          {groups.map(([site, items], index) => (
            <details className="site-group card" key={site} open={index < 6} style={{ padding: 0 }}>
              <summary style={{ padding: '10px 12px' }}>
                {site}
                <span className="hint" style={{ fontWeight: 400 }}>
                  {items.length} crawl{items.length === 1 ? '' : 's'}
                </span>
              </summary>
              {items.map((crawl) => (
                <div className="crawl-row" key={crawl.id} onDoubleClick={() => navigate(`/crawls/${encodeURIComponent(crawl.id)}`)}>
                  {crawl.isRunning && <span className="dot running" title="Running" />}
                  <div className="name">
                    <Link to={`/crawls/${encodeURIComponent(crawl.id)}`}>{relativeDate(crawl.modified)}</Link>
                    <div className="hint">
                      {crawl.readable ? `${statusText[crawl.status] ?? crawl.status} · ${number(crawl.crawled)} URLs` : "Couldn't be read"}
                      {' · '}
                      {crawl.name}
                    </div>
                  </div>
                  <button className="small" onClick={() => navigate(`/crawls/${encodeURIComponent(crawl.id)}`)}>
                    Open
                  </button>
                  <button className="small" disabled={crawl.isRunning || !crawl.readable} onClick={() => rescan(crawl)}>
                    Rescan
                  </button>
                  <Menu label="More" className="small plain">
                    <button onClick={() => run(() => api.post(`${crawlPath(crawl.id)}/reveal`))}>Show in Finder</button>
                    <hr />
                    <button className="danger" disabled={crawl.isRunning} onClick={() => setTrashing(crawl)}>
                      Move to Trash…
                    </button>
                  </Menu>
                </div>
              ))}
            </details>
          ))}
        </section>
      </div>

      {configuring && (
        <ConfigDialog
          config={config}
          editable="all"
          onCancel={() => setConfiguring(false)}
          onSave={(next) => {
            setConfig(next)
            setConfiguring(false)
          }}
        />
      )}
      {trashing && (
        <Confirm
          title={`Move this crawl to the Trash?`}
          message={`${trashing.name} goes to the Trash, where you can still restore it from Finder.`}
          action="Move to Trash"
          danger
          onCancel={() => setTrashing(null)}
          onConfirm={async () => {
            const crawl = trashing
            setTrashing(null)
            await run(() => api.delete(crawlPath(crawl.id)))
            reload()
          }}
        />
      )}
    </div>
  )
}
