import { useEffect, useState } from 'react'
import { useNavigate, useParams } from 'react-router'
import { api, type CrawlListItem } from '../api'

/**
 * Where ClickUp tasks filed by earlier versions link to: the site's latest crawl.
 */
export default function LatestCrawl() {
  const { host = '' } = useParams()
  const navigate = useNavigate()
  const [missing, setMissing] = useState(false)
  useEffect(() => {
    api.get<CrawlListItem[]>('/api/crawls').then((crawls) => {
      const latest = crawls.find((crawl) => crawl.site === host && crawl.readable && !crawl.name.includes(' fix check '))
      if (latest) navigate(`/crawls/${encodeURIComponent(latest.id)}`, { replace: true })
      else setMissing(true)
    })
  }, [host, navigate])
  return <div className="empty">{missing ? `There's no crawl of ${host} on this Mac.` : 'Opening the latest crawl…'}</div>
}
