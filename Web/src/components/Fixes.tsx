import { useEffect, useMemo, useState, type ReactNode } from 'react'
import { api, type Severity as SeverityName } from '../api'
import { number, relativeDate } from '../hooks'
import { Severity } from '../ui'
import { Markdown } from './Markdown'

/**
 * A site's fixes, in the crawl page: a section of the sidebar, a view in the main pane, and the
 * inspector for one fix. The list is the site's, kept across crawls; every crawl brings it up to
 * date, and a check — a crawl of just the pages involved — verifies fixes marked done.
 */

export type FixStatus = 'open' | 'ticked' | 'verified' | 'reopened'

export interface FixItem {
  key: string
  parentKey?: string
  topic: string
  name: string
  severity: number
  kind: string
  status: FixStatus
  firstSeen: string
  lastSeen: string
  tickedAt?: string
  verifiedAt?: string
  verifiedBy?: string
  pageCount: number
  checkURLs: string[]
}

export interface FixKind {
  code: string
  title: string
  severity: number
  total: number
  verified: number
  ticked: number
  lastVerifiedBy?: string
  lastVerifiedAt?: string
}

export interface FixList {
  host: string
  items: FixItem[]
  kinds: FixKind[]
}

const severityNames: SeverityName[] = ['error', 'warning', 'notice']
const severityTitles = ['Errors', 'Warnings', 'Notices']
export const statusLabels: Record<FixStatus, string> = { open: 'To do', ticked: 'Done', verified: 'Verified', reopened: 'Still there' }
const statusClass: Record<FixStatus, string> = { open: '', ticked: 'warn', verified: 'ok', reopened: 'bad' }
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

export const fixesPath = (host: string) => `/api/sites/${encodeURIComponent(host)}/fixes`

/** The fixes counted as kinds of problem count them: each issue, not the page holding several. */
function leaves(list: FixList) {
  const parents = new Set(list.items.map((item) => item.parentKey).filter(Boolean))
  return list.items.filter((item) => !parents.has(item.key))
}

/** A fix's name in a list of one kind, where an issue under a page is named by its page. */
function displayName(item: FixItem, byKey: Map<string, FixItem>) {
  if (!item.parentKey) return item.name
  return byKey.get(item.parentKey)?.name ?? item.name
}

export function StatusChip({ status }: { status: FixStatus }) {
  return <span className={`chip ${statusClass[status]}`}>{statusLabels[status]}</span>
}

// MARK: Sidebar

/** All fixes, then each kind of problem by severity, with how many are verified. */
export function FixesSidebar(props: {
  list: FixList | null
  selection: string
  item: (key: string, label: ReactNode, count?: ReactNode, icon?: ReactNode, title?: string) => ReactNode
}) {
  const { list, item } = props
  if (!list || list.kinds.length === 0) return null
  const total = list.kinds.reduce((sum, kind) => sum + kind.total, 0)
  const verified = list.kinds.reduce((sum, kind) => sum + kind.verified, 0)
  const progress = (done: number, of: number) => `${number(done)}/${number(of)}`
  return (
    <>
      <h3>Fixes</h3>
      {item('fixes:all', 'All fixes', progress(verified, total), undefined, `${number(verified)} of ${number(total)} verified`)}
      {severityNames.map((severity, index) => {
        const kinds = list.kinds.filter((kind) => kind.severity === index)
        if (!kinds.length) return null
        return (
          <div key={severity}>
            <h4>{severityTitles[index]}</h4>
            {kinds.map((kind) =>
              item(
                `fixes:${kind.code}`,
                kind.title,
                progress(kind.verified, kind.total),
                <Severity severity={severity} />,
                `${severityTitles[index]}: ${number(kind.verified)} of ${number(kind.total)} verified` +
                  (kind.ticked ? `, ${number(kind.ticked)} done and waiting for a check` : ''),
              ),
            )}
          </div>
        )
      })}
    </>
  )
}

// MARK: Main pane

type Filter = 'todo' | 'ticked' | 'verified' | 'all'
const filters: { id: Filter; label: string; shows: FixStatus[] }[] = [
  { id: 'todo', label: 'To do', shows: ['open', 'reopened'] },
  { id: 'ticked', label: 'Done', shows: ['ticked'] },
  { id: 'verified', label: 'Verified', shows: ['verified'] },
  { id: 'all', label: 'All', shows: ['open', 'reopened', 'ticked', 'verified'] },
]
const pageSize = 200

/** The fixes of one kind, or all of them with an overview; tick them off and check them. */
export function FixesPane(props: {
  list: FixList
  kind: string
  selected: string | null
  checking: boolean
  onSelect: (key: string) => void
  onTick: (keys: string[], ticked: boolean) => void
  onCheck: (keys?: string[]) => void
}) {
  const { list, kind } = props
  const [filter, setFilter] = useState<Filter>('todo')
  const [shown, setShown] = useState(pageSize)
  useEffect(() => setShown(pageSize), [kind, filter])
  const byKey = useMemo(() => new Map(list.items.map((item) => [item.key, item])), [list])
  const all = kind === 'all'
  const current = list.kinds.find((entry) => entry.code === kind)

  // A kind lists its issues; all fixes lists each fix once, a page with several issues as one.
  const rows = useMemo(() => {
    const source = all ? list.items.filter((item) => !item.parentKey) : leaves(list).filter((item) => item.kind === kind)
    return source
  }, [list, kind, all])
  const childrenOf = useMemo(() => {
    const map = new Map<string, FixItem[]>()
    for (const item of list.items) if (item.parentKey) map.set(item.parentKey, [...(map.get(item.parentKey) ?? []), item])
    return map
  }, [list])
  const statusOf = (item: FixItem): FixStatus => {
    const children = childrenOf.get(item.key)
    if (!children?.length) return item.status
    if (children.some((child) => child.status === 'reopened')) return 'reopened'
    if (children.some((child) => child.status === 'open')) return 'open'
    if (children.some((child) => child.status === 'ticked')) return 'ticked'
    return 'verified'
  }
  const shows = filters.find((entry) => entry.id === filter)!.shows
  const visible = rows.filter((item) => shows.includes(statusOf(item)))
  const done = rows.filter((item) => statusOf(item) === 'ticked')
  const counts = (status: FixStatus) => rows.filter((item) => statusOf(item) === status).length

  return (
    <div className="main fixes-pane">
      <div className="table-toolbar">
        <strong style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>{all ? `All fixes · ${list.host}` : current?.title}</strong>
        <span className="hint">{number(rows.length)}</span>
        <span className="spacer" />
        <div className="segmented">
          {filters.map((entry) => (
            <button key={entry.id} className={filter === entry.id ? 'on' : ''} onClick={() => setFilter(entry.id)}>
              {entry.label}
            </button>
          ))}
        </div>
        <button
          className="primary small"
          disabled={!done.length || props.checking}
          title="Crawl just the pages these fixes involve, and verify each one or mark it still there"
          onClick={() => props.onCheck(all ? undefined : done.map((item) => item.key))}
        >
          {props.checking ? 'Checking…' : `Check ${number(done.length)} Done`}
        </button>
      </div>
      {all ? (
        <FixesOverview list={list} />
      ) : (
        <div className="fixes-summary">
          {(['open', 'reopened', 'ticked', 'verified'] as FixStatus[]).map((status) => (
            <span key={status} className={`chip ${statusClass[status]}`}>
              {statusLabels[status]} {number(counts(status))}
            </span>
          ))}
        </div>
      )}
      <div className="fixes-list">
        {visible.length === 0 && <div className="empty">Nothing here.</div>}
        {visible.slice(0, shown).map((item) => {
          const status = statusOf(item)
          const children = childrenOf.get(item.key) ?? []
          return (
            <div
              key={item.key}
              className={`fix-row ${props.selected === item.key ? 'selected' : ''}`}
              onClick={() => props.onSelect(item.key)}
            >
              <input
                type="checkbox"
                title={status === 'verified' ? 'Verified fixed' : status === 'ticked' ? 'Mark not done' : 'Mark as done'}
                checked={status === 'ticked' || status === 'verified'}
                disabled={status === 'verified'}
                onClick={(event) => event.stopPropagation()}
                onChange={(event) => props.onTick([item.key], event.target.checked)}
              />
              <Severity severity={severityNames[item.severity] ?? 'notice'} />
              <span className="fix-name" title={displayName(item, byKey)}>
                {all ? item.name : displayName(item, byKey)}
              </span>
              {all && <span className="hint">{topicNames[item.topic] ?? item.topic}</span>}
              <span className="hint">
                {children.length > 0 ? `${children.length} issues` : `${number(item.pageCount)} page${item.pageCount === 1 ? '' : 's'}`}
              </span>
              <StatusChip status={status} />
            </div>
          )
        })}
        {visible.length > shown && (
          <div className="fix-row">
            <button className="small" onClick={() => setShown(shown + pageSize * 5)}>
              Show more ({number(visible.length - shown)} left)
            </button>
          </div>
        )}
      </div>
    </div>
  )
}

/** Where the site stands: every kind of problem by severity, with its progress. */
function FixesOverview({ list }: { list: FixList }) {
  const total = list.kinds.reduce((sum, kind) => sum + kind.total, 0)
  const verified = list.kinds.reduce((sum, kind) => sum + kind.verified, 0)
  const ticked = list.kinds.reduce((sum, kind) => sum + kind.ticked, 0)
  return (
    <div className="fixes-overview">
      <div className="row wrap">
        <strong>
          {number(verified)} of {number(total)} verified
        </strong>
        {ticked > 0 && <span className="hint">· {number(ticked)} done and waiting for a check</span>}
      </div>
      <div className="progress fixes-progress">
        <div style={{ width: `${total ? (verified / total) * 100 : 0}%` }} />
      </div>
      <div className="fixes-kinds">
        {list.kinds.map((kind) => (
          <div key={kind.code} className="fixes-kind" title={kind.lastVerifiedBy ? `Last verified by ${kind.lastVerifiedBy}` : undefined}>
            <Severity severity={severityNames[kind.severity] ?? 'notice'} />
            <span className="fix-name">{kind.title}</span>
            <span className="progress" style={{ width: 80 }}>
              <div style={{ width: `${kind.total ? (kind.verified / kind.total) * 100 : 0}%` }} />
            </span>
            <span className="hint count">
              {number(kind.verified)}/{number(kind.total)}
            </span>
          </div>
        ))}
      </div>
    </div>
  )
}

// MARK: Inspector

/** One fix: what's wrong where, how to fix it, where it stands, and checking it. */
export function FixInspector(props: {
  list: FixList
  itemKey: string
  checking: boolean
  onTick: (keys: string[], ticked: boolean) => void
  onCheck: (keys?: string[]) => void
  onSelect: (key: string) => void
}) {
  const item = props.list.items.find((entry) => entry.key === props.itemKey)
  const parent = item?.parentKey ? props.list.items.find((entry) => entry.key === item.parentKey) : undefined
  const children = props.list.items.filter((entry) => entry.parentKey === props.itemKey)
  const [details, setDetails] = useState<string | null>(null)

  useEffect(() => {
    setDetails(null)
    if (!item) return
    let current = true
    api
      .get<{ message: string }>(`${fixesPath(props.list.host)}/details?key=${encodeURIComponent(item.key)}`)
      .then((answer) => current && setDetails(answer.message))
      .catch(() => current && setDetails(''))
    return () => {
      current = false
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.itemKey, item?.lastSeen])

  if (!item) return <div className="empty">Select a fix to see what to do.</div>
  const checkable = item.checkURLs.length > 0 || children.some((child) => child.checkURLs.length > 0)
  const done = item.status === 'ticked'
  return (
    <>
      <div className="inspector-header">
        <div className="url">{parent ? `${parent.name} · ${item.name}` : item.name}</div>
        <div className="row wrap">
          <Severity severity={severityNames[item.severity] ?? 'notice'} />
          <StatusChip status={item.status} />
          <span className="hint">{topicNames[item.topic] ?? item.topic}</span>
          <span className="spacer" />
          {item.status !== 'verified' && (
            <button className="small" onClick={() => props.onTick([item.key], !done)}>
              {done ? 'Not Done' : 'Mark Done'}
            </button>
          )}
          {item.status !== 'verified' && (
            <button
              className="small primary"
              disabled={!checkable || props.checking}
              title={checkable ? 'Crawl just the pages this fix involves and verify it' : 'Verified by the next full crawl or speed check'}
              onClick={() => props.onCheck([item.key])}
            >
              Check This Fix
            </button>
          )}
        </div>
      </div>
      <div className="inspector-body">
        <dl className="kv">
          <dt>First found</dt>
          <dd>{item.firstSeen}</dd>
          <dt>Last seen</dt>
          <dd>{item.lastSeen}</dd>
          {item.tickedAt && item.status === 'ticked' && (
            <>
              <dt>Marked done</dt>
              <dd>{relativeDate(item.tickedAt)}</dd>
            </>
          )}
          {item.verifiedBy && (
            <>
              <dt>Verified by</dt>
              <dd>
                {item.verifiedBy}
                {item.verifiedAt ? `, ${relativeDate(item.verifiedAt)}` : ''}
              </dd>
            </>
          )}
        </dl>
        {children.length > 0 && (
          <div className="stack" style={{ gap: 4 }}>
            <strong>Issues</strong>
            {children.map((child) => (
              <div key={child.key} className="fix-row" onClick={() => props.onSelect(child.key)}>
                <input
                  type="checkbox"
                  checked={child.status === 'ticked' || child.status === 'verified'}
                  disabled={child.status === 'verified'}
                  onClick={(event) => event.stopPropagation()}
                  onChange={(event) => props.onTick([child.key], event.target.checked)}
                />
                <span className="fix-name">{child.name}</span>
                <StatusChip status={child.status} />
              </div>
            ))}
          </div>
        )}
        {details === null ? <p className="hint">Loading…</p> : details && <Markdown text={details} />}
      </div>
    </>
  )
}
