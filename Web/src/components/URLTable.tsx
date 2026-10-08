import { useVirtualizer } from '@tanstack/react-virtual'
import { useEffect, useMemo, useRef, useState, type KeyboardEvent, type MouseEvent } from 'react'
import { api, crawlPath, type Column, type Row } from '../api'
import { ContextMenu, useToast } from '../ui'

const rowHeight = 24
const pageSize = 200

/**
 * A table that stays quick at a million rows: it holds only the list of row ids and fetches the
 * rows themselves in pages of 200 as they scroll into view.
 */
export default function URLTable(props: {
  crawlID: string
  ids: number[]
  columns: Column[]
  /** Bumped when the crawl's data has changed, so loaded rows are fetched again. */
  version: number
  sort: { column: string; ascending: boolean } | null
  onSort: (sort: { column: string; ascending: boolean }) => void
  selected: number | null
  onSelect: (id: number | null) => void
  onRunLighthouse: (ids: number[]) => void
}) {
  const { crawlID, ids, columns, version } = props
  const toast = useToast()
  const scroller = useRef<HTMLDivElement>(null)
  const [rows, setRows] = useState<Map<number, Row>>(new Map())
  const loading = useRef(new Set<number>())
  const [widths, setWidths] = useState<Record<string, number>>({})
  const [multi, setMulti] = useState<Set<number>>(new Set())
  const anchor = useRef<number | null>(null)
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null)

  // A different table, or new data: forget what's loaded.
  const columnKey = columns.map((column) => column.id).join('|')
  useEffect(() => {
    setRows(new Map())
    loading.current.clear()
  }, [crawlID, columnKey, version])
  useEffect(() => {
    setMulti(new Set())
    scroller.current?.scrollTo({ top: 0 })
  }, [crawlID, columnKey])

  const virtualizer = useVirtualizer({
    count: ids.length,
    getScrollElement: () => scroller.current,
    estimateSize: () => rowHeight,
    overscan: 30,
  })
  const items = virtualizer.getVirtualItems()

  // Fetch whichever pages the visible rows fall in.
  useEffect(() => {
    if (!items.length) return
    const first = Math.floor(items[0].index / pageSize)
    const last = Math.floor(items[items.length - 1].index / pageSize)
    for (let page = first; page <= last; page++) {
      if (loading.current.has(page)) continue
      const pageIDs = ids.slice(page * pageSize, (page + 1) * pageSize)
      if (pageIDs.every((id) => rows.has(id))) continue
      loading.current.add(page)
      api
        .post<Row[]>(`${crawlPath(crawlID)}/rows/data`, { ids: pageIDs, columns: columns.map((column) => column.id) })
        .then((loaded) =>
          setRows((current) => {
            const next = new Map(current)
            for (const row of loaded) next.set(row.id, row)
            return next
          }),
        )
        .catch(() => loading.current.delete(page))
    }
  }, [items, ids, rows, crawlID, columns])

  const widthOf = (column: Column) => widths[column.id] ?? column.width
  const totalWidth = useMemo(() => columns.reduce((sum, column) => sum + widthOf(column), 0), [columns, widths])

  const select = (id: number, index: number, event: MouseEvent) => {
    if (event.shiftKey && anchor.current !== null) {
      const from = ids.indexOf(anchor.current)
      const [start, end] = from < index ? [from, index] : [index, from]
      setMulti(new Set(ids.slice(start, end + 1)))
    } else if (event.metaKey || event.ctrlKey) {
      const next = new Set(multi)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      setMulti(next)
      anchor.current = id
    } else {
      setMulti(new Set([id]))
      anchor.current = id
    }
    props.onSelect(id)
  }

  const keyDown = (event: KeyboardEvent) => {
    if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return
    event.preventDefault()
    const current = props.selected === null ? -1 : ids.indexOf(props.selected)
    const next = Math.max(0, Math.min(ids.length - 1, current + (event.key === 'ArrowDown' ? 1 : -1)))
    if (ids[next] === undefined) return
    setMulti(new Set([ids[next]]))
    anchor.current = ids[next]
    props.onSelect(ids[next])
    virtualizer.scrollToIndex(next, { align: 'auto' })
  }

  const chosen = () => {
    const set = multi.size ? multi : new Set(props.selected !== null ? [props.selected] : [])
    return ids.filter((id) => set.has(id))
  }
  const chosenURLs = () => chosen().map((id) => rows.get(id)?.url).filter((url): url is string => !!url)

  const startResize = (column: Column, event: MouseEvent) => {
    event.preventDefault()
    event.stopPropagation()
    const startX = event.clientX
    const startWidth = widthOf(column)
    const move = (moveEvent: globalThis.MouseEvent) =>
      setWidths((current) => ({ ...current, [column.id]: Math.max(50, startWidth + moveEvent.clientX - startX) }))
    const up = () => {
      window.removeEventListener('mousemove', move)
      window.removeEventListener('mouseup', up)
    }
    window.addEventListener('mousemove', move)
    window.addEventListener('mouseup', up)
  }

  if (!columns.length) return null
  if (!ids.length) return <div className="empty">No URLs here.</div>

  return (
    <div className="grid" ref={scroller} tabIndex={0} onKeyDown={keyDown}>
      <div className="grid-header" style={{ width: totalWidth }}>
        {columns.map((column) => {
          const sorted = props.sort?.column === column.id
          return (
            <div
              key={column.id}
              className={column.sortable ? 'sortable' : ''}
              style={{ width: widthOf(column), textAlign: column.kind === 'text' ? 'left' : 'right' }}
              title={column.title}
              onClick={() =>
                column.sortable &&
                props.onSort({ column: column.id, ascending: sorted ? !props.sort!.ascending : column.kind === 'text' })
              }
            >
              {column.title}
              {sorted ? (props.sort!.ascending ? ' ▲' : ' ▼') : ''}
              <span className="resize" onMouseDown={(event) => startResize(column, event)} onClick={(event) => event.stopPropagation()} />
            </div>
          )
        })}
      </div>
      <div style={{ height: virtualizer.getTotalSize(), width: totalWidth, position: 'relative' }}>
        {items.map((item) => {
          const id = ids[item.index]
          const row = rows.get(id)
          const status = row?.statusCode ?? 0
          const classes = [
            'grid-row',
            id === props.selected || multi.has(id) ? 'selected' : '',
            status >= 400 ? 'broken' : status >= 300 ? 'redirect' : '',
            row && row.crawled && !row.indexable ? 'nonindexable' : '',
          ].join(' ')
          return (
            <div
              key={id}
              className={classes}
              style={{ top: item.start, width: totalWidth }}
              onMouseDown={(event) => event.button === 0 && select(id, item.index, event)}
              onDoubleClick={() => row && window.open(row.url, '_blank', 'noopener')}
              onContextMenu={(event) => {
                event.preventDefault()
                if (!multi.has(id)) {
                  setMulti(new Set([id]))
                  props.onSelect(id)
                }
                setMenu({ x: event.clientX, y: event.clientY })
              }}
            >
              {columns.map((column, index) => (
                <div key={column.id} className={column.kind === 'text' ? '' : 'num'} style={{ width: widthOf(column) }} title={row?.cells[index]}>
                  {row ? formatCell(row.cells[index], column) : ''}
                </div>
              ))}
            </div>
          )
        })}
      </div>
      {menu && (
        <ContextMenu x={menu.x} y={menu.y} onClose={() => setMenu(null)}>
          <button
            onClick={() => {
              for (const url of chosenURLs().slice(0, 10)) window.open(url, '_blank', 'noopener')
            }}
          >
            Open in Browser{chosen().length > 1 ? ` (${Math.min(chosen().length, 10)})` : ''}
          </button>
          <button
            onClick={async () => {
              await navigator.clipboard.writeText(chosenURLs().join('\n'))
              toast(chosen().length === 1 ? 'Copied the URL' : `Copied ${chosen().length} URLs`)
            }}
          >
            Copy URL{chosen().length > 1 ? 's' : ''}
          </button>
          <hr />
          <button onClick={() => props.onRunLighthouse(chosen())}>Run Lighthouse on {chosen().length === 1 ? 'This Page' : `${chosen().length} Pages`}</button>
        </ContextMenu>
      )}
    </div>
  )
}

/** Decimal columns arrive with their full precision; a table wants whole numbers, scores too. */
function formatCell(value: string, column: Column): string {
  if (column.kind === 'decimal' && value !== '' && !Number.isNaN(Number(value))) return Math.round(Number(value)).toLocaleString()
  if (column.kind === 'integer' && value !== '' && !Number.isNaN(Number(value))) return Number(value).toLocaleString()
  return value
}
