import { useEffect, useState } from 'react'
import { NavLink, Route, Routes } from 'react-router'
import { api, APIError, type About, type UpdateState } from './api'
import { useEvents } from './hooks'
import CrawlPage from './pages/CrawlPage'
import RobotsPage from './pages/RobotsPage'
import SchedulesPage from './pages/SchedulesPage'
import SettingsPage from './pages/SettingsPage'
import StartPage from './pages/StartPage'
import { useAction } from './ui'

export default function App() {
  const [about, setAbout] = useState<About | null>(null)
  const [update, setUpdate] = useState<UpdateState | null>(null)
  const [signedOut, setSignedOut] = useState(false)
  const run = useAction()

  const loadAbout = () =>
    api
      .get<About>('/api/about')
      .then((about) => {
        // Back after a restart with a different version: reload so the page matches the server.
        setAbout((previous) => {
          if (previous && previous.version !== about.version) window.location.reload()
          return about
        })
        setUpdate(about.update)
        setSignedOut(false)
      })
      .catch((error) => {
        if (error instanceof APIError && error.status === 403) setSignedOut(true)
      })

  useEffect(() => {
    loadAbout()
  }, [])

  // One stream for library-wide news; pages listen for it on the window rather than opening their
  // own, since a browser allows only six connections to a site.
  const connected = useEvents(
    signedOut ? null : '/api/events',
    { update: setUpdate, crawls: () => window.dispatchEvent(new Event('crawlspace:crawls')) },
    () => {
      loadAbout()
      window.dispatchEvent(new Event('crawlspace:crawls'))
    },
  )

  if (signedOut) {
    return (
      <div className="empty">
        <div className="stack" style={{ maxWidth: 420 }}>
          <h1>Open Crawlspace from the menu bar</h1>
          <p className="hint">
            This browser isn't signed in yet. Click the ant in the menu bar and choose Open Crawlspace.
          </p>
        </div>
      </div>
    )
  }

  return (
    <div className="app">
      <header className="topbar">
        <NavLink to="/" className="brand">
          <span aria-hidden>🐜</span> Crawlspace
        </NavLink>
        <nav className="row">
          <NavLink to="/" end>
            Crawls
          </NavLink>
          <NavLink to="/schedules">Schedules</NavLink>
          <NavLink to="/robots">Robots.txt Tester</NavLink>
          <NavLink to="/settings">Settings</NavLink>
        </nav>
        <span className="spacer" />
        <span className="hint">{about ? `Version ${about.version}` : ''}</span>
      </header>
      <div>
        {!connected && (
          <div className="banner warn">
            <span className="dot running" /> Reconnecting… If it doesn't come back, open it from the menu bar.
          </div>
        )}
        {connected && update?.phase === 'ready' && (
          <div className="banner">
            <span>
              Version {update.latest} is ready. It installs by itself once no crawl is running, or you can restart now.
            </span>
            <span className="spacer" />
            <button className="small primary" onClick={() => run(() => api.post('/api/update/apply'))}>
              Restart now
            </button>
          </div>
        )}
        {connected && update?.phase === 'installing' && <div className="banner">Installing {update.latest}… this page will reload.</div>}
      </div>
      <Routes>
        <Route path="/" element={<StartPage about={about} />} />
        <Route path="/crawls/:id" element={<CrawlPage />} />
        <Route path="/schedules" element={<SchedulesPage />} />
        <Route path="/robots" element={<RobotsPage />} />
        <Route path="/settings" element={<SettingsPage about={about} onChange={loadAbout} />} />
        <Route path="*" element={<div className="empty">Nothing here.</div>} />
      </Routes>
    </div>
  )
}
