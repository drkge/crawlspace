import { useEffect, useState } from 'react'
import { api, uuid, type CrawlConfig, type ScheduledCrawl } from '../api'
import ConfigDialog from '../components/ConfigDialog'
import { relativeDate } from '../hooks'
import { Confirm, Dialog, useAction, useToast } from '../ui'

interface ScheduleEntry {
  schedule: ScheduledCrawl
  description: string
  installed: boolean
}

const weekdays = ['', 'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']

/** Crawls that run themselves: overnight, weekly, and so on, compared with the run before. */
export default function SchedulesPage() {
  const run = useAction()
  const toast = useToast()
  const [entries, setEntries] = useState<ScheduleEntry[] | null>(null)
  const [editing, setEditing] = useState<ScheduledCrawl | null>(null)
  const [deleting, setDeleting] = useState<ScheduledCrawl | null>(null)
  const [defaults, setDefaults] = useState<CrawlConfig | null>(null)

  const reload = () => api.get<ScheduleEntry[]>('/api/schedules').then(setEntries)
  useEffect(() => {
    reload()
    api.get<CrawlConfig>('/api/defaults').then(setDefaults)
  }, [])

  const create = () =>
    defaults &&
    setEditing({
      id: uuid(),
      name: '',
      config: defaults,
      frequency: 'weekly',
      hour: 3,
      minute: 0,
      weekday: 2,
      isEnabled: true,
      compareWithPrevious: true,
      exportCSV: false,
      exportReport: false,
    })

  return (
    <div className="page">
      <div className="page-inner stack">
        <div className="row">
          <h1>Scheduled crawls</h1>
          <span className="spacer" />
          <button className="primary" onClick={create} disabled={!defaults}>
            New Schedule…
          </button>
        </div>
        <p className="hint">
          Scheduled crawls run in the background while this Mac is awake and you're logged in. One due while it was asleep runs soon
          after it wakes. Each finished crawl appears in Recent Crawls.
        </p>
        {entries?.length === 0 && <p className="hint">No schedules yet.</p>}
        {entries?.map(({ schedule, description }) => (
          <div className="card row" key={schedule.id}>
            <div style={{ flex: 1, minWidth: 0 }} className="stack">
              <div className="row">
                <strong>{schedule.name}</strong>
                {!schedule.isEnabled && <span className="chip">Paused</span>}
              </div>
              <span className="hint">
                {description} · {schedule.config.startURL}
              </span>
              {schedule.lastRun && (
                <span className="hint">
                  Last run {relativeDate(schedule.lastRun)}
                  {schedule.lastSummary ? `: ${schedule.lastSummary}` : ''}
                </span>
              )}
            </div>
            <button
              className="small"
              onClick={async () => {
                const started = await run(() => api.post<{ message: string }>(`/api/schedules/${schedule.id}/run`))
                if (started) {
                  toast(started.message)
                  reload()
                }
              }}
            >
              Run Now
            </button>
            <button className="small" onClick={() => setEditing(schedule)}>
              Edit
            </button>
            <button className="small danger" onClick={() => setDeleting(schedule)}>
              Delete
            </button>
          </div>
        ))}
      </div>

      {editing && (
        <ScheduleEditor
          schedule={editing}
          onCancel={() => setEditing(null)}
          onSave={async (schedule) => {
            const saved = await run(() => api.put(`/api/schedules/${schedule.id}`, schedule), `${schedule.name} saved`)
            if (saved) {
              setEditing(null)
              reload()
            }
          }}
        />
      )}
      {deleting && (
        <Confirm
          title={`Delete “${deleting.name}”?`}
          message="It stops running. Crawls it has already made stay in Recent Crawls."
          action="Delete"
          danger
          onCancel={() => setDeleting(null)}
          onConfirm={async () => {
            const schedule = deleting
            setDeleting(null)
            await run(() => api.delete(`/api/schedules/${schedule.id}`))
            reload()
          }}
        />
      )}
    </div>
  )
}

function ScheduleEditor(props: { schedule: ScheduledCrawl; onSave: (schedule: ScheduledCrawl) => void; onCancel: () => void }) {
  const [schedule, setSchedule] = useState(props.schedule)
  const [configuring, setConfiguring] = useState(false)
  const set = (patch: Partial<ScheduledCrawl>) => setSchedule({ ...schedule, ...patch })
  const time = `${String(schedule.hour).padStart(2, '0')}:${String(schedule.minute).padStart(2, '0')}`

  return (
    <Dialog
      title={props.schedule.name ? `Edit ${props.schedule.name}` : 'New Schedule'}
      onClose={props.onCancel}
      footer={
        <>
          <button onClick={props.onCancel}>Cancel</button>
          <button className="primary" onClick={() => props.onSave(schedule)}>
            Save
          </button>
        </>
      }
    >
      <div className="form-grid">
        <label className="field">
          <span>Name</span>
          <input type="text" value={schedule.name} placeholder="Client weekly" onChange={(event) => set({ name: event.target.value })} />
        </label>
        <label className="field">
          <span>Start URL</span>
          <input
            type="text"
            value={schedule.config.startURL}
            placeholder="https://www.example.com/"
            onChange={(event) => set({ config: { ...schedule.config, startURL: event.target.value } })}
          />
        </label>
      </div>
      <div>
        <button className="small" onClick={() => setConfiguring(true)}>
          Crawl Configuration…
        </button>
      </div>
      <div className="row wrap">
        <label className="field">
          <span>Runs</span>
          <select value={schedule.frequency} onChange={(event) => set({ frequency: event.target.value as ScheduledCrawl['frequency'] })}>
            <option value="hourly">Every hour</option>
            <option value="daily">Every day</option>
            <option value="weekdays">Weekdays</option>
            <option value="weekly">Every week</option>
          </select>
        </label>
        {schedule.frequency === 'weekly' && (
          <label className="field">
            <span>On</span>
            <select value={schedule.weekday} onChange={(event) => set({ weekday: Number(event.target.value) })}>
              {weekdays.slice(1).map((day, index) => (
                <option key={day} value={index + 1}>
                  {day}
                </option>
              ))}
            </select>
          </label>
        )}
        {schedule.frequency === 'hourly' ? (
          <label className="field">
            <span>Minutes past the hour</span>
            <input type="number" min={0} max={59} step={5} value={schedule.minute} onChange={(event) => set({ minute: Number(event.target.value) })} />
          </label>
        ) : (
          <label className="field">
            <span>At</span>
            <input
              type="time"
              value={time}
              step={300}
              onChange={(event) => {
                const [hour, minute] = event.target.value.split(':').map(Number)
                set({ hour: hour || 0, minute: minute || 0 })
              }}
            />
          </label>
        )}
      </div>
      <fieldset>
        <label className="check">
          <input type="checkbox" checked={schedule.compareWithPrevious} onChange={(event) => set({ compareWithPrevious: event.target.checked })} />
          Compare with the previous run
        </label>
        <label className="check">
          <input type="checkbox" checked={schedule.exportCSV} onChange={(event) => set({ exportCSV: event.target.checked })} />
          Save the Internal HTML table as CSV beside the crawl
        </label>
        <label className="check">
          <input type="checkbox" checked={schedule.exportReport} onChange={(event) => set({ exportReport: event.target.checked })} />
          Save a PDF audit report beside the crawl
        </label>
        <label className="check">
          <input type="checkbox" checked={schedule.isEnabled} onChange={(event) => set({ isEnabled: event.target.checked })} />
          Enabled
        </label>
      </fieldset>
      {configuring && (
        <ConfigDialog
          title="Scheduled Crawl Configuration"
          config={schedule.config}
          editable="all"
          onCancel={() => setConfiguring(false)}
          onSave={(config) => {
            set({ config })
            setConfiguring(false)
          }}
        />
      )}
    </Dialog>
  )
}
