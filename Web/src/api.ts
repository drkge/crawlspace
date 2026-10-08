// The server's JSON, and small helpers for calling it. Shapes match Sources/Server/DTO.swift.

export type Severity = 'error' | 'warning' | 'notice'
export type CrawlStatus = 'new' | 'running' | 'paused' | 'stopped' | 'completed'
export type Device = 'mobile' | 'desktop'

export interface Extractor {
  id: string
  name: string
  kind: 'cssSelector' | 'xpath' | 'regex'
  expression: string
  output: 'text' | 'innerHTML' | 'outerHTML' | 'attribute'
  attribute: string
  collectAll: boolean
  useRenderedHTML: boolean
}

export interface CustomSearch {
  id: string
  name: string
  mode: 'contains' | 'doesNotContain' | 'matchesRegex' | 'doesNotMatchRegex'
  term: string
  caseSensitive: boolean
  visibleTextOnly: boolean
  useRenderedHTML: boolean
}

export interface CrawlConfig {
  mode: 'spider' | 'list' | 'sitemap'
  startURL: string
  listURLs: string[]
  sitemapURLs: string[]
  discoverSitemapsFromRobots: boolean
  renderJavaScript: boolean
  renderConcurrency: number
  renderSettleSeconds: number
  storeScreenshots: boolean
  renderBlockHeavyResources: boolean
  extractors: Extractor[]
  customSearches: CustomSearch[]
  basicAuthUsername: string
  customHeaders: Record<string, string>
  cookieHeader: string
  subdomainPolicy: 'exactHost' | 'allSubdomains'
  crawlOutsideStartFolder: boolean
  includePatterns: string[]
  excludePatterns: string[]
  checkExternalLinks: boolean
  followInternalNofollow: boolean
  followExternalNofollow: boolean
  crawlImages: boolean
  crawlCSS: boolean
  crawlJavaScript: boolean
  crawlCanonicals: boolean
  crawlHreflang: boolean
  maxURLs: number
  maxDepth: number
  maxURLLength: number
  maxQueryVariantsPerPath: number
  maxPathSegmentRepeats: number
  maxRedirectsToFollow: number
  concurrency: number
  automaticConcurrency: boolean
  maxURLsPerSecond: number
  timeoutSeconds: number
  respectRobotsTxt: boolean
  skipRobotsBlocked: boolean
  platformProfile: 'automatic' | 'shopify' | 'none'
  appliedProfile?: string | null
  ecommerceMode: 'automatic' | 'on' | 'off'
  ecommerceActive: boolean
  userAgent: string
  robotsUserAgentToken: string
  stripQueryParameters: string[]
  storeHTML: boolean
  maxHTMLBytes: number
  lighthouseTopPages: number
  lighthouseShopifyTemplates: boolean
}

export interface Progress {
  phase: 'idle' | 'starting' | 'crawling' | 'paused' | 'stopping' | 'analysing' | 'finished' | 'failed'
  crawled: number
  discovered: number
  queued: number
  inFlight: number
  concurrency: number
  urlsPerSecond: number
  elapsedSeconds: number
  wasStopped: boolean
  errorMessage?: string
}

export interface LighthouseProgress {
  done: number
  total: number
  currentURL?: string
  currentDevice?: Device
  failures: number
}

export interface CrawlState {
  id: string
  name: string
  site: string
  status: CrawlStatus
  progress: Progress
  isRunning: boolean
  isPaused: boolean
  canStart: boolean
  isConfigurable: boolean
  config: CrawlConfig
  lighthouse: { running: boolean; progress?: LighthouseProgress; message?: string }
  exporting?: string
  ecommerceNote?: string
  /** What a speed check measures, e.g. "one page of each Shopify template". */
  speedPlan: string
}

export interface CrawlListItem {
  id: string
  name: string
  site: string
  startURL: string
  status: CrawlStatus
  crawled: number
  modified: string
  isRunning: boolean
  readable: boolean
}

export interface Issue {
  code: string
  category: string
  severity: Severity
  title: string
  description: string
  howToFix: string
}

export interface Bucket {
  label: string
  count: number
}

export interface Overview {
  totalURLs: number
  crawled: number
  queued: number
  skipped: number
  internalHTML: number
  internalOther: number
  external: number
  indexable: number
  nonIndexable: number
  statusClasses: Bucket[]
  depths: Bucket[]
  responseTimes: Bucket[]
  averageResponseMs?: number
}

export interface Counts {
  issues: { issue: Issue; count: number }[]
  filters: Record<string, number>
  extractions: { name: string; count: number }[]
  searches: { name: string; count: number }[]
  hasLighthouse: boolean
  overview: Overview
}

export interface Column {
  id: string
  title: string
  kind: 'text' | 'integer' | 'decimal'
  width: number
  sortable: boolean
}

export interface RowList {
  title: string
  ids: number[]
  columns: Column[]
  issue?: Issue
}

export interface Row {
  id: number
  url: string
  statusCode?: number
  indexable: boolean
  crawled: boolean
  cells: string[]
}

export interface LinkRow {
  otherID: number
  url: string
  statusCode?: number
  type: number
  flags: number
  text: string
}

export interface EvidenceItem {
  text: string
  url?: string
  position?: number
  pagesWithSameLink?: number
}

export interface Evidence {
  items: EvidenceItem[]
  more: number
  fix: string
  isTemplateWide: boolean
}

export interface LighthouseMetrics {
  score?: number
  lcpMs?: number
  cls?: number
  tbtMs?: number
  fcpMs?: number
  speedIndexMs?: number
}

export interface LighthouseRun {
  device: Device
  metrics: LighthouseMetrics
  opportunities: { id: string; title: string; displayValue?: string; savingsMs: number; score: number }[]
  error?: string
  ranAt: string
  hasReport: boolean
  template?: string
}

/** A page Lighthouse has measured, for the speed-by-template table. */
export interface MeasuredPage {
  id: number
  url: string
  template?: string
  mobile: LighthouseMetrics
  desktop: LighthouseMetrics
}

export interface Inspector {
  id: number
  url: string
  statusCode?: number
  status: string
  indexability: string
  indexable: boolean
  isPage: boolean
  serp?: {
    host: string
    title?: string
    titleLength?: number
    titlePixels?: number
    titleTooWide: boolean
    description?: string
    descriptionLength?: number
    descriptionPixels?: number
    descriptionTooWide: boolean
  }
  details: { name: string; value: string }[]
  issues: { issue: Issue; evidence?: Evidence }[]
  inlinks: LinkRow[]
  outlinks: LinkRow[]
  headers: { name: string; value: string }[]
  hreflang: { lang: string; url: string; statusCode?: number }[]
  structuredData: { types: string; error?: string }[]
  extractions: { name: string; value: string }[]
  nearDuplicates: { url: string; similarity: number }[]
  hasRawHTML: boolean
  hasRenderedHTML: boolean
  hasScreenshot: boolean
  lighthouse: LighthouseRun[]
}

export interface Change {
  url: string
  before?: string
  after?: string
  code?: string
}

export interface Comparison {
  baselineName: string
  currentName: string
  counts: {
    baselineURLs: number
    currentURLs: number
    added: number
    removed: number
    statusChanged: number
    indexabilityChanged: number
    titleChanged: number
    canonicalChanged: number
    newIssues: number
    fixedIssues: number
  }
  issueDeltas: { code: string; title: string; severity: number; before: number; after: number }[]
  added: Change[]
  removed: Change[]
  statusChanges: Change[]
  indexabilityChanges: Change[]
  titleChanges: Change[]
  canonicalChanges: Change[]
  newIssues: Change[]
  fixedIssues: Change[]
}

export interface UpdateState {
  current: string
  latest?: string
  phase: 'idle' | 'checking' | 'downloading' | 'ready' | 'installing' | 'failed' | 'disabled'
  message?: string
  lastChecked?: string
}

export interface About {
  version: string
  commit: string
  update: UpdateState
  lighthouse: string
  lighthouseRuntime?: string
  crawlsFolder: string
  freeDiskGigabytes?: number
}

export interface Settings {
  clickUpSeverities: Severity[]
  clickUpTableSeverities: Severity[]
  clickUpSubtaskLimit: number
  automaticUpdates: boolean
}

export interface ScheduledCrawl {
  id: string
  name: string
  config: CrawlConfig
  frequency: 'daily' | 'weekly' | 'weekdays' | 'hourly'
  hour: number
  minute: number
  weekday: number
  isEnabled: boolean
  compareWithPrevious: boolean
  exportCSV: boolean
  exportReport: boolean
  lastRun?: string
  lastSummary?: string
}

export class APIError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message)
  }
}

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  const response = await fetch(path, {
    method,
    headers: body === undefined ? {} : { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
    credentials: 'same-origin',
  })
  if (!response.ok) {
    let message = `${response.status} ${response.statusText}`
    try {
      const json = await response.json()
      if (json?.message) message = json.message
    } catch {
      // Not JSON: keep the status line.
    }
    throw new APIError(message, response.status)
  }
  if (response.status === 204) return undefined as T
  return response.json() as Promise<T>
}

export const api = {
  get: <T>(path: string) => request<T>('GET', path),
  post: <T>(path: string, body?: unknown) => request<T>('POST', path, body ?? {}),
  put: <T>(path: string, body: unknown) => request<T>('PUT', path, body),
  delete: <T>(path: string) => request<T>('DELETE', path),
}

export const crawlPath = (id: string) => `/api/crawls/${encodeURIComponent(id)}`

/** Starts a download the server builds, and resolves once it's saved (or rejects with its message). */
export async function downloadFrom(method: 'GET' | 'POST', path: string, body?: unknown): Promise<void> {
  const response = await fetch(path, {
    method,
    headers: body === undefined ? {} : { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  if (!response.ok) {
    let message = `${response.status} ${response.statusText}`
    try {
      message = (await response.json()).message ?? message
    } catch {
      // keep the status line
    }
    throw new APIError(message, response.status)
  }
  const disposition = response.headers.get('Content-Disposition') ?? ''
  const encoded = /filename\*=UTF-8''([^;]+)/.exec(disposition)?.[1]
  const plain = /filename="([^"]+)"/.exec(disposition)?.[1]
  const filename = encoded ? decodeURIComponent(encoded) : (plain ?? 'download')
  const blob = await response.blob()
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = filename
  document.body.appendChild(link)
  link.click()
  link.remove()
  setTimeout(() => URL.revokeObjectURL(url), 10_000)
}

export function uuid(): string {
  return crypto.randomUUID().toUpperCase()
}
