import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import ReactDOM from 'react-dom/client'
import {
  Activity,
  AppWindow,
  Camera,
  CheckCircle2,
  Circle,
  CloudOff,
  Database,
  ExternalLink,
  FlaskConical,
  Focus,
  HardDrive,
  HeartPulse,
  LoaderCircle,
  MapPin,
  Mic,
  Play,
  RefreshCw,
  ServerCog,
  ShieldCheck,
  Square,
  Wifi,
  XCircle,
} from 'lucide-react'
import './styles.css'

const displayMode = new URLSearchParams(window.location.search).get('extendDisplayMode') ?? 'window'

const initialResults = {
  host: { status: 'idle', detail: 'Not checked' },
  serviceWorker: { status: 'idle', detail: 'Not checked' },
  indexedDB: { status: 'idle', detail: 'Not checked' },
  cache: { status: 'idle', detail: 'Not checked' },
  quota: { status: 'idle', detail: 'Not checked' },
  network: { status: navigator.onLine ? 'pass' : 'warn', detail: navigator.onLine ? 'Online' : 'Offline' },
  camera: { status: 'idle', detail: 'Requires permission' },
  microphone: { status: 'idle', detail: 'Requires permission' },
  location: { status: 'idle', detail: 'Requires host permission' },
  health: { status: 'idle', detail: 'Requires host permission' },
  focus: { status: 'idle', detail: 'Requires host permission' },
  spatialWindows: { status: 'idle', detail: 'Requires host permission' },
}

function formatBytes(bytes) {
  if (!Number.isFinite(bytes)) return 'Unavailable'
  const units = ['B', 'KB', 'MB', 'GB']
  let value = bytes
  let unit = 0
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024
    unit += 1
  }
  return `${value.toFixed(unit === 0 ? 0 : 1)} ${units[unit]}`
}

function indexedDBProbe() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open('extend-reality-pwa-lab', 1)
    request.onerror = () => reject(request.error)
    request.onupgradeneeded = () => request.result.createObjectStore('diagnostics')
    request.onsuccess = () => {
      const database = request.result
      const transaction = database.transaction('diagnostics', 'readwrite')
      const store = transaction.objectStore('diagnostics')
      const value = { checkedAt: new Date().toISOString(), nonce: crypto.randomUUID() }
      store.put(value, 'last-check')
      const read = store.get('last-check')
      read.onerror = () => reject(read.error)
      read.onsuccess = () => {
        database.close()
        resolve(read.result)
      }
    }
  })
}

function ResultIcon({ status }) {
  if (status === 'running') return <LoaderCircle className="spin" aria-label="Running" />
  if (status === 'pass') return <CheckCircle2 aria-label="Passed" />
  if (status === 'warn') return <CloudOff aria-label="Warning" />
  if (status === 'fail') return <XCircle aria-label="Failed" />
  return <Circle aria-label="Not checked" />
}

function TestCard({ id, icon: Icon, title, description, result, actionLabel, onRun, children }) {
  return (
    <article className={`test-card ${result.status}`}>
      <div className="card-heading">
        <span className="card-icon" aria-hidden="true"><Icon /></span>
        <div>
          <h2>{title}</h2>
          <p>{description}</p>
        </div>
        <span className="result-icon"><ResultIcon status={result.status} /></span>
      </div>
      <p className="result-detail" aria-live="polite">{result.detail}</p>
      {children}
      {onRun && (
        <button type="button" className="card-button" onClick={onRun} disabled={result.status === 'running'}>
          {result.status === 'running' ? <LoaderCircle className="spin" aria-hidden="true" /> : <Play aria-hidden="true" />}
          {actionLabel ?? 'Run test'}
        </button>
      )}
    </article>
  )
}

function PWALab() {
  const [results, setResults] = useState(initialResults)
  const [cameraStream, setCameraStream] = useState(null)
  const [microphoneStream, setMicrophoneStream] = useState(null)
  const [audioLevel, setAudioLevel] = useState(0)
  const videoRef = useRef(null)
  const audioFrame = useRef(null)
  const isWidget = displayMode === 'widget'

  const setResult = useCallback((id, status, detail) => {
    setResults((current) => ({ ...current, [id]: { status, detail } }))
  }, [])

  const execute = useCallback(async (id, operation) => {
    setResult(id, 'running', 'Checking…')
    try {
      const detail = await operation()
      setResult(id, 'pass', detail)
    } catch (error) {
      setResult(id, 'fail', error instanceof Error ? error.message : String(error))
    }
  }, [setResult])

  const safeTests = useMemo(() => ({
    host: async () => {
      const api = window.extendReality
      if (!api) return `Browser mode · ${displayMode}`
      return `ExtendReality API v${api.version} · ${displayMode}`
    },
    serviceWorker: async () => {
      if (!('serviceWorker' in navigator)) throw new Error('Service Worker API unavailable')
      const registration = await navigator.serviceWorker.ready
      return `Active · scope ${new URL(registration.scope).pathname}`
    },
    indexedDB: async () => {
      const value = await indexedDBProbe()
      return `Write/read passed · ${value.nonce.slice(0, 8)}`
    },
    cache: async () => {
      const cache = await caches.open('extend-reality-pwa-lab-probe')
      const request = new Request(new URL('probe.txt', window.location.href))
      await cache.put(request, new Response('ExtendReality cache probe'))
      const response = await cache.match(request)
      if ((await response?.text()) !== 'ExtendReality cache probe') throw new Error('Cached response mismatch')
      return 'Cache write/read passed'
    },
    quota: async () => {
      if (!navigator.storage?.estimate) throw new Error('Storage estimate unavailable')
      const estimate = await navigator.storage.estimate()
      return `${formatBytes(estimate.usage)} used of ${formatBytes(estimate.quota)}`
    },
  }), [])

  const runSafeTests = useCallback(async () => {
    await Promise.all(Object.entries(safeTests).map(([id, operation]) => execute(id, operation)))
  }, [execute, safeTests])

  useEffect(() => {
    runSafeTests()
    const networkChanged = () => setResult('network', navigator.onLine ? 'pass' : 'warn', navigator.onLine ? 'Online' : 'Offline')
    window.addEventListener('online', networkChanged)
    window.addEventListener('offline', networkChanged)
    return () => {
      window.removeEventListener('online', networkChanged)
      window.removeEventListener('offline', networkChanged)
      cameraStream?.getTracks().forEach((track) => track.stop())
      microphoneStream?.getTracks().forEach((track) => track.stop())
      cancelAnimationFrame(audioFrame.current)
    }
  }, []) // Run diagnostics once when the app opens.

  useEffect(() => {
    if (videoRef.current) videoRef.current.srcObject = cameraStream
  }, [cameraStream])

  const startCamera = () => execute('camera', async () => {
    const stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' }, audio: false })
    setCameraStream(stream)
    return `${stream.getVideoTracks()[0]?.label || 'Camera'} active`
  })

  const stopCamera = () => {
    cameraStream?.getTracks().forEach((track) => track.stop())
    setCameraStream(null)
    setResult('camera', 'idle', 'Stopped')
  }

  const startMicrophone = () => execute('microphone', async () => {
    const stream = await navigator.mediaDevices.getUserMedia({ video: false, audio: true })
    setMicrophoneStream(stream)
    const context = new AudioContext()
    const analyser = context.createAnalyser()
    analyser.fftSize = 256
    context.createMediaStreamSource(stream).connect(analyser)
    const samples = new Uint8Array(analyser.frequencyBinCount)
    const update = () => {
      analyser.getByteFrequencyData(samples)
      setAudioLevel(Math.min(100, Math.round(samples.reduce((sum, value) => sum + value, 0) / samples.length)))
      audioFrame.current = requestAnimationFrame(update)
    }
    update()
    return `${stream.getAudioTracks()[0]?.label || 'Microphone'} active`
  })

  const stopMicrophone = () => {
    microphoneStream?.getTracks().forEach((track) => track.stop())
    setMicrophoneStream(null)
    cancelAnimationFrame(audioFrame.current)
    setAudioLevel(0)
    setResult('microphone', 'idle', 'Stopped')
  }

  const readHostCapability = (id, method, format) => execute(id, async () => {
    const api = window.extendReality
    if (!api || typeof api[method] !== 'function') throw new Error('ExtendReality host API unavailable')
    return format(await api[method]())
  })

  const createSpatialLayout = () => execute('spatialWindows', async () => {
    const windows = window.extendReality?.windows
    if (!windows) throw new Error('Spatial window API unavailable')
    await windows.setLayout({
      primaryPanelID: 'primary',
      panels: [
        {
          id: 'primary',
          accessibilityLabel: 'PWA Lab diagnostics',
          placement: { yaw: 0, pitch: 0, depth: 0, width: 0.72, height: 0.68, layer: 0 },
        },
        {
          id: 'spatial-tools',
          accessibilityLabel: 'PWA Lab spatial tools',
          url: './?extendDisplayMode=widget',
          placement: { yaw: 24, pitch: 1, depth: 0.08, width: 0.28, height: 0.42, layer: 1 },
        },
      ],
    })
    await windows.update('spatial-tools', {
      accessibilityLabel: 'PWA Lab spatial tools',
      url: './?extendDisplayMode=widget',
      placement: { yaw: 22, pitch: 0, depth: 0.05, width: 0.28, height: 0.40, layer: 1 },
    })
    return 'Created and updated a same-origin secondary panel'
  })

  const resetSpatialLayout = () => execute('spatialWindows', async () => {
    const windows = window.extendReality?.windows
    if (!windows) throw new Error('Spatial window API unavailable')
    await windows.reset()
    return 'Composition reset to the primary panel'
  })

  const passed = Object.values(results).filter((result) => result.status === 'pass').length
  const failed = Object.values(results).filter((result) => result.status === 'fail').length

  return (
    <main className={isWidget ? 'lab-shell widget' : 'lab-shell'}>
      <header className="lab-header">
        <div className="lab-brand">
          <span className="lab-mark" aria-hidden="true"><FlaskConical /></span>
          <div>
            <p className="eyebrow">ExtendReality diagnostics</p>
            <h1>PWA Lab</h1>
          </div>
        </div>
        <div className="header-actions">
          <span className="mode-pill"><AppWindow aria-hidden="true" />{displayMode}</span>
          <button type="button" className="primary-button" onClick={runSafeTests}>
            <RefreshCw aria-hidden="true" /> Run safe checks
          </button>
        </div>
      </header>

      <section className="summary" aria-live="polite">
        <div><strong>{passed}</strong><span>passed</span></div>
        <div><strong>{failed}</strong><span>failed</span></div>
        <div><strong>{window.extendReality?.version ?? 'Web'}</strong><span>host API</span></div>
        <div><strong>{navigator.onLine ? 'On' : 'Off'}</strong><span>network</span></div>
      </section>

      <section className="lab-grid" aria-label="PWA diagnostics">
        <TestCard id="host" icon={ServerCog} title="Host runtime" description="Detect injected API and display mode." result={results.host} onRun={() => execute('host', safeTests.host)} />
        <TestCard id="serviceWorker" icon={ShieldCheck} title="Service Worker" description="Confirm an active offline worker." result={results.serviceWorker} onRun={() => execute('serviceWorker', safeTests.serviceWorker)} />
        <TestCard id="indexedDB" icon={Database} title="IndexedDB" description="Persist data inside this app's private store." result={results.indexedDB} onRun={() => execute('indexedDB', safeTests.indexedDB)} />
        <TestCard id="cache" icon={HardDrive} title="Cache Storage" description="Write and read an offline response." result={results.cache} onRun={() => execute('cache', safeTests.cache)} />
        <TestCard id="quota" icon={Activity} title="Storage quota" description="Inspect WebKit storage allocation." result={results.quota} onRun={() => execute('quota', safeTests.quota)} />
        <TestCard id="network" icon={Wifi} title="Network state" description="Observe online and offline transitions." result={results.network} />

        {!isWidget && (
          <>
            <TestCard id="camera" icon={Camera} title="Camera" description="Exercise the host-managed WebRTC permission." result={results.camera} actionLabel={cameraStream ? undefined : 'Start camera'} onRun={cameraStream ? undefined : startCamera}>
              {cameraStream && (
                <div className="media-preview">
                  <video ref={videoRef} autoPlay muted playsInline aria-label="Camera preview" />
                  <button type="button" className="stop-button" onClick={stopCamera}><Square aria-hidden="true" /> Stop</button>
                </div>
              )}
            </TestCard>
            <TestCard id="microphone" icon={Mic} title="Microphone" description="Exercise audio capture and display input level." result={results.microphone} actionLabel={microphoneStream ? undefined : 'Start microphone'} onRun={microphoneStream ? undefined : startMicrophone}>
              {microphoneStream && (
                <div className="meter-row">
                  <div className="meter" aria-label={`Microphone level ${audioLevel}%`}><span style={{ width: `${audioLevel}%` }} /></div>
                  <button type="button" className="stop-button" onClick={stopMicrophone}><Square aria-hidden="true" /> Stop</button>
                </div>
              )}
            </TestCard>
            <TestCard id="location" icon={MapPin} title="Location" description="Read foreground location through host API v3." result={results.location} actionLabel="Read location" onRun={() => readHostCapability('location', 'getLocation', (value) => `${value.latitude.toFixed(5)}, ${value.longitude.toFixed(5)} · ±${Math.round(value.horizontalAccuracy)} m`)} />
            <TestCard id="health" icon={HeartPulse} title="Health summary" description="Read today's limited HealthKit summary." result={results.health} actionLabel="Read summary" onRun={() => readHostCapability('health', 'getHealthSummary', (value) => `${Math.round(value.steps)} steps · ${Math.round(value.activeEnergyKilocalories)} kcal${value.latestHeartRateBPM ? ` · ${Math.round(value.latestHeartRateBPM)} bpm` : ''}`)} />
            <TestCard id="focus" icon={Focus} title="Focus status" description="Read whether ExtendReality notifications are silenced." result={results.focus} actionLabel="Read status" onRun={() => readHostCapability('focus', 'getFocusStatus', (value) => value.isFocused ? 'Focus is silencing notifications' : 'Notifications are not silenced')} />
            <TestCard id="spatialWindows" icon={AppWindow} title="Spatial windows" description="Create, update, and reset a same-origin panel composition." result={results.spatialWindows} actionLabel="Create panels" onRun={createSpatialLayout}>
              <button type="button" className="stop-button" onClick={resetSpatialLayout}><Square aria-hidden="true" /> Reset layout</button>
            </TestCard>
            <article className="test-card external-card">
              <div className="card-heading">
                <span className="card-icon" aria-hidden="true"><ExternalLink /></span>
                <div><h2>Origin boundary</h2><p>Open an external HTTPS link and confirm it leaves the PWA.</p></div>
              </div>
              <a className="card-button" href="https://example.com/" target="_self"><ExternalLink aria-hidden="true" /> Open example.com</a>
            </article>
          </>
        )}
      </section>
    </main>
  )
}

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <PWALab />
  </React.StrictMode>,
)
