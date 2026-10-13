import { useEffect, useMemo, useState } from 'react'
import { Link, useParams } from 'react-router'
import { api, crawlPath, type Severity as SeverityName } from '../api'
import { number, relativeDate, useEvents } from '../hooks'
import { Severity, useAction, useToast } from '../ui'

type Status = 'open' | 'ticked' | 'confirmed' | 'reopened'

interface FixItem {
  key: string
  parentKey?: string
  topic: string
  name: string
  severity: number
  kind: string
  status: Status
  firstSeen: string
  lastSeen: string
  tickedAt?: string
  confirmedAt?: string
  confirmedBy?: string
  pageCount: number
  checkURLs: string[]
}

const topicNames: Record<string, string> = {
  links: 'Links',
  images: 'Images',
  siteSettings: 'Site settings',
  duplicates: 'Duplicates',
  speed: 'Speed',
  products: 'Products',
  collections: 'Collections',
  storePages: 'Pages',
  blog: 'Blog posts',
  otherPages: 'Other pages',
  errors: 'Errors',
  warnings: 'Warnings',
  notices: 'Notices',
}
const topicOrder = Object.keys(topicNames)
const severities: SeverityName[] = ['error', 'warning', 'notice']
const statusLabels: Record<Status, string> = { open: 'To do', ticked: 'Done, to check', confirmed: 'Confirmed', reopened: 'Still there' }
const statusClass: Record<Status, string> = { open: '', ticked: 'warn', confirmed: 'ok', reopened: 'bad' }
type Filter = 'todo' | 'ticked' | 'confirmed' | 'all'
const filters: { id: Filter; label: string; shows: Status[] }[] = [
  { id: 'todo', label: 'To do', shows: ['open', 'reopened'] },
  { id: 'ticked', label: 'Done, to check', shows: ['ticked'] },
  { id: 'confirmed', label: 'Confirmed', shows: ['confirmed'] },
  { id: 'all', label: 'All', shows: ['open', 'reopened', 'ticked', 'confirmed'] },
]
/** Items shown per list before "Show more", so a store with thousands stays quick. */
const pageSize = 100

/**
 * A site's fixes, kept across crawls: tick them off as they're done, then check them — a crawl of
 * just the pages involved — to confirm each one or find it still there.
 */
export default function FixesPage() {
  const { host = '' } = useParams()
  const run = useAction()
  const toast = useToast()
  const [items, setItems] = useState<FixItem[] | null>(null)
  const [missing, setMissing] = useState(false)
  const [filter, setFilter] = useState<Filter>('todo')
  const [open, setOpen] = useState<Record<string, boolean>>({})
  const [shown, setShown] = useState<Record<string, number>>({})
  const [checking, setChecking] = useState<string | null>(null)
  const [checkProgress, setCheckProgress] = useState<{ crawled: number; total: number } | null>(null)

  const base = `/api/sites/${encodeURIComponent(host)}/fixes`
  const reload = () =>
    api
      .get<{ items: FixItem[] }>(base)
      .then((answer) => setItems(answer.items))
      .catch(() => setMissing(true))
  useEffect(() => {
    reload()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [host])

  useEvents(checking ? `${crawlPath(checking)}/events` : null, {
    progress: (update: { crawled?: number; discovered?: number }) =>
      setCheckProgress({ crawled: update.crawled ?? 0, total: update.discovered ?? 0 }),
    worklist: (changes: { confirmed: number; reopened: number }) => {
      setChecking(null)
      setCheckProgress(null)
      toast(`Check finished: ${changes.confirmed} confirmed fixed, ${changes.reopened} still there.`)
      reload()
    },
  })

  const children = useMemo(() => {
    const byParent = new Map<string, FixItem[]>()
    for (const item of items ?? []) {
      if (item.parentKey) byParent.set(item.parentKey, [...(byParent.get(item.parentKey) ?? []), item])
    }
    return byParent
  }, [items])

  const counts = useMemo(() => {
    const total: Record<Status, number> = { open: 0, ticked: 0, confirmed: 0, reopened: 0 }
    for (const item of items ?? []) if (!item.parentKey) total[item.status] += 1
    return total
  }, [items])

  const shows = filters.find((entry) => entry.id === filter)!.shows
  const visible = (item: FixItem) =>
    shows.includes(item.status) || (children.get(item.key) ?? []).some((child) => shows.includes(child.status))
  const groups = useMemo(() => {
    const byTopic = new Map<string, FixItem[]>()
    for (const item of items ?? []) {
      if (item.parentKey || !visible(item)) continue
      byTopic.set(item.topic, [...(byTopic.get(item.topic) ?? []), item])
    }
    return [...byTopic.entries()].sort((a, b) => topicOrder.indexOf(a[0]) - topicOrder.indexOf(b[0]))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [items, filter, children])

  const tick = async (keys: string[], ticked: boolean) => {
    await run(() => api.post(`${base}/tick`, { keys, ticked }))
    reload()
  }

  const check = async () => {
    const started = await run(() => api.post<{ id: string }>(`${base}/check`))
    if (started) {
      setChecking(started.id)
      toast('Checking the ticked fixes: crawling just the pages involved.')
    }
  }

  if (missing) {
    return (
      <div className="page">
        <div className="page-inner stack">
          <h1>{host}</h1>
          <p className="hint">This site has no list of fixes yet. Open one of its crawls and choose Fixes to start one.</p>
        </div>
      </div>
    )
  }

  return (
    <div className="page">
      <div className="page-inner stack">
        <div className="row wrap">
          <h1>Fixes · {host}</h1>
          <span className="spacer" />
          <button className="primary" disabled={!counts.ticked || !!checking} onClick={check}>
            {checking ? 'Checking…' : `Check ${number(counts.ticked)} Ticked Fix${counts.ticked === 1 ? '' : 'es'}`}
          </button>
        </div>
        <p className="hint">
          Tick a fix once it's done, then check: Crawlspace crawls just the pages involved and confirms each one, or marks it still
          there. A full crawl of the site confirms anything else that has gone.
        </p>
        {checking && (
          <div className="card row">
            <span>
              Checking{checkProgress ? `: ${number(checkProgress.crawled)} of ${number(checkProgress.total)} pages` : '…'}
            </span>
            <span className="spacer" />
            <Link to={`/crawls/${encodeURIComponent(checking)}`}>Open the check</Link>
          </div>
        )}
        <div className="row wrap">
          {(['open', 'reopened', 'ticked', 'confirmed'] as Status[]).map((status) => (
            <span key={status} className={`chip ${statusClass[status]}`}>
              {statusLabels[status]} {number(counts[status])}
            </span>
          ))}
          <span className="spacer" />
          <div className="segmented">
            {filters.map((entry) => (
              <button key={entry.id} className={filter === entry.id ? 'on' : ''} onClick={() => setFilter(entry.id)}>
                {entry.label}
              </button>
            ))}
          </div>
        </div>
        {items && groups.length === 0 && <p className="hint">Nothing here.</p>}
        {groups.map(([topic, list]) => (
          <details className="card fix-group" key={topic} open={groups.length <= 4} style={{ padding: 0 }}>
            <summary style={{ padding: '10px 12px' }}>
              {topicNames[topic] ?? topic}
              <span className="hint" style={{ fontWeight: 400 }}>
                {number(list.length)}
              </span>
            </summary>
            {list.slice(0, shown[topic] ?? pageSize).map((item) => (
              <FixRow
                key={item.key}
                item={item}
                children={children.get(item.key) ?? []}
                open={!!open[item.key]}
                onToggle={() => setOpen({ ...open, [item.key]: !open[item.key] })}
                onTick={tick}
                base={base}
              />
            ))}
            {list.length > (shown[topic] ?? pageSize) && (
              <div className="fix-row">
                <button className="small" onClick={() => setShown({ ...shown, [topic]: (shown[topic] ?? pageSize) + pageSize * 5 })}>
                  Show more ({number(list.length - (shown[topic] ?? pageSize))} left)
                </button>
              </div>
            )}
          </details>
        ))}
      </div>
    </div>
  )
}

function FixRow({
  item,
  children,
  open,
  onToggle,
  onTick,
  base,
}: {
  item: FixItem
  children: FixItem[]
  open: boolean
  onToggle: () => void
  onTick: (keys: string[], ticked: boolean) => void
  base: string
}) {
  const [details, setDetails] = useState<Record<string, string>>({})
  const loadDetails = (key: string) =>
    !details[key] &&
    api
      .get<{ message: string }>(`${base}/details?key=${encodeURIComponent(key)}`)
      .then((answer) => setDetails((current) => ({ ...current, [key]: answer.message })))
  useEffect(() => {
    if (open && children.length === 0) loadDetails(item.key)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open])

  return (
    <div className="fix-row-group">
      <div className="fix-row">
        <TickBox item={item} onTick={onTick} />
        <button className="plain fix-name" onClick={onToggle} title="Show what's wrong and how to fix it">
          {open ? '▾' : '▸'} {item.name}
        </button>
        <Severity severity={severities[item.severity] ?? 'notice'} />
        <span className="hint">
          {children.length > 0
            ? `${children.length} issue${children.length === 1 ? '' : 's'}`
            : `${number(item.pageCount)} page${item.pageCount === 1 ? '' : 's'}`}
        </span>
        <span className={`chip ${statusClass[item.status]}`} title={statusTitle(item)}>
          {statusLabels[item.status]}
        </span>
      </div>
      {open && children.length > 0 && (
        <div className="fix-children">
          {children.map((child) => (
            <div key={child.key}>
              <div className="fix-row">
                <TickBox item={child} onTick={onTick} />
                <button className="plain fix-name" onClick={() => loadDetails(child.key)}>
                  {child.name}
                </button>
                <Severity severity={severities[child.severity] ?? 'notice'} />
                <span className={`chip ${statusClass[child.status]}`} title={statusTitle(child)}>
                  {statusLabels[child.status]}
                </span>
              </div>
              {details[child.key] && <Markdown text={details[child.key]} />}
            </div>
          ))}
        </div>
      )}
      {open && children.length === 0 && (details[item.key] ? <Markdown text={details[item.key]} /> : <p className="hint fix-detail">Loading…</p>)}
    </div>
  )
}

function TickBox({ item, onTick }: { item: FixItem; onTick: (keys: string[], ticked: boolean) => void }) {
  return (
    <input
      type="checkbox"
      title={item.status === 'confirmed' ? 'Confirmed fixed' : item.status === 'ticked' ? 'Untick' : 'Mark as done'}
      checked={item.status === 'ticked' || item.status === 'confirmed'}
      disabled={item.status === 'confirmed'}
      onChange={(event) => onTick([item.key], event.target.checked)}
    />
  )
}

function statusTitle(item: FixItem) {
  if (item.status === 'confirmed' && item.confirmedBy) return `Confirmed by ${item.confirmedBy}${item.confirmedAt ? `, ${relativeDate(item.confirmedAt)}` : ''}`
  if (item.status === 'ticked' && item.tickedAt) return `Ticked ${relativeDate(item.tickedAt)}; a check will confirm it`
  return `First found in ${item.firstSeen}; last seen in ${item.lastSeen}`
}

/** The fix's description: the Markdown the ClickUp export writes, shown as it would be there. */
function Markdown({ text }: { text: string }) {
  return <div className="fix-detail markdown" dangerouslySetInnerHTML={{ __html: markdown(text) }} />
}

const escapeHTML = (text: string) => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')

/** Enough Markdown for the descriptions: paragraphs, bullets, tables, headings, bold, italics, code and links. */
export function markdown(source: string): string {
  const inline = (text: string) =>
    escapeHTML(text)
      .replace(/\\\|/g, '|')
      .replace(/`([^`]+)`/g, '<code>$1</code>')
      .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
      .replace(/(^|[^*])\*([^*\s][^*]*?)\*/g, '$1<em>$2</em>')
      .replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>')
  const cells = (line: string) =>
    line
      .trim()
      .replace(/^\||\|$/g, '')
      .split(/(?<!\\)\|/)
      .map((cell) => cell.trim())
  const html: string[] = []
  const blocks = source.split(/\n{2,}/)
  for (const block of blocks) {
    const lines = block.split('\n')
    const tableStart = lines.findIndex((line) => line.trim().startsWith('|'))
    if (tableStart >= 0 && lines[tableStart + 1]?.match(/^\|?\s*-{3}/)) {
      if (tableStart > 0) html.push(`<p>${lines.slice(0, tableStart).map(inline).join('<br>')}</p>`)
      const head = cells(lines[tableStart])
      const rows = lines.slice(tableStart + 2).filter((line) => line.trim().startsWith('|')).map(cells)
      html.push(
        `<table class="simple"><thead><tr>${head.map((cell) => `<th>${inline(cell)}</th>`).join('')}</tr></thead><tbody>${rows
          .map((row) => `<tr>${row.map((cell) => `<td>${inline(cell)}</td>`).join('')}</tr>`)
          .join('')}</tbody></table>`,
      )
      continue
    }
    if (lines.some((line) => line.startsWith('- '))) {
      const lead = lines.filter((line) => !line.startsWith('- '))
      if (lead.length) html.push(`<p>${lead.map(inline).join('<br>')}</p>`)
      html.push(`<ul>${lines.filter((line) => line.startsWith('- ')).map((line) => `<li>${inline(line.slice(2))}</li>`).join('')}</ul>`)
      continue
    }
    if (block.startsWith('### ')) {
      html.push(`<h4>${inline(block.slice(4))}</h4>`)
      continue
    }
    html.push(`<p>${lines.map(inline).join('<br>')}</p>`)
  }
  return html.join('')
}
