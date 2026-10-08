import { useState } from 'react'
import { api } from '../api'
import { useStoredState } from '../hooks'
import { useAction } from '../ui'

interface Verdict {
  url: string
  allowed: boolean
  rule?: string
  line?: number
}

/** Fetch a site's robots.txt (or paste one), edit it, and see which URLs it lets through. */
export default function RobotsPage() {
  const run = useAction()
  const [site, setSite] = useStoredState('robots.site', '')
  const [robots, setRobots] = useState('')
  const [urls, setURLs] = useState('')
  const [agent, setAgent] = useStoredState('robots.agent', 'Googlebot')
  const [fetched, setFetched] = useState<string | null>(null)
  const [verdicts, setVerdicts] = useState<Verdict[] | null>(null)
  const [fetching, setFetching] = useState(false)

  const fetchRobots = async () => {
    setFetching(true)
    const result = await run(() => api.post<{ robotsURL: string; statusCode: number; text: string }>('/api/robots/fetch', { site }))
    setFetching(false)
    if (!result) return
    setRobots(result.text)
    setFetched(`${result.robotsURL} — HTTP ${result.statusCode}${result.text ? '' : ' (empty, so everything is allowed)'}`)
    if (!urls.trim()) setURLs(site)
  }

  const test = async () => {
    const result = await run(() =>
      api.post<Verdict[]>('/api/robots/test', { site, robots, urls: urls.split('\n'), userAgent: agent }),
    )
    if (result) setVerdicts(result)
  }

  return (
    <div className="page">
      <div className="page-inner stack" style={{ maxWidth: 1200 }}>
        <h1>Robots.txt Tester</h1>
        <div className="charts" style={{ alignItems: 'start' }}>
          <div className="card stack">
            <form
              className="row"
              onSubmit={(event) => {
                event.preventDefault()
                fetchRobots()
              }}
            >
              <input type="text" style={{ flex: 1 }} placeholder="https://www.example.com" value={site} onChange={(event) => setSite(event.target.value)} />
              <button type="submit" disabled={fetching || !site.trim()}>
                {fetching ? 'Fetching…' : 'Fetch'}
              </button>
            </form>
            {fetched && <span className="hint">{fetched}</span>}
            <label className="field">
              <span>robots.txt (edit freely to try changes)</span>
              <textarea rows={18} value={robots} onChange={(event) => setRobots(event.target.value)} />
            </label>
          </div>
          <div className="card stack">
            <label className="field">
              <span>URLs or paths to test, one per line</span>
              <textarea rows={8} value={urls} onChange={(event) => setURLs(event.target.value)} />
            </label>
            <div className="row">
              <label className="field" style={{ flex: 1 }}>
                <span>User-agent</span>
                <input type="text" value={agent} onChange={(event) => setAgent(event.target.value)} />
              </label>
              <button className="primary" style={{ alignSelf: 'end' }} onClick={test} disabled={!urls.trim()}>
                Test URLs
              </button>
            </div>
            {verdicts && (
              <table className="simple">
                <thead>
                  <tr>
                    <th>URL</th>
                    <th>Result</th>
                    <th>Rule</th>
                  </tr>
                </thead>
                <tbody>
                  {verdicts.map((verdict, index) => (
                    <tr key={index}>
                      <td style={{ wordBreak: 'break-all' }}>{verdict.url}</td>
                      <td style={{ color: verdict.allowed ? 'var(--good)' : 'var(--error)', fontWeight: 500 }}>
                        {verdict.allowed ? 'Allowed' : 'Blocked'}
                      </td>
                      <td className="mono">{verdict.rule ? `${verdict.rule} (line ${verdict.line})` : <span className="hint">No rule matched</span>}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
        </div>
      </div>
    </div>
  )
}
