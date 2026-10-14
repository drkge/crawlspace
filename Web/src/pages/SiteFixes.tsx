import { useEffect, useState } from 'react'
import { useNavigate, useParams } from 'react-router'
import { api, type CrawlListItem } from '../api'

/**
 * Where the ClickUp overview links to: the fixes of the site's latest crawl, the one to work from.
 */
export default function SiteFixes() {
  const { host = '' } = useParams()
  const navigate = useNavigate()
  const [missing, setMissing] = useState(false)
  useEffect(() => {
    api.get<CrawlListItem[]>('/api/crawls').then((crawls) => {
      const latest = crawls.find((crawl) => crawl.site === host && crawl.readable && !crawl.name.includes(' fix check '))
      if (latest) navigate(`/crawls/${encodeURIComponent(latest.id)}?view=fixes:all`, { replace: true })
      else setMissing(true)
    })
  }, [host, navigate])
  return <div className="empty">{missing ? `There's no crawl of ${host} on this Mac.` : 'Opening the fixes…'}</div>
}
