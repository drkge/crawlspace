import { useEffect, useState } from 'react'
import { api, crawlPath, type Inspector as InspectorData, type LighthouseRun, type LinkRow } from '../api'
import { isNofollow, linkPositions, linkTypes, number, relativeDate, useStoredState } from '../hooks'
import { ScoreGauge, Severity, messageOf, useToast } from '../ui'

type Tab = 'details' | 'issues' | 'links' | 'speed' | 'source'

/** Everything about one URL, beside the table. */
export default function Inspector(props: {
  crawlID: string
  rowID: number | null
  version: number
  lighthouseRunning: boolean
  onSelectURL: (url: string) => void
  onRunLighthouse: (ids: number[]) => void
}) {
  const [data, setData] = useState<InspectorData | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [tab, setTab] = useStoredState<Tab>('inspectorTab', 'details')

  useEffect(() => {
    if (props.rowID === null) {
      setData(null)
      return
    }
    let current = true
    api
      .get<InspectorData>(`${crawlPath(props.crawlID)}/rows/${props.rowID}`)
      .then((loaded) => current && (setData(loaded), setError(null)))
      .catch((failure) => current && setError(messageOf(failure)))
    return () => {
      current = false
    }
  }, [props.crawlID, props.rowID, props.version])

  if (props.rowID === null) return <div className="empty">Select a URL to see everything about it.</div>
  if (error) return <div className="empty error-text">{error}</div>
  if (!data) return <div className="empty">Loading…</div>

  const statusClass = !data.statusCode ? 'bad' : data.statusCode >= 400 ? 'bad' : data.statusCode >= 300 ? 'warn' : 'ok'
  return (
    <>
      <div className="inspector-header">
        <div className="url">{data.url}</div>
        <div className="row wrap">
          <span className={`chip ${statusClass}`}>{data.statusCode ? `${data.statusCode} ${data.status}` : data.status}</span>
          {data.indexability && <span className={`chip ${data.indexable ? 'ok' : 'warn'}`}>{data.indexability}</span>}
          <span className="spacer" />
          <a className="button small" href={data.url} target="_blank" rel="noopener noreferrer">
            Open ↗
          </a>
        </div>
      </div>
      <div className="tabs" role="tablist">
        {(['details', 'issues', 'links', 'speed', 'source'] as const).map((name) => (
          <button key={name} className={tab === name ? 'on' : ''} onClick={() => setTab(name)}>
            {name === 'issues' ? `Issues ${data.issues.length ? `(${data.issues.length})` : ''}` : name[0].toUpperCase() + name.slice(1)}
          </button>
        ))}
      </div>
      <div className="inspector-body">
        {tab === 'details' && <Details data={data} />}
        {tab === 'issues' && <Issues data={data} onSelectURL={props.onSelectURL} />}
        {tab === 'links' && <Links data={data} onSelectURL={props.onSelectURL} />}
        {tab === 'speed' && (
          <Speed data={data} crawlID={props.crawlID} running={props.lighthouseRunning} onRun={() => props.onRunLighthouse([data.id])} />
        )}
        {tab === 'source' && <Source data={data} crawlID={props.crawlID} />}
      </div>
    </>
  )
}

function KeyValues({ pairs }: { pairs: { name: string; value: string }[] }) {
  return (
    <dl className="kv">
      {pairs.map((pair, index) => (
        <div key={index} style={{ display: 'contents' }}>
          <dt>{pair.name}</dt>
          <dd>{pair.value}</dd>
        </div>
      ))}
    </dl>
  )
}

function Details({ data }: { data: InspectorData }) {
  const serp = data.serp
  return (
    <>
      {serp && (
        <section className="stack" style={{ gap: 6 }}>
          <h3>Search result preview</h3>
          <div className="serp">
            <span className="hint">{serp.host}</span>
            <span className="serp-title">{serp.title ?? '(no title)'}</span>
            <span className="serp-desc">{serp.description ?? '(no meta description — Google will write a snippet itself)'}</span>
          </div>
          <div className="row hint">
            {serp.titleLength !== undefined && (
              <span style={{ color: serp.titleTooWide ? 'var(--warning)' : undefined }}>
                Title {serp.titleLength} chars · {Math.round(serp.titlePixels ?? 0)} px
              </span>
            )}
            {!!serp.descriptionLength && (
              <span style={{ color: serp.descriptionTooWide ? 'var(--warning)' : undefined }}>
                Description {serp.descriptionLength} chars · {Math.round(serp.descriptionPixels ?? 0)} px
              </span>
            )}
          </div>
        </section>
      )}
      <KeyValues pairs={data.details} />
      {data.hreflang.length > 0 && (
        <section className="stack" style={{ gap: 6 }}>
          <h3>Hreflang</h3>
          <table className="simple">
            <tbody>
              {data.hreflang.map((entry, index) => (
                <tr key={index}>
                  <td className="mono">{entry.lang}</td>
                  <td style={{ wordBreak: 'break-all' }}>{entry.url}</td>
                  <td className="num" style={{ color: entry.statusCode && entry.statusCode >= 300 ? 'var(--error)' : undefined }}>
                    {entry.statusCode}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}
      {data.extractions.length > 0 && (
        <section className="stack" style={{ gap: 6 }}>
          <h3>Custom extraction</h3>
          <KeyValues pairs={data.extractions} />
        </section>
      )}
      {data.nearDuplicates.length > 0 && (
        <section className="stack" style={{ gap: 6 }}>
          <h3>Near duplicates</h3>
          <table className="simple">
            <tbody>
              {data.nearDuplicates.map((duplicate) => (
                <tr key={duplicate.url}>
                  <td className="num">{Math.round(duplicate.similarity * 100)}%</td>
                  <td style={{ wordBreak: 'break-all' }}>{duplicate.url}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}
      {data.structuredData.length > 0 && (
        <section className="stack" style={{ gap: 6 }}>
          <h3>Structured data</h3>
          {data.structuredData.map((block, index) => (
            <div key={index}>
              <div>{block.types || '(no @type)'}</div>
              {block.error && <div className="error-text hint">{block.error}</div>}
            </div>
          ))}
        </section>
      )}
      {data.headers.length > 0 && (
        <section className="stack" style={{ gap: 6 }}>
          <h3>Response headers</h3>
          <KeyValues pairs={data.headers} />
        </section>
      )}
    </>
  )
}

function Issues({ data, onSelectURL }: { data: InspectorData; onSelectURL: (url: string) => void }) {
  if (!data.issues.length) return <p className="hint">No issues on this URL.</p>
  return (
    <>
      {data.issues.map(({ issue, evidence }) => (
        <div className="issue-card" key={issue.code}>
          <div className="head">
            <Severity severity={issue.severity} />
            <span>
              {issue.category}: {issue.title}
            </span>
          </div>
          <div className="hint">{issue.description}</div>
          {evidence && evidence.items.length > 0 && (
            <ul className="evidence">
              {evidence.items.map((item, index) => (
                <li key={index}>
                  {item.url ? (
                    <a
                      href={item.url}
                      onClick={(event) => {
                        event.preventDefault()
                        onSelectURL(item.url!)
                      }}
                    >
                      {item.text}
                    </a>
                  ) : (
                    item.text
                  )}
                  {item.position !== undefined && item.position > 0 && <span className="chip" style={{ marginLeft: 6 }}>{linkPositions[item.position]}</span>}
                  {!!item.pagesWithSameLink && item.pagesWithSameLink > 1 && (
                    <span className="hint"> · on {number(item.pagesWithSameLink)} pages</span>
                  )}
                </li>
              ))}
              {evidence.more > 0 && <li className="hint">…and {number(evidence.more)} more</li>}
            </ul>
          )}
          {evidence?.isTemplateWide && <div className="chip warn">Fix once in the theme: it's on every page that uses this template</div>}
          <div>
            <strong>Fix: </strong>
            {evidence?.fix || issue.howToFix}
          </div>
        </div>
      ))}
    </>
  )
}

function Links({ data, onSelectURL }: { data: InspectorData; onSelectURL: (url: string) => void }) {
  const list = (title: string, links: LinkRow[]) => (
    <section className="stack" style={{ gap: 6 }}>
      <h3>
        {title} ({number(links.length)}
        {links.length === 1000 ? '+' : ''})
      </h3>
      <div className="link-list">
        {links.map((link, index) => (
          <div key={index}>
            <a
              href={link.url}
              onClick={(event) => {
                event.preventDefault()
                onSelectURL(link.url)
              }}
              style={{ wordBreak: 'break-all' }}
            >
              {link.url}
            </a>
            <span className="hint" style={{ color: link.statusCode && link.statusCode >= 400 ? 'var(--error)' : undefined }}>
              {link.statusCode ?? ''}
            </span>
            <span className="meta">
              {linkTypes[link.type] ?? 'Link'}
              {isNofollow(link.flags) ? ' · nofollow' : ''}
              {link.text ? ` · “${link.text}”` : ''}
            </span>
          </div>
        ))}
        {!links.length && <span className="hint">None.</span>}
      </div>
    </section>
  )
  return (
    <>
      {list('Inlinks', data.inlinks)}
      {list('Outlinks', data.outlinks)}
    </>
  )
}

function Speed(props: { data: InspectorData; crawlID: string; running: boolean; onRun: () => void }) {
  const { data } = props
  if (!data.isPage) return <p className="hint">Lighthouse measures pages, not files.</p>
  const runs: Record<string, LighthouseRun | undefined> = Object.fromEntries(data.lighthouse.map((run) => [run.device, run]))
  const ms = (value?: number) => (value === undefined || value === null ? '–' : value >= 1000 ? `${(value / 1000).toFixed(1)} s` : `${Math.round(value)} ms`)
  return (
    <>
      <div className="row">
        <button className="small primary" disabled={props.running} onClick={props.onRun}>
          {props.running ? 'Lighthouse is running…' : data.lighthouse.length ? 'Measure again' : 'Run Lighthouse'}
        </button>
        <span className="hint">Mobile and desktop, about half a minute.</span>
      </div>
      {!data.lighthouse.length && <p className="hint">Lighthouse hasn't measured this page yet.</p>}
      {data.lighthouse.find((run) => run.template) && (
        <p className="hint">
          Measured as the store's <strong>{data.lighthouse.find((run) => run.template)!.template}</strong> page: what's slow here is
          likely slow on every page built from the same theme template.
        </p>
      )}
      {data.lighthouse.length > 0 && (
        <div className="scores">
          {(['mobile', 'desktop'] as const).map((device) => {
            const run = runs[device]
            return (
              <div className="score" key={device}>
                <div className="row">
                  <strong>{device === 'mobile' ? 'Mobile' : 'Desktop'}</strong>
                  <span className="spacer" />
                  <ScoreGauge score={run?.metrics.score ?? undefined} />
                </div>
                {run?.error && <div className="hint error-text">{run.error}</div>}
                {run && (
                  <dl className="kv">
                    <dt>LCP</dt>
                    <dd>{ms(run.metrics.lcpMs)}</dd>
                    <dt>CLS</dt>
                    <dd>{run.metrics.cls === undefined || run.metrics.cls === null ? '–' : run.metrics.cls.toFixed(3)}</dd>
                    <dt>TBT</dt>
                    <dd>{ms(run.metrics.tbtMs)}</dd>
                    <dt>FCP</dt>
                    <dd>{ms(run.metrics.fcpMs)}</dd>
                    <dt>Speed Index</dt>
                    <dd>{ms(run.metrics.speedIndexMs)}</dd>
                  </dl>
                )}
                {run?.hasReport && (
                  <a href={`${crawlPath(props.crawlID)}/rows/${data.id}/lighthouse/${device}`} target="_blank" rel="noopener">
                    Full Lighthouse report ↗
                  </a>
                )}
                {run && <span className="hint">{relativeDate(run.ranAt)}</span>}
              </div>
            )
          })}
        </div>
      )}
      {data.lighthouse.map(
        (run) =>
          run.opportunities.length > 0 && (
            <section className="stack" style={{ gap: 6 }} key={run.device}>
              <h3>What would help most · {run.device}</h3>
              <table className="simple">
                <tbody>
                  {run.opportunities.map((opportunity) => (
                    <tr key={opportunity.id}>
                      <td>{opportunity.title}</td>
                      <td className="num hint">{opportunity.savingsMs > 0 ? `−${ms(opportunity.savingsMs)}` : (opportunity.displayValue ?? '')}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </section>
          ),
      )}
    </>
  )
}

function Source({ data, crawlID }: { data: InspectorData; crawlID: string }) {
  const toast = useToast()
  const [which, setWhich] = useState<'html' | 'rendered'>(data.hasRawHTML ? 'html' : 'rendered')
  const [text, setText] = useState<string | null>(null)
  useEffect(() => {
    setText(null)
    if ((which === 'html' && !data.hasRawHTML) || (which === 'rendered' && !data.hasRenderedHTML)) return
    fetch(`${crawlPath(crawlID)}/rows/${data.id}/${which}`)
      .then((response) => (response.ok ? response.text() : Promise.reject(new Error(response.statusText))))
      .then(setText)
      .catch((error) => toast(messageOf(error), true))
  }, [which, data.id, crawlID, data.hasRawHTML, data.hasRenderedHTML, toast])

  if (!data.hasRawHTML && !data.hasRenderedHTML && !data.hasScreenshot) {
    return <p className="hint">Nothing stored for this URL. Turn on “Store each page's HTML” in the crawl's configuration to keep it.</p>
  }
  return (
    <>
      {data.hasScreenshot && <img src={`${crawlPath(crawlID)}/rows/${data.id}/screenshot`} alt="Screenshot of the page" style={{ maxWidth: '100%', borderRadius: 6 }} />}
      {(data.hasRawHTML || data.hasRenderedHTML) && (
        <>
          <div className="segmented">
            <button className={which === 'html' ? 'on' : ''} disabled={!data.hasRawHTML} onClick={() => setWhich('html')}>
              Raw HTML
            </button>
            <button className={which === 'rendered' ? 'on' : ''} disabled={!data.hasRenderedHTML} onClick={() => setWhich('rendered')}>
              Rendered DOM
            </button>
          </div>
          <pre className="source">{text ?? 'Loading…'}</pre>
        </>
      )}
    </>
  )
}
