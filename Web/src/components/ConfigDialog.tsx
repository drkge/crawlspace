import { useState, type ReactNode } from 'react'
import { api, uuid, type CrawlConfig, type CustomSearch, type Extractor } from '../api'
import { Confirm, Dialog, useAction } from '../ui'

const lines = (text: string) =>
  text
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)

/** Common causes of damage during a signed-in crawl: following them logs out or deletes things. */
const safetyExclusions = ['/logout', '/log-out', '/signout', '/sign-out', '/delete', '/remove', '/unsubscribe', '/cart']

function hostOf(url: string): string {
  try {
    return new URL(/^https?:\/\//i.test(url) ? url : `https://${url}`).host
  } catch {
    return ''
  }
}

/**
 * Every crawl setting. Before a crawl starts all of them can change; once it has, only speed
 * (and how many pages Lighthouse measures), because a crawl that changed scope half way would mean
 * two different things.
 */
export default function ConfigDialog(props: {
  config: CrawlConfig
  editable: 'all' | 'speed'
  title?: string
  onSave: (config: CrawlConfig) => void
  onCancel: () => void
}) {
  const run = useAction()
  const [config, setConfig] = useState(props.config)
  const [include, setInclude] = useState(props.config.includePatterns.join('\n'))
  const [exclude, setExclude] = useState(props.config.excludePatterns.join('\n'))
  const [sitemaps, setSitemaps] = useState(props.config.sitemapURLs.join('\n'))
  const [strip, setStrip] = useState(props.config.stripQueryParameters.join('\n'))
  const [headers, setHeaders] = useState(
    Object.entries(props.config.customHeaders)
      .map(([name, value]) => `${name}: ${value}`)
      .join('\n'),
  )
  const [password, setPassword] = useState('')
  const [confirmIgnoreRobots, setConfirmIgnoreRobots] = useState(false)
  const all = props.editable === 'all'
  const set = (patch: Partial<CrawlConfig>) => setConfig({ ...config, ...patch })

  const save = async () => {
    const customHeaders: Record<string, string> = {}
    for (const line of lines(headers)) {
      const colon = line.indexOf(':')
      if (colon > 0) customHeaders[line.slice(0, colon).trim()] = line.slice(colon + 1).trim()
    }
    const next: CrawlConfig = {
      ...config,
      includePatterns: lines(include),
      excludePatterns: lines(exclude),
      sitemapURLs: config.mode === 'sitemap' ? config.sitemapURLs : lines(sitemaps),
      stripQueryParameters: lines(strip),
      customHeaders,
    }
    // The password is kept with Crawlspace's secrets, never in the crawl's settings.
    if (all && next.basicAuthUsername && password) {
      const host = hostOf(next.startURL || next.listURLs[0] || '')
      await run(() => api.put('/api/crawl-password', { host, user: next.basicAuthUsername, password }))
    }
    props.onSave(next)
  }

  const number = (key: keyof CrawlConfig, label: string, options: { min?: number; max?: number; step?: number; disabled?: boolean } = {}) => (
    <label className="field">
      <span>{label}</span>
      <input
        type="number"
        min={options.min}
        max={options.max}
        step={options.step ?? 1}
        disabled={options.disabled}
        value={config[key] as number}
        onChange={(event) => set({ [key]: Number(event.target.value) } as Partial<CrawlConfig>)}
      />
    </label>
  )
  const check = (key: keyof CrawlConfig, label: ReactNode, disabled = !all) => (
    <label className="check">
      <input
        type="checkbox"
        disabled={disabled}
        checked={config[key] as boolean}
        onChange={(event) => set({ [key]: event.target.checked } as Partial<CrawlConfig>)}
      />
      <span>{label}</span>
    </label>
  )

  return (
    <Dialog
      title={props.title ?? 'Crawl Configuration'}
      size="wide"
      onClose={props.onCancel}
      footer={
        <>
          {!all && <span className="hint">This crawl has started, so only its speed can change.</span>}
          <span className="spacer" />
          <button onClick={props.onCancel}>Cancel</button>
          <button className="primary" onClick={save}>
            Done
          </button>
        </>
      }
    >
      <fieldset>
        <legend>Speed</legend>
        <div className="form-grid">
          {number('concurrency', 'Maximum connections', { min: 1, max: 50 })}
          {number('maxURLsPerSecond', 'URLs per second (0 = no limit)', { min: 0, step: 0.5 })}
          {number('timeoutSeconds', 'Timeout (seconds)', { min: 1 })}
          {config.renderJavaScript && number('renderConcurrency', 'Pages rendered at once', { min: 1, max: 8 })}
        </div>
        {check('automaticConcurrency', 'Find the kindest number under that: fewer connections when the server struggles', false)}
      </fieldset>

      <fieldset>
        <legend>Speed reports (Lighthouse)</legend>
        <div className="row wrap">
          {number('lighthouseTopPages', 'Pages to measure after the crawl', { min: 0, max: 500 })}
          <span className="hint" style={{ maxWidth: 420 }}>
            The most-linked indexable pages, measured on mobile and desktop: roughly half a minute a page. 0 turns it off; you can
            still measure any page from the inspector.
          </span>
        </div>
        {check(
          'lighthouseShopifyTemplates',
          <>
            On Shopify stores, measure one page of each theme template instead: home, the most-linked collection, all products, the 3
            most-linked products, cart, search, blog, an article and a page. About 10 pages.
          </>,
          false,
        )}
      </fieldset>

      <fieldset disabled={!all}>
        <legend>Scope</legend>
        <div className="form-grid">
          <label className="field">
            <span>Subdomains</span>
            <select value={config.subdomainPolicy} onChange={(event) => set({ subdomainPolicy: event.target.value as CrawlConfig['subdomainPolicy'] })}>
              <option value="exactHost">Only the start URL's host</option>
              <option value="allSubdomains">The host and all its subdomains</option>
            </select>
          </label>
          {number('maxURLs', 'Maximum URLs', { min: 1, disabled: !all })}
          {number('maxDepth', 'Maximum depth (0 = no limit)', { min: 0, disabled: !all })}
          {number('maxQueryVariantsPerPath', 'Query variants per path', { min: 1, disabled: !all })}
        </div>
        {check('crawlOutsideStartFolder', 'Crawl outside the start folder')}
        {check('checkExternalLinks', 'Check external links')}
        <div className="form-grid">
          <label className="field">
            <span>Only crawl URLs matching (regex, one per line)</span>
            <textarea rows={3} value={include} onChange={(event) => setInclude(event.target.value)} />
          </label>
          <label className="field">
            <span>Skip URLs matching (regex, one per line)</span>
            <textarea rows={3} value={exclude} onChange={(event) => setExclude(event.target.value)} />
          </label>
        </div>
      </fieldset>

      <fieldset disabled={!all}>
        <legend>What to crawl</legend>
        <div className="form-grid">
          {check('crawlImages', 'Images')}
          {check('crawlCSS', 'CSS')}
          {check('crawlJavaScript', 'JavaScript')}
          {check('crawlCanonicals', 'Canonicals')}
          {check('crawlHreflang', 'Hreflang')}
          {check('followInternalNofollow', 'Follow internal nofollow')}
          {check('followExternalNofollow', 'Follow external nofollow')}
        </div>
      </fieldset>

      <fieldset disabled={!all}>
        <legend>Robots and identity</legend>
        <label className="check">
          <input
            type="checkbox"
            checked={config.respectRobotsTxt}
            onChange={(event) => (event.target.checked ? set({ respectRobotsTxt: true }) : setConfirmIgnoreRobots(true))}
          />
          <span>Respect robots.txt</span>
        </label>
        {check('skipRobotsBlocked', 'Leave URLs robots.txt blocks out of the reports')}
        <div className="form-grid">
          <label className="field">
            <span>User-Agent</span>
            <input type="text" value={config.userAgent} onChange={(event) => set({ userAgent: event.target.value })} />
          </label>
          <label className="field">
            <span>robots.txt token</span>
            <input type="text" value={config.robotsUserAgentToken} onChange={(event) => set({ robotsUserAgentToken: event.target.value })} />
          </label>
        </div>
      </fieldset>

      <fieldset disabled={!all}>
        <legend>Platform</legend>
        <div className="form-grid">
          <label className="field">
            <span>Platform defaults</span>
            <select value={config.platformProfile} onChange={(event) => set({ platformProfile: event.target.value as CrawlConfig['platformProfile'] })}>
              <option value="automatic">Automatic</option>
              <option value="shopify">Shopify</option>
              <option value="none">None</option>
            </select>
          </label>
          <label className="field">
            <span>E-commerce checks</span>
            <select value={config.ecommerceMode} onChange={(event) => set({ ecommerceMode: event.target.value as CrawlConfig['ecommerceMode'] })}>
              <option value="automatic">Automatic (on for Shopify)</option>
              <option value="on">On</option>
              <option value="off">Off</option>
            </select>
          </label>
        </div>
        {config.appliedProfile && (
          <p className="hint">
            {config.appliedProfile} was detected: its filter, sort and search URLs aren't crawled
            {config.ecommerceActive ? ', and the e-commerce checks are on' : ''}.
          </p>
        )}
      </fieldset>

      <fieldset disabled={!all}>
        <legend>JavaScript rendering</legend>
        {check('renderJavaScript', 'Render pages with WebKit, so content JavaScript builds is audited (much slower)')}
        {config.renderJavaScript && (
          <>
            <div className="form-grid">{number('renderSettleSeconds', 'Wait after load (seconds)', { min: 0, step: 0.5, disabled: !all })}</div>
            {check('storeScreenshots', 'Keep a screenshot of each page')}
            {check('renderBlockHeavyResources', 'Skip images, media and fonts while rendering (faster)')}
          </>
        )}
      </fieldset>

      <fieldset disabled={!all}>
        <legend>Sitemaps</legend>
        {check('discoverSitemapsFromRobots', 'Find sitemaps listed in robots.txt')}
        {config.mode !== 'sitemap' && (
          <label className="field">
            <span>Also check these sitemaps (one per line)</span>
            <textarea rows={2} value={sitemaps} onChange={(event) => setSitemaps(event.target.value)} />
          </label>
        )}
      </fieldset>

      <fieldset disabled={!all}>
        <legend>Custom extraction</legend>
        <ExtractorEditor extractors={config.extractors} onChange={(extractors) => set({ extractors })} disabled={!all} />
      </fieldset>

      <fieldset disabled={!all}>
        <legend>Custom search</legend>
        <SearchEditor searches={config.customSearches} onChange={(customSearches) => set({ customSearches })} disabled={!all} />
      </fieldset>

      <fieldset disabled={!all}>
        <legend>Authentication</legend>
        <div className="form-grid">
          <label className="field">
            <span>Username (HTTP basic auth)</span>
            <input type="text" autoComplete="off" value={config.basicAuthUsername} onChange={(event) => set({ basicAuthUsername: event.target.value })} />
          </label>
          <label className="field">
            <span>Password</span>
            <input
              type="password"
              autoComplete="new-password"
              placeholder={config.basicAuthUsername ? 'Unchanged' : ''}
              value={password}
              onChange={(event) => setPassword(event.target.value)}
            />
          </label>
        </div>
        <label className="field">
          <span>Cookie header</span>
          <input type="text" value={config.cookieHeader} placeholder="session=…" onChange={(event) => set({ cookieHeader: event.target.value })} />
        </label>
        <label className="field">
          <span>Custom headers ("Name: value", one per line)</span>
          <textarea rows={2} value={headers} onChange={(event) => setHeaders(event.target.value)} />
        </label>
        <div>
          <button
            className="small"
            onClick={() => setExclude([...new Set([...lines(exclude), ...safetyExclusions])].join('\n'))}
            type="button"
          >
            Exclude sign-out and delete URLs
          </button>
        </div>
      </fieldset>

      <fieldset disabled={!all}>
        <legend>Content</legend>
        {check('storeHTML', "Store each page's HTML (needed for the Source tab)")}
        <label className="field">
          <span>Query parameters to strip (one per line; a trailing * matches a prefix, such as utm_*)</span>
          <textarea rows={2} value={strip} onChange={(event) => setStrip(event.target.value)} />
        </label>
      </fieldset>

      {confirmIgnoreRobots && (
        <Confirm
          title="Ignore robots.txt?"
          message="Crawlspace will fetch pages the site has asked crawlers not to. Only do this on sites you own or have permission to crawl."
          action="Ignore robots.txt"
          onCancel={() => setConfirmIgnoreRobots(false)}
          onConfirm={() => {
            set({ respectRobotsTxt: false })
            setConfirmIgnoreRobots(false)
          }}
        />
      )}
    </Dialog>
  )
}

function ExtractorEditor(props: { extractors: Extractor[]; onChange: (extractors: Extractor[]) => void; disabled: boolean }) {
  const update = (index: number, patch: Partial<Extractor>) =>
    props.onChange(props.extractors.map((extractor, i) => (i === index ? { ...extractor, ...patch } : extractor)))
  return (
    <div className="stack">
      {props.extractors.map((extractor, index) => (
        <div className="row wrap" key={extractor.id}>
          <input type="text" placeholder="Name" value={extractor.name} onChange={(event) => update(index, { name: event.target.value })} style={{ width: 140 }} />
          <select value={extractor.kind} onChange={(event) => update(index, { kind: event.target.value as Extractor['kind'] })}>
            <option value="cssSelector">CSS selector</option>
            <option value="xpath">XPath</option>
            <option value="regex">Regex</option>
          </select>
          <input
            type="text"
            className="mono"
            placeholder={extractor.kind === 'cssSelector' ? '.price' : extractor.kind === 'xpath' ? '//span[@class="price"]' : 'SKU: (\\w+)'}
            value={extractor.expression}
            onChange={(event) => update(index, { expression: event.target.value })}
            style={{ flex: 1, minWidth: 160 }}
          />
          {extractor.kind !== 'regex' && (
            <select value={extractor.output} onChange={(event) => update(index, { output: event.target.value as Extractor['output'] })}>
              <option value="text">Text</option>
              <option value="innerHTML">Inner HTML</option>
              <option value="outerHTML">Outer HTML</option>
              <option value="attribute">Attribute</option>
            </select>
          )}
          {extractor.output === 'attribute' && (
            <input type="text" placeholder="href" value={extractor.attribute} onChange={(event) => update(index, { attribute: event.target.value })} style={{ width: 90 }} />
          )}
          <label className="check">
            <input type="checkbox" checked={extractor.collectAll} onChange={(event) => update(index, { collectAll: event.target.checked })} />
            All matches
          </label>
          <button className="small plain" type="button" onClick={() => props.onChange(props.extractors.filter((_, i) => i !== index))}>
            Remove
          </button>
        </div>
      ))}
      <div>
        <button
          className="small"
          type="button"
          disabled={props.disabled}
          onClick={() =>
            props.onChange([
              ...props.extractors,
              { id: uuid(), name: '', kind: 'cssSelector', expression: '', output: 'text', attribute: '', collectAll: false, useRenderedHTML: true },
            ])
          }
        >
          Add extractor
        </button>
      </div>
    </div>
  )
}

function SearchEditor(props: { searches: CustomSearch[]; onChange: (searches: CustomSearch[]) => void; disabled: boolean }) {
  const update = (index: number, patch: Partial<CustomSearch>) =>
    props.onChange(props.searches.map((search, i) => (i === index ? { ...search, ...patch } : search)))
  return (
    <div className="stack">
      {props.searches.map((search, index) => (
        <div className="row wrap" key={search.id}>
          <input type="text" placeholder="Name" value={search.name} onChange={(event) => update(index, { name: event.target.value })} style={{ width: 140 }} />
          <select value={search.mode} onChange={(event) => update(index, { mode: event.target.value as CustomSearch['mode'] })}>
            <option value="contains">Contains</option>
            <option value="doesNotContain">Does not contain</option>
            <option value="matchesRegex">Matches regex</option>
            <option value="doesNotMatchRegex">Doesn't match regex</option>
          </select>
          <input type="text" placeholder="Text to find" value={search.term} onChange={(event) => update(index, { term: event.target.value })} style={{ flex: 1, minWidth: 160 }} />
          <label className="check">
            <input type="checkbox" checked={search.caseSensitive} onChange={(event) => update(index, { caseSensitive: event.target.checked })} />
            Case sensitive
          </label>
          <label className="check">
            <input type="checkbox" checked={search.visibleTextOnly} onChange={(event) => update(index, { visibleTextOnly: event.target.checked })} />
            Visible text only
          </label>
          <button className="small plain" type="button" onClick={() => props.onChange(props.searches.filter((_, i) => i !== index))}>
            Remove
          </button>
        </div>
      ))}
      <div>
        <button
          className="small"
          type="button"
          disabled={props.disabled}
          onClick={() =>
            props.onChange([
              ...props.searches,
              { id: uuid(), name: '', mode: 'contains', term: '', caseSensitive: false, visibleTextOnly: false, useRenderedHTML: true },
            ])
          }
        >
          Add search
        </button>
      </div>
    </div>
  )
}
