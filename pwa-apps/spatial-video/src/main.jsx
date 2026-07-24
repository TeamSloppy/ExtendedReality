import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import ReactDOM from 'react-dom/client'
import {
  AlertCircle,
  ArrowLeft,
  Check,
  ChevronRight,
  CircleOff,
  CloudDownload,
  CloudOff,
  Download,
  ExternalLink,
  FileVideo,
  FolderOpen,
  Gauge,
  HardDrive,
  Home,
  Info,
  Library,
  ListPlus,
  LoaderCircle,
  LogIn,
  LogOut,
  MonitorPlay,
  MoreHorizontal,
  Pause,
  Play,
  PlaySquare,
  Plus,
  RefreshCw,
  Radio,
  RotateCcw,
  RotateCw,
  Search,
  Settings,
  Square,
  Trash2,
  Upload,
  Users,
  Wifi,
  X,
} from 'lucide-react'
import './styles.css'
import { formatBytes, formatDuration, parseYouTubeVideoID } from './media.js'
import {
  cleanupOfflineStorage,
  deleteOfflineMedia,
  downloadRemoteMedia,
  getSetting,
  importLocalMedia,
  offlineMediaObjectURL,
  setSetting,
} from './storage.js'
import { CHANNEL_NAME, createSpatialLayout, isSpatialMessage, spatialMessage } from './spatial.js'
import {
  fetchSubscriptionFeed,
  loadYouTubeIframeAPI,
  lookupYouTubeVideo,
  searchYouTube,
  youtubeFallbackItem,
} from './youtube.js'
import {
  DEFAULT_GOOGLE_OAUTH_CLIENT_ID,
  isGoogleWebClientID,
  normalizeGoogleClientID,
  requestYouTubeAccessToken,
  revokeYouTubeAccessToken,
} from './youtube-auth.js'

const params = new URLSearchParams(window.location.search)
const panel = params.get('panel') ?? 'primary'
const displayMode = params.get('extendDisplayMode') ?? 'window'
const SNAPSHOT_KEY = 'spatial-video.snapshot.v1'
const COMMAND_KEY = 'spatial-video.command.v1'

const emptyPlayback = {
  ready: false,
  playing: false,
  buffering: false,
  currentTime: 0,
  duration: 0,
  error: '',
}

const emptySharedState = {
  current: null,
  playback: emptyPlayback,
  results: [],
  subscriptions: [],
  queue: [],
  offline: [],
  query: '',
  searchStatus: '',
  subscriptionStatus: '',
  youtubeConnected: false,
  online: navigator.onLine,
}

function readSnapshot() {
  try {
    return { ...emptySharedState, ...JSON.parse(localStorage.getItem(SNAPSHOT_KEY) ?? 'null') }
  } catch {
    return emptySharedState
  }
}

function useSpatialBus({ primary, sharedState, onCommand }) {
  const channelRef = useRef(null)
  const sharedRef = useRef(sharedState)
  const commandRef = useRef(onCommand)
  const [remoteState, setRemoteState] = useState(readSnapshot)
  sharedRef.current = sharedState
  commandRef.current = onCommand

  useEffect(() => {
    const channel = typeof BroadcastChannel === 'function' ? new BroadcastChannel(CHANNEL_NAME) : null
    channelRef.current = channel

    const receive = (message) => {
      if (!isSpatialMessage(message)) return
      if (primary && message.type === 'request-state') {
        channel?.postMessage(spatialMessage('state', { state: sharedRef.current }))
      } else if (primary && message.type === 'command') {
        commandRef.current?.(message.command)
      } else if (!primary && message.type === 'state') {
        setRemoteState({ ...emptySharedState, ...message.state })
      }
    }
    if (channel) channel.onmessage = (event) => receive(event.data)

    const storageListener = (event) => {
      if (!primary && event.key === SNAPSHOT_KEY && event.newValue) {
        try { setRemoteState({ ...emptySharedState, ...JSON.parse(event.newValue) }) } catch { /* ignore */ }
      }
      if (primary && event.key === COMMAND_KEY && event.newValue) {
        try { receive(JSON.parse(event.newValue).message) } catch { /* ignore */ }
      }
    }
    window.addEventListener('storage', storageListener)
    if (!primary) channel?.postMessage(spatialMessage('request-state'))

    return () => {
      window.removeEventListener('storage', storageListener)
      channel?.close()
      channelRef.current = null
    }
  }, [primary])

  useEffect(() => {
    if (!primary) return
    const message = spatialMessage('state', { state: sharedState })
    channelRef.current?.postMessage(message)
    try { localStorage.setItem(SNAPSHOT_KEY, JSON.stringify(sharedState)) } catch { /* storage may be unavailable */ }
  }, [primary, sharedState])

  const sendCommand = useCallback((command) => {
    const message = spatialMessage('command', { command })
    channelRef.current?.postMessage(message)
    if (!channelRef.current) {
      try { localStorage.setItem(COMMAND_KEY, JSON.stringify({ nonce: crypto.randomUUID(), message })) } catch { /* ignore */ }
    }
  }, [])

  return { remoteState, sendCommand }
}

function YouTubePlayer({ item, controllerRef, onPlayback }) {
  const hostRef = useRef(null)

  useEffect(() => {
    let player
    let timer
    let cancelled = false
    onPlayback({ ...emptyPlayback, buffering: true })

    const mount = document.createElement('div')
    mount.className = 'youtube-player-mount'
    hostRef.current?.replaceChildren(mount)

    loadYouTubeIframeAPI().then((YT) => {
      if (cancelled || !hostRef.current) return
      player = new YT.Player(mount, {
        videoId: item.videoId,
        width: '100%',
        height: '100%',
        playerVars: { playsinline: 1, controls: 0, rel: 0, origin: window.location.origin },
        events: {
          onReady: () => {
            controllerRef.current = {
              play: () => player.playVideo(),
              pause: () => player.pauseVideo(),
              seekBy: (seconds) => player.seekTo(Math.max(0, player.getCurrentTime() + seconds), true),
              seekTo: (seconds) => player.seekTo(Math.max(0, seconds), true),
            }
            const report = () => onPlayback((previous) => ({
              ...previous,
              ready: true,
              currentTime: Number(player.getCurrentTime()) || 0,
              duration: Number(player.getDuration()) || 0,
            }))
            report()
            timer = window.setInterval(report, 500)
          },
          onStateChange: (event) => onPlayback((previous) => ({
            ...previous,
            ready: true,
            playing: event.data === YT.PlayerState.PLAYING
              || (event.data === YT.PlayerState.BUFFERING && previous.playing),
            buffering: event.data === YT.PlayerState.BUFFERING,
            currentTime: Number(player.getCurrentTime()) || previous.currentTime,
            duration: Number(player.getDuration()) || previous.duration,
            error: '',
          })),
          onError: (event) => {
            const embedDenied = event.data === 101 || event.data === 150
            onPlayback((previous) => ({
              ...previous,
              ready: false,
              playing: false,
              buffering: false,
              error: embedDenied ? 'The creator disabled embedded playback.' : `YouTube player error ${event.data}.`,
            }))
          },
        },
      })
    }).catch((error) => onPlayback((previous) => ({ ...previous, buffering: false, error: error.message })))

    return () => {
      cancelled = true
      window.clearInterval(timer)
      controllerRef.current = null
      player?.destroy?.()
      hostRef.current?.replaceChildren()
    }
  }, [item.videoId, controllerRef, onPlayback])

  return <div className="youtube-player" ref={hostRef} aria-label={`Playing ${item.title} from YouTube`} />
}

function OfflinePlayer({ item, controllerRef, onPlayback }) {
  const videoRef = useRef(null)
  const [source, setSource] = useState('')

  useEffect(() => {
    let cancelled = false
    let objectURL = ''
    onPlayback({ ...emptyPlayback, buffering: true })
    offlineMediaObjectURL(item).then((url) => {
      if (cancelled) return URL.revokeObjectURL(url)
      objectURL = url
      setSource(url)
    }).catch((error) => onPlayback({ ...emptyPlayback, error: error.message }))
    return () => {
      cancelled = true
      if (objectURL) URL.revokeObjectURL(objectURL)
    }
  }, [item.id, onPlayback])

  useEffect(() => {
    const video = videoRef.current
    if (!video) return
    controllerRef.current = {
      play: () => video.play(),
      pause: () => video.pause(),
      seekBy: (seconds) => { video.currentTime = Math.max(0, video.currentTime + seconds) },
      seekTo: (seconds) => { video.currentTime = Math.max(0, seconds) },
    }
    return () => { controllerRef.current = null }
  }, [source, controllerRef])

  const report = (changes = {}) => {
    const video = videoRef.current
    onPlayback((previous) => ({
      ...previous,
      ready: video?.readyState >= 1,
      playing: video ? !video.paused : false,
      currentTime: video?.currentTime || 0,
      duration: Number.isFinite(video?.duration) ? video.duration : 0,
      ...changes,
    }))
  }

  return (
    <video
      ref={videoRef}
      className="offline-player"
      src={source}
      playsInline
      onLoadedMetadata={() => report({ buffering: false, error: '' })}
      onTimeUpdate={() => report()}
      onPlay={() => report({ playing: true, buffering: false })}
      onPause={() => report({ playing: false })}
      onWaiting={() => report({ buffering: true })}
      onPlaying={() => report({ playing: true, buffering: false })}
      onError={() => report({ playing: false, buffering: false, error: 'This offline video could not be decoded.' })}
    />
  )
}

function EmptyPlayer() {
  return (
    <div className="empty-player">
      <span className="empty-orbit"><MonitorPlay aria-hidden="true" /></span>
      <h1>Your video, in space</h1>
      <p>Paste a YouTube link, search online, or open a video from your private offline library.</p>
    </div>
  )
}

function PlayerPanel({ state, controllerRef, onPlayback, onCommand, showChrome = true }) {
  const current = state.current
  return (
    <section className="panel player-panel" aria-label="Video player">
      {current?.kind === 'youtube' && <YouTubePlayer item={current} controllerRef={controllerRef} onPlayback={onPlayback} />}
      {current?.kind === 'offline' && <OfflinePlayer item={current} controllerRef={controllerRef} onPlayback={onPlayback} />}
      {!current && <EmptyPlayer />}
      {showChrome && (
        <header className="player-chrome">
          <div className="brand-lockup">
            <button className="chrome-back-button" type="button" aria-label="Back to library" onClick={() => onCommand({ type: 'browse-library' })}><ArrowLeft aria-hidden="true" /></button>
            <span className="app-mark"><Play aria-hidden="true" /></span><strong>Spatial Video</strong>
          </div>
          <div className="chrome-actions">
            <span className={state.online ? 'network-pill' : 'network-pill offline'}>
              {state.online ? <Wifi aria-hidden="true" /> : <CloudOff aria-hidden="true" />}
              {state.online ? 'Online' : 'Offline'}
            </span>
            <button className="icon-button" type="button" aria-label="Add offline video" onClick={() => onCommand({ type: 'open-import' })}><Plus aria-hidden="true" /></button>
            <button className="icon-button" type="button" aria-label="Open settings" onClick={() => onCommand({ type: 'open-settings' })}><Settings aria-hidden="true" /></button>
          </div>
        </header>
      )}
      {state.playback.buffering && <div className="buffering" aria-live="polite"><LoaderCircle className="spin" aria-hidden="true" /> Buffering</div>}
      {state.playback.error && <div className="player-error" role="alert"><AlertCircle aria-hidden="true" /><span>{state.playback.error}</span></div>}
    </section>
  )
}

function InfoPanel({ state }) {
  const current = state.current
  return (
    <section className="panel info-panel" aria-label="Now playing information">
      <div className="eyebrow"><Info aria-hidden="true" /> Now playing</div>
      {current ? (
        <>
          {current.thumbnailURL
            ? <img className="info-poster" src={current.thumbnailURL} alt="" />
            : <div className="info-poster poster-placeholder"><FileVideo aria-hidden="true" /></div>}
          <div className="source-row">
            <span className={current.kind === 'youtube' ? 'source-badge youtube' : 'source-badge offline'}>
              {current.kind === 'youtube' ? <PlaySquare aria-hidden="true" /> : <HardDrive aria-hidden="true" />}
              {current.kind === 'youtube' ? 'YouTube' : 'Offline'}
            </span>
            <span className="playback-state">{state.playback.buffering ? 'Buffering' : state.playback.playing ? 'Playing' : 'Paused'}</span>
          </div>
          <h2>{current.title}</h2>
          <p className="channel-title">{current.channelTitle ?? current.filename}</p>
          {current.kind === 'offline' && (
            <dl className="media-facts"><div><dt>Format</dt><dd>{current.extension.toUpperCase()}</dd></div><div><dt>Size</dt><dd>{formatBytes(current.bytes)}</dd></div></dl>
          )}
          {current.kind === 'youtube' && (
            <a className="external-link" href={`https://www.youtube.com/watch?v=${current.videoId}`} target="_blank" rel="noreferrer">
              Open on YouTube <ExternalLink aria-hidden="true" />
            </a>
          )}
        </>
      ) : (
        <div className="empty-info"><CircleOff aria-hidden="true" /><h2>Nothing playing</h2><p>Choose a result or an offline video.</p></div>
      )}
    </section>
  )
}

function ResultCard({ item, queued, onPlay, onQueue }) {
  return (
    <article className="result-card">
      <button type="button" className="result-main" onClick={onPlay}>
        <img src={item.thumbnailURL} alt="" />
        <span><strong>{item.title}</strong><small>{item.channelTitle}</small></span>
      </button>
      <button type="button" className="queue-button" aria-label={queued ? 'Already in queue' : `Add ${item.title} to queue`} disabled={queued} onClick={onQueue}>
        {queued ? <Check aria-hidden="true" /> : <ListPlus aria-hidden="true" />}
      </button>
    </article>
  )
}

function QueuePanel({ state, onCommand }) {
  const [tab, setTab] = useState('online')
  const [query, setQuery] = useState(state.query)

  useEffect(() => { if (state.query) setQuery(state.query) }, [state.query])
  const submit = (event) => {
    event.preventDefault()
    onCommand({ type: 'search', query })
  }

  return (
    <section className="panel queue-panel" aria-label="Search, queue, and offline library">
      <div className="queue-header">
        <div><span className="eyebrow"><Library aria-hidden="true" /> Library</span><h2>Find your next video</h2></div>
        <button className="icon-button" type="button" aria-label="Open settings" onClick={() => onCommand({ type: 'open-settings' })}><Settings aria-hidden="true" /></button>
      </div>
      <div className="segmented source-tabs" role="tablist" aria-label="Video source">
        <button role="tab" aria-selected={tab === 'online'} className={tab === 'online' ? 'active' : ''} onClick={() => setTab('online')}><PlaySquare aria-hidden="true" /> Online</button>
        <button role="tab" aria-selected={tab === 'subscriptions'} className={tab === 'subscriptions' ? 'active' : ''} onClick={() => setTab('subscriptions')}><Users aria-hidden="true" /> Subscriptions</button>
        <button role="tab" aria-selected={tab === 'offline'} className={tab === 'offline' ? 'active' : ''} onClick={() => setTab('offline')}><HardDrive aria-hidden="true" /> Offline <span>{state.offline.length}</span></button>
      </div>

      {tab === 'online' && (
        <>
          <form className="search-form" onSubmit={submit}>
            <label className="sr-only" htmlFor="video-search">Search YouTube or paste a video link</label>
            <Search aria-hidden="true" />
            <input id="video-search" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search or paste a YouTube link" autoComplete="off" />
            {query && <button type="button" className="clear-search" aria-label="Clear search" onClick={() => setQuery('')}><X aria-hidden="true" /></button>}
            <button type="submit" className="submit-search" aria-label="Search videos"><ChevronRight aria-hidden="true" /></button>
          </form>
          <p className={state.searchStatus.startsWith('Error:') ? 'inline-status error' : 'inline-status'} aria-live="polite">{state.searchStatus || 'Public search requires your own browser-restricted API key.'}</p>
          <div className="result-list">
            {state.results.map((item) => (
              <ResultCard
                key={item.videoId}
                item={item}
                queued={state.queue.some((entry) => entry.videoId === item.videoId)}
                onPlay={() => onCommand({ type: 'load-youtube', item })}
                onQueue={() => onCommand({ type: 'enqueue', item })}
              />
            ))}
            {!state.results.length && state.queue.map((item) => (
              <ResultCard key={item.videoId} item={item} queued onPlay={() => onCommand({ type: 'load-youtube', item })} />
            ))}
            {!state.results.length && !state.queue.length && (
              <div className="empty-list"><PlaySquare aria-hidden="true" /><strong>URL-only mode is ready</strong><span>Paste a link above, or add an API key for search.</span></div>
            )}
          </div>
        </>
      )}

      {tab === 'subscriptions' && (
        <>
          <div className="subscription-toolbar">
            <div>
              <strong>{state.youtubeConnected ? 'Latest from your channels' : 'Connect your Google account'}</strong>
              <small>{state.youtubeConnected ? 'A recent-upload feed, sorted newest first.' : 'Read-only access to your YouTube subscriptions.'}</small>
            </div>
            <button
              type="button"
              className="queue-button"
              aria-label={state.youtubeConnected ? 'Refresh subscriptions' : 'Open Google connection settings'}
              onClick={() => onCommand({ type: state.youtubeConnected ? 'refresh-subscriptions' : 'open-settings' })}
            >
              {state.youtubeConnected ? <RefreshCw aria-hidden="true" /> : <LogIn aria-hidden="true" />}
            </button>
          </div>
          <p className={state.subscriptionStatus.startsWith('Error:') ? 'inline-status error' : 'inline-status'} aria-live="polite">
            {state.subscriptionStatus || (state.youtubeConnected ? 'Refresh to load recent uploads.' : 'Your access token is kept in memory only.')}
          </p>
          <div className="result-list">
            {state.subscriptions.map((item) => (
              <ResultCard
                key={item.videoId}
                item={item}
                queued={state.queue.some((entry) => entry.videoId === item.videoId)}
                onPlay={() => onCommand({ type: 'load-youtube', item })}
                onQueue={() => onCommand({ type: 'enqueue', item })}
              />
            ))}
            {!state.subscriptions.length && (
              <div className="empty-list">
                <Users aria-hidden="true" />
                <strong>{state.youtubeConnected ? 'No recent uploads found' : 'Subscriptions need Google access'}</strong>
                <span>{state.youtubeConnected ? 'Try refreshing again later.' : 'Add a Web client ID and connect in Settings.'}</span>
              </div>
            )}
          </div>
        </>
      )}

      {tab === 'offline' && (
        <>
          <button className="add-offline" type="button" onClick={() => onCommand({ type: 'open-import' })}><Download aria-hidden="true" /><span><strong>Add for offline</strong><small>MP4, WebM, MOV or M4V</small></span><ChevronRight aria-hidden="true" /></button>
          <div className="result-list offline-list">
            {state.offline.map((item) => (
              <article className="offline-card" key={item.id}>
                <button type="button" className="offline-main" onClick={() => onCommand({ type: 'load-offline', item })}>
                  <span className="file-icon"><FileVideo aria-hidden="true" /></span>
                  <span><strong>{item.title}</strong><small>{item.extension.toUpperCase()} · {formatBytes(item.bytes)}</small></span>
                </button>
                <button type="button" className="queue-button danger" aria-label={`Delete ${item.title}`} onClick={() => onCommand({ type: 'delete-offline', item })}><Trash2 aria-hidden="true" /></button>
              </article>
            ))}
            {!state.offline.length && <div className="empty-list"><FolderOpen aria-hidden="true" /><strong>Your offline library is empty</strong><span>Imported videos stay in this app's private storage.</span></div>}
          </div>
        </>
      )}
    </section>
  )
}

function TransportPanel({ state, onCommand }) {
  const { playback } = state
  const progress = playback.duration > 0 ? Math.min(100, (playback.currentTime / playback.duration) * 100) : 0
  const disabled = !state.current
  return (
    <section className="panel transport-panel" aria-label="Playback controls">
      <div className="transport-topline">
        <div className="transport-title"><span>{state.current?.title ?? 'Choose a video'}</span><small>{state.current?.channelTitle ?? state.current?.filename ?? 'Spatial Video'}</small></div>
        <div className="transport-buttons">
          <button type="button" disabled={disabled} aria-label="Back 10 seconds" onClick={() => onCommand({ type: 'seek-by', seconds: -10 })}><RotateCcw aria-hidden="true" /><small>10</small></button>
          <button type="button" className="play-button" disabled={disabled} aria-label={playback.playing ? 'Pause' : 'Play'} onClick={() => onCommand({ type: 'toggle-playback' })}>
            {playback.playing ? <Pause aria-hidden="true" /> : <Play aria-hidden="true" />}
          </button>
          <button type="button" disabled={disabled} aria-label="Forward 10 seconds" onClick={() => onCommand({ type: 'seek-by', seconds: 10 })}><RotateCw aria-hidden="true" /><small>10</small></button>
        </div>
        <span className="timecode">{formatDuration(playback.currentTime)} / {formatDuration(playback.duration)}</span>
      </div>
      <label className="timeline-label">
        <span className="sr-only">Playback position</span>
        <input type="range" min="0" max={playback.duration || 1} step="0.1" value={Math.min(playback.currentTime, playback.duration || 1)} disabled={disabled || !playback.duration} onChange={(event) => onCommand({ type: 'seek-to', seconds: Number(event.target.value) })} style={{ '--progress': `${progress}%` }} />
      </label>
    </section>
  )
}

function WidgetPanel({ state, onCommand }) {
  return (
    <main className="widget-shell">
      <section className="widget-card">
        <div className="widget-art">{state.current?.thumbnailURL ? <img src={state.current.thumbnailURL} alt="" /> : <Play aria-hidden="true" />}</div>
        <div className="widget-copy"><span>{state.current?.kind === 'offline' ? 'Offline video' : 'Spatial Video'}</span><strong>{state.current?.title ?? 'Nothing playing'}</strong><small>{state.current?.channelTitle ?? state.current?.filename ?? 'Open the full app to choose a video'}</small></div>
        <button className="play-button" type="button" disabled={!state.current} aria-label={state.playback.playing ? 'Pause' : 'Play'} onClick={() => onCommand({ type: 'toggle-playback' })}>{state.playback.playing ? <Pause aria-hidden="true" /> : <Play aria-hidden="true" />}</button>
      </section>
    </main>
  )
}

function ModalFrame({ title, description, onClose, children }) {
  const closeRef = useRef(null)
  const dialogRef = useRef(null)
  useEffect(() => {
    closeRef.current?.focus()
    const keydown = (event) => {
      if (event.key === 'Escape') onClose()
      if (event.key !== 'Tab') return
      const focusable = [...dialogRef.current.querySelectorAll('button:not(:disabled), input:not(:disabled), a[href]')]
      if (!focusable.length) return
      const first = focusable[0]
      const last = focusable[focusable.length - 1]
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus() }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus() }
    }
    window.addEventListener('keydown', keydown)
    return () => window.removeEventListener('keydown', keydown)
  }, [onClose])
  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose() }}>
      <section ref={dialogRef} className="modal-card" role="dialog" aria-modal="true" aria-labelledby="modal-title" aria-describedby="modal-description">
        <header><div><h2 id="modal-title">{title}</h2><p id="modal-description">{description}</p></div><button ref={closeRef} type="button" className="icon-button" aria-label="Close" onClick={onClose}><X aria-hidden="true" /></button></header>
        {children}
      </section>
    </div>
  )
}

function SettingsModal({ initialKey, initialClientID, authSession, authBusy, authError, onConnect, onDisconnect, onSave, onClose }) {
  const [key, setKey] = useState(initialKey)
  const [clientID, setClientID] = useState(initialClientID)
  const clientIDValid = !clientID.trim() || isGoogleWebClientID(clientID)
  return (
    <ModalFrame title="Online video settings" description="API credentials stay inside Spatial Video. Google access tokens are kept in memory only." onClose={onClose}>
      <label className="field-label" htmlFor="youtube-api-key">YouTube Data API key</label>
      <input className="modal-input" id="youtube-api-key" type="password" value={key} onChange={(event) => setKey(event.target.value)} autoComplete="off" placeholder="Paste a browser-restricted key" />
      <div className="privacy-note"><Gauge aria-hidden="true" /><p>Restrict the key to the deployed HTTPS origin. Direct URL playback works without a key.</p></div>
      <div className="settings-divider" />
      <label className="field-label" htmlFor="google-client-id">Google OAuth Web client ID</label>
      <input
        className="modal-input"
        id="google-client-id"
        type="text"
        value={clientID}
        aria-invalid={!clientIDValid}
        onChange={(event) => setClientID(event.target.value)}
        autoComplete="off"
        placeholder="123456789-example.apps.googleusercontent.com"
      />
      {!clientIDValid && <p className="field-error">Enter a Google OAuth Web client ID ending in apps.googleusercontent.com.</p>}
      <div className="oauth-card">
        <div className={authSession ? 'oauth-status connected' : 'oauth-status'}>
          <span>{authSession ? <Check aria-hidden="true" /> : <Users aria-hidden="true" />}</span>
          <div><strong>{authSession ? 'Google connected' : 'Subscriptions disconnected'}</strong><small>Requests only YouTube read-only access.</small></div>
        </div>
        {authSession ? (
          <button type="button" className="secondary-button" disabled={authBusy} onClick={onDisconnect}><LogOut aria-hidden="true" /> Disconnect</button>
        ) : (
          <button type="button" className="primary-button" disabled={authBusy || !isGoogleWebClientID(clientID)} onClick={() => onConnect({ clientID: clientID.trim(), apiKey: key.trim() })}>
            {authBusy ? <LoaderCircle className="spin" aria-hidden="true" /> : <LogIn aria-hidden="true" />} Connect Google
          </button>
        )}
      </div>
      {authError && <p className="modal-error" role="alert"><AlertCircle aria-hidden="true" />{authError}</p>}
      <div className="privacy-note"><Info aria-hidden="true" /><p>This is a latest-uploads feed from subscribed channels. The YouTube Data API does not expose the personalized Home recommendations feed.</p></div>
      <footer className="modal-actions">
        <button type="button" className="secondary-button" onClick={() => { setKey(''); setClientID(DEFAULT_GOOGLE_OAUTH_CLIENT_ID) }}>Reset fields</button>
        <button type="button" className="primary-button" disabled={!clientIDValid} onClick={() => onSave({ apiKey: key.trim(), clientID: clientID.trim() })}>Save settings</button>
      </footer>
    </ModalFrame>
  )
}

function ImportModal({ onImported, onClose }) {
  const [mode, setMode] = useState('file')
  const [file, setFile] = useState(null)
  const [url, setURL] = useState('')
  const [confirmed, setConfirmed] = useState(false)
  const [progress, setProgress] = useState(null)
  const [error, setError] = useState('')
  const abortRef = useRef(null)
  const busy = Boolean(progress)

  const start = async () => {
    if (!confirmed) return setError('Confirm that you have permission to store this media.')
    setError('')
    const controller = new AbortController()
    abortRef.current = controller
    setProgress({ written: 0, total: mode === 'file' ? file?.size ?? 0 : 0 })
    const options = { signal: controller.signal, onProgress: setProgress }
    try {
      const record = mode === 'file' ? await importLocalMedia(file, options) : await downloadRemoteMedia(url, options)
      await onImported(record)
      onClose()
    } catch (cause) {
      if (cause.name !== 'AbortError') setError(cause.message)
      setProgress(null)
    } finally {
      abortRef.current = null
    }
  }

  const percent = progress?.total > 0 ? Math.min(100, (progress.written / progress.total) * 100) : null
  return (
    <ModalFrame title="Add an offline video" description="Keep an original-format copy in this app's private storage." onClose={busy ? () => {} : onClose}>
      <div className="segmented modal-segmented" role="tablist" aria-label="Import source">
        <button role="tab" aria-selected={mode === 'file'} className={mode === 'file' ? 'active' : ''} disabled={busy} onClick={() => setMode('file')}><Upload aria-hidden="true" /> Local file</button>
        <button role="tab" aria-selected={mode === 'url'} className={mode === 'url' ? 'active' : ''} disabled={busy} onClick={() => setMode('url')}><CloudDownload aria-hidden="true" /> Direct URL</button>
      </div>
      {mode === 'file' ? (
        <label className="file-picker"><input type="file" accept="video/mp4,video/webm,video/quicktime,.m4v" disabled={busy} onChange={(event) => setFile(event.target.files?.[0] ?? null)} /><FolderOpen aria-hidden="true" /><span><strong>{file?.name ?? 'Choose a video file'}</strong><small>{file ? formatBytes(file.size) : 'MP4, WebM, MOV or M4V'}</small></span></label>
      ) : (
        <><label className="field-label" htmlFor="direct-video-url">Direct HTTPS media URL</label><input className="modal-input" id="direct-video-url" type="url" value={url} disabled={busy} onChange={(event) => setURL(event.target.value)} placeholder="https://media.example.com/video.mp4" /></>
      )}
      <label className="permission-check"><input type="checkbox" checked={confirmed} disabled={busy} onChange={(event) => setConfirmed(event.target.checked)} /><span>I own this video or have permission to keep an offline copy.</span></label>
      {progress && <div className="download-progress" aria-live="polite"><div><span>{percent === null ? 'Downloading…' : `${percent.toFixed(0)}%`}</span><span>{formatBytes(progress.written)}{progress.total ? ` / ${formatBytes(progress.total)}` : ''}</span></div><progress max="100" value={percent ?? undefined} /></div>}
      {error && <p className="modal-error" role="alert"><AlertCircle aria-hidden="true" />{error}</p>}
      <footer className="modal-actions">
        {busy ? <button type="button" className="secondary-button" onClick={() => abortRef.current?.abort()}><Square aria-hidden="true" /> Cancel download</button> : <button type="button" className="secondary-button" onClick={onClose}>Cancel</button>}
        <button type="button" className="primary-button" disabled={busy || !confirmed || (mode === 'file' ? !file : !url.trim())} onClick={start}><Download aria-hidden="true" /> Save offline</button>
      </footer>
    </ModalFrame>
  )
}

const sectionDetails = {
  home: { title: 'Watch in a new dimension', description: 'Your videos, subscriptions, and offline library in one place.' },
  discover: { title: 'Discover', description: 'Search YouTube or open a direct video link.' },
  subscriptions: { title: 'Subscriptions', description: 'The latest uploads from channels you follow.' },
  saved: { title: 'Saved', description: 'Videos waiting in your queue.' },
  offline: { title: 'Offline', description: 'Original-quality files stored privately on this device.' },
}

function itemKey(item) {
  return item.kind === 'offline' || item.id ? `offline-${item.id}` : `youtube-${item.videoId}`
}

function LibraryMediaCard({ item, queued, onPlay, onQueue }) {
  const offlineItem = item.kind === 'offline' || Boolean(item.id)
  const source = offlineItem ? 'Offline' : item.channelTitle || 'YouTube'
  const meta = offlineItem
    ? `${String(item.extension || 'video').toUpperCase()} · ${formatBytes(item.bytes || 0)}`
    : item.publishedAt
      ? new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric' }).format(new Date(item.publishedAt))
      : queued ? 'Saved to your queue' : 'YouTube video'

  return (
    <article className="library-media-card">
      <button type="button" className="library-card-main" onClick={onPlay} aria-label={`Open ${item.title}`}>
        <span className={item.thumbnailURL ? 'library-thumbnail' : 'library-thumbnail placeholder'}>
          {item.thumbnailURL ? <img src={item.thumbnailURL} alt="" /> : <FileVideo aria-hidden="true" />}
          <span className={offlineItem ? 'thumbnail-badge offline' : 'thumbnail-badge'}>{offlineItem ? <HardDrive aria-hidden="true" /> : <PlaySquare aria-hidden="true" />}{offlineItem ? 'Local' : 'Online'}</span>
          <span className="thumbnail-play"><Play aria-hidden="true" /></span>
        </span>
        <span className="library-card-copy">
          <span className={offlineItem ? 'channel-avatar offline' : 'channel-avatar'}>{offlineItem ? <HardDrive aria-hidden="true" /> : <Play aria-hidden="true" />}</span>
          <span className="library-card-text"><strong>{item.title}</strong><small>{source}</small><small>{meta}</small></span>
        </span>
      </button>
      {!offlineItem && onQueue && (
        <button type="button" className="card-action" aria-label={queued ? `${item.title} is saved` : `Save ${item.title}`} disabled={queued} onClick={onQueue}>
          {queued ? <Check aria-hidden="true" /> : <MoreHorizontal aria-hidden="true" />}
        </button>
      )}
    </article>
  )
}

function LibraryBrowser({ state, onCommand }) {
  const [section, setSection] = useState('home')
  const [query, setQuery] = useState(state.query)
  const searchRef = useRef(null)
  useEffect(() => { if (state.query) setQuery(state.query) }, [state.query])

  const allItems = useMemo(() => {
    const seen = new Set()
    return [...(state.current ? [state.current] : []), ...state.results, ...state.subscriptions, ...state.queue, ...state.offline]
      .map((item) => ({ ...item, kind: item.kind || (item.id ? 'offline' : 'youtube') }))
      .filter((item) => {
        const key = itemKey(item)
        if (seen.has(key)) return false
        seen.add(key)
        return true
      })
  }, [state.current, state.results, state.subscriptions, state.queue, state.offline])

  const items = section === 'home'
    ? allItems
    : section === 'discover'
      ? state.results
      : section === 'subscriptions'
        ? state.subscriptions
        : section === 'saved'
          ? state.queue
          : state.offline.map((item) => ({ ...item, kind: 'offline' }))
  const details = sectionDetails[section]
  const status = section === 'subscriptions' ? state.subscriptionStatus : section === 'discover' ? state.searchStatus : ''

  const submit = (event) => {
    event.preventDefault()
    setSection('discover')
    onCommand({ type: 'search', query })
  }

  const showSearch = () => {
    setSection('discover')
    window.requestAnimationFrame(() => searchRef.current?.focus())
  }

  const navItems = [
    { id: 'home', label: 'Home', icon: Home },
    { id: 'discover', label: 'Discover', icon: Search },
    { id: 'subscriptions', label: 'Following', icon: Radio },
    { id: 'saved', label: 'Saved', icon: Library },
    { id: 'offline', label: 'Offline', icon: HardDrive },
  ]

  return (
    <main className="library-shell">
      <section className="library-window" aria-label="Spatial Video library">
        <header className="library-topbar">
          <div className="library-brand"><span className="brand-menu" aria-hidden="true"><span /><span /><span /></span><span className="app-mark"><Play aria-hidden="true" /></span><strong>Spatial <span>Video</span></strong></div>
          <form className="library-search" onSubmit={submit}>
            <label className="sr-only" htmlFor="library-search-input">Search YouTube or paste a video link</label>
            <Search aria-hidden="true" />
            <input ref={searchRef} id="library-search-input" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search or paste a YouTube link" autoComplete="off" />
            {query && <button type="button" className="clear-search" aria-label="Clear search" onClick={() => setQuery('')}><X aria-hidden="true" /></button>}
            <button type="submit" className="library-search-submit" aria-label="Search"><ChevronRight aria-hidden="true" /></button>
          </form>
          <div className="library-actions">
            <span className={state.online ? 'library-network' : 'library-network offline'} aria-label={state.online ? 'Online' : 'Offline'}>{state.online ? <Wifi aria-hidden="true" /> : <CloudOff aria-hidden="true" />}</span>
            <button className="topbar-action" type="button" aria-label="Add offline video" onClick={() => onCommand({ type: 'open-import' })}><Plus aria-hidden="true" /></button>
            <button className="topbar-action" type="button" aria-label="Open settings" onClick={() => onCommand({ type: 'open-settings' })}><Settings aria-hidden="true" /></button>
          </div>
        </header>

        <aside className="library-rail" aria-label="Library sections">
          <nav>
            {navItems.map(({ id, label, icon: Icon }) => (
              <button key={id} type="button" className={section === id ? 'active' : ''} aria-current={section === id ? 'page' : undefined} onClick={() => setSection(id)}>
                <Icon aria-hidden="true" /><span>{label}</span>
                {id === 'saved' && state.queue.length > 0 && <small>{state.queue.length}</small>}
              </button>
            ))}
          </nav>
          <button className="rail-settings" type="button" onClick={() => onCommand({ type: 'open-settings' })}><Settings aria-hidden="true" /><span>Settings</span></button>
        </aside>

        <div className="library-content">
          <div className="library-heading">
            <div><span className="library-kicker"><span /> Spatial collection</span><h1>{details.title}</h1><p>{details.description}</p></div>
            {section === 'subscriptions' && (
              <button type="button" className="refresh-button" onClick={() => onCommand({ type: state.youtubeConnected ? 'refresh-subscriptions' : 'open-settings' })}>
                {state.youtubeConnected ? <RefreshCw aria-hidden="true" /> : <LogIn aria-hidden="true" />}{state.youtubeConnected ? 'Refresh' : 'Connect'}
              </button>
            )}
            {section === 'offline' && <button type="button" className="refresh-button" onClick={() => onCommand({ type: 'open-import' })}><Plus aria-hidden="true" />Add video</button>}
          </div>

          <div className="library-filters" aria-label="Content filters">
            {navItems.slice(0, 5).map(({ id, label }) => <button key={id} type="button" className={section === id ? 'active' : ''} onClick={() => setSection(id)}>{label}</button>)}
          </div>

          {status && <p className={status.startsWith('Error:') ? 'library-status error' : 'library-status'} aria-live="polite">{status}</p>}

          {items.length ? (
            <div className="library-grid">
              {items.map((item) => (
                <LibraryMediaCard
                  key={itemKey(item)}
                  item={item}
                  queued={item.kind !== 'offline' && state.queue.some((entry) => entry.videoId === item.videoId)}
                  onPlay={() => onCommand({ type: item.kind === 'offline' || item.id ? 'load-offline' : 'load-youtube', item })}
                  onQueue={item.kind === 'offline' || item.id ? null : () => onCommand({ type: 'enqueue', item })}
                />
              ))}
            </div>
          ) : (
            <div className="library-empty">
              <div className="empty-intro"><span><MonitorPlay aria-hidden="true" /></span><h2>Build your spatial library</h2><p>Find an online video, connect your subscriptions, or bring a file you already own.</p></div>
              <div className="quick-actions">
                <button type="button" onClick={showSearch}><Search aria-hidden="true" /><span><strong>Search videos</strong><small>Paste a link or find something new</small></span><ChevronRight aria-hidden="true" /></button>
                <button type="button" onClick={() => onCommand({ type: 'open-settings' })}><Radio aria-hidden="true" /><span><strong>Connect subscriptions</strong><small>Read-only access to recent uploads</small></span><ChevronRight aria-hidden="true" /></button>
                <button type="button" onClick={() => onCommand({ type: 'open-import' })}><Download aria-hidden="true" /><span><strong>Add offline</strong><small>Keep a private original-quality copy</small></span><ChevronRight aria-hidden="true" /></button>
              </div>
            </div>
          )}
        </div>
      </section>
    </main>
  )
}

function BrowserLayout({ state, controllerRef, onPlayback, onCommand, playerOnly = false, screen = 'library' }) {
  if (!playerOnly && screen === 'library') return <LibraryBrowser state={state} onCommand={onCommand} />
  return (
    <main className={playerOnly ? 'single-panel-shell' : 'app-shell'}>
      <PlayerPanel state={state} controllerRef={controllerRef} onPlayback={onPlayback} onCommand={onCommand} />
      {!playerOnly && <InfoPanel state={state} />}
      {!playerOnly && <QueuePanel state={state} onCommand={onCommand} />}
      {!playerOnly && <TransportPanel state={state} onCommand={onCommand} />}
    </main>
  )
}

function PrimaryApp() {
  const [screen, setScreen] = useState('library')
  const [current, setCurrent] = useState(null)
  const [playback, setPlayback] = useState(emptyPlayback)
  const [results, setResults] = useState([])
  const [subscriptions, setSubscriptions] = useState([])
  const [queue, setQueue] = useState([])
  const [offline, setOffline] = useState([])
  const [query, setQuery] = useState('')
  const [searchStatus, setSearchStatus] = useState('')
  const [subscriptionStatus, setSubscriptionStatus] = useState('')
  const [online, setOnline] = useState(navigator.onLine)
  const [apiKey, setAPIKey] = useState('')
  const [googleClientID, setGoogleClientID] = useState(DEFAULT_GOOGLE_OAUTH_CLIENT_ID)
  const [authSession, setAuthSession] = useState(null)
  const [authBusy, setAuthBusy] = useState(false)
  const [authError, setAuthError] = useState('')
  const [modal, setModal] = useState(null)
  const [spatialActive, setSpatialActive] = useState(false)
  const [hydrated, setHydrated] = useState(false)
  const playerController = useRef(null)
  const searchController = useRef(null)
  const subscriptionController = useRef(null)
  const layoutRequest = useRef(0)

  const youtubeConnected = Boolean(authSession?.accessToken && authSession.expiresAt > Date.now())
  const sharedState = useMemo(() => ({
    current,
    playback,
    results,
    subscriptions,
    queue,
    offline,
    query,
    searchStatus,
    subscriptionStatus,
    youtubeConnected,
    online,
  }), [current, playback, results, subscriptions, queue, offline, query, searchStatus, subscriptionStatus, youtubeConnected, online])
  const sharedRef = useRef(sharedState)
  sharedRef.current = sharedState

  useEffect(() => {
    Promise.all([
      getSetting('youtubeApiKey', ''),
      getSetting('googleOAuthClientID', DEFAULT_GOOGLE_OAUTH_CLIENT_ID),
      getSetting('queue', []),
      getSetting('current', null),
      cleanupOfflineStorage(),
    ]).then(([storedKey, storedClientID, storedQueue, storedCurrent, storedOffline]) => {
      setAPIKey(storedKey)
      setGoogleClientID(normalizeGoogleClientID(storedClientID) || DEFAULT_GOOGLE_OAUTH_CLIENT_ID)
      setQueue(Array.isArray(storedQueue) ? storedQueue : [])
      if (storedCurrent?.kind === 'offline') {
        const existing = storedOffline.find((item) => item.id === storedCurrent.id)
        setCurrent(existing ? { ...existing, kind: 'offline' } : null)
      } else if (storedCurrent?.kind === 'youtube') {
        setCurrent(storedCurrent)
      }
      setOffline(storedOffline)
      setHydrated(true)
    }).catch((error) => {
      setSearchStatus(`Error: ${error.message}`)
      setHydrated(true)
    })
  }, [])

  useEffect(() => {
    if (!authSession?.expiresAt) return
    const remaining = authSession.expiresAt - Date.now()
    if (remaining <= 0) {
      setAuthSession(null)
      setSubscriptionStatus('Google session expired. Connect again to refresh subscriptions.')
      return
    }
    const timer = window.setTimeout(() => {
      setAuthSession(null)
      setSubscriptionStatus('Google session expired. Connect again to refresh subscriptions.')
    }, remaining)
    return () => window.clearTimeout(timer)
  }, [authSession])

  useEffect(() => {
    const update = () => setOnline(navigator.onLine)
    window.addEventListener('online', update)
    window.addEventListener('offline', update)
    return () => { window.removeEventListener('online', update); window.removeEventListener('offline', update) }
  }, [])

  useEffect(() => {
    if (!hydrated) return
    setSetting('queue', queue).catch(() => {})
  }, [queue, hydrated])
  useEffect(() => {
    if (!hydrated) return
    setSetting('current', current).catch(() => {})
  }, [current, hydrated])

  useEffect(() => {
    if (displayMode === 'widget' || !window.extendReality?.windows) return
    return () => { window.extendReality?.windows?.reset?.().catch?.(() => {}) }
  }, [])

  useEffect(() => {
    if (displayMode === 'widget' || !window.extendReality?.windows) return
    const request = ++layoutRequest.current
    const includesPlaybackPanels = playback.playing
    window.extendReality.windows
      .setLayout(createSpatialLayout(window.location.href, displayMode, includesPlaybackPanels))
      .then(() => {
        if (request === layoutRequest.current) setSpatialActive(includesPlaybackPanels)
      })
      .catch(() => {
        if (request === layoutRequest.current) setSpatialActive(false)
      })
  }, [playback.playing])

  const loadYouTube = useCallback((item) => {
    setCurrent({ ...item, kind: 'youtube' })
    setPlayback(emptyPlayback)
    setSearchStatus('')
    setScreen('watch')
  }, [])

  const handleSearch = useCallback(async (value) => {
    const submitted = String(value ?? '').trim()
    setQuery(submitted)
    if (!submitted) { setResults([]); setSearchStatus(''); return }
    searchController.current?.abort()
    const controller = new AbortController()
    searchController.current = controller
    setSearchStatus('Searching…')
    try {
      const videoId = parseYouTubeVideoID(submitted)
      if (videoId) {
        const item = apiKey ? await lookupYouTubeVideo(videoId, apiKey, controller.signal) : youtubeFallbackItem(videoId)
        setResults([item])
        loadYouTube(item)
        setSearchStatus(apiKey ? 'Video loaded.' : 'Video loaded in URL-only mode.')
      } else {
        if (!navigator.onLine) throw new Error('Reconnect to search YouTube. Offline videos remain available.')
        const found = await searchYouTube(submitted, apiKey, controller.signal)
        setResults(found)
        setSearchStatus(found.length ? `${found.length} results from YouTube.` : 'No embeddable videos found.')
      }
    } catch (error) {
      if (error.name !== 'AbortError') setSearchStatus(`Error: ${error.message}`)
    }
  }, [apiKey, loadYouTube])

  const refreshSubscriptions = useCallback(async (session = authSession) => {
    if (!session?.accessToken || session.expiresAt <= Date.now()) {
      setAuthSession(null)
      setSubscriptionStatus('Error: Connect your Google account in settings.')
      return
    }
    if (!navigator.onLine) {
      setSubscriptionStatus('Error: Reconnect to refresh subscriptions.')
      return
    }
    subscriptionController.current?.abort()
    const controller = new AbortController()
    subscriptionController.current = controller
    setSubscriptionStatus('Loading subscriptions…')
    try {
      const found = await fetchSubscriptionFeed(session.accessToken, controller.signal)
      setSubscriptions(found)
      setSubscriptionStatus(found.length ? `${found.length} recent uploads from your subscriptions.` : 'No recent uploads found.')
    } catch (error) {
      if (error.name === 'AbortError') return
      if (error.status === 401) setAuthSession(null)
      setSubscriptionStatus(`Error: ${error.status === 401 ? 'Google session expired. Connect again.' : error.message}`)
    }
  }, [authSession])

  const playerAction = useCallback((command) => {
    const controller = playerController.current
    if (!controller) return
    if (command.type === 'toggle-playback') {
      const result = sharedRef.current.playback.playing ? controller.pause() : controller.play()
      result?.catch?.((error) => setPlayback((previous) => ({ ...previous, error: error.message })))
    } else if (command.type === 'seek-by') controller.seekBy(command.seconds)
    else if (command.type === 'seek-to') controller.seekTo(command.seconds)
  }, [])

  const handleCommand = useCallback((command) => {
    if (!command?.type) return
    if (command.type === 'search') handleSearch(command.query)
    else if (command.type === 'refresh-subscriptions') refreshSubscriptions()
    else if (command.type === 'load-youtube') loadYouTube(command.item)
    else if (command.type === 'enqueue') setQueue((items) => items.some((item) => item.videoId === command.item.videoId) ? items : [...items, command.item])
    else if (command.type === 'load-offline') { setCurrent({ ...command.item, kind: 'offline' }); setPlayback(emptyPlayback); setScreen('watch') }
    else if (command.type === 'browse-library') {
      playerController.current?.pause?.()
      setPlayback(emptyPlayback)
      setCurrent(null)
      setScreen('library')
    }
    else if (command.type === 'delete-offline') {
      deleteOfflineMedia(command.item).then(() => {
        setOffline((items) => items.filter((item) => item.id !== command.item.id))
        setCurrent((item) => item?.kind === 'offline' && item.id === command.item.id ? null : item)
      }).catch((error) => setSearchStatus(`Error: ${error.message}`))
    } else if (command.type === 'open-settings') setModal('settings')
    else if (command.type === 'open-import') setModal('import')
    else playerAction(command)
  }, [handleSearch, loadYouTube, playerAction, refreshSubscriptions])

  useSpatialBus({ primary: true, sharedState, onCommand: handleCommand })

  const saveSettings = async ({ apiKey: nextAPIKey, clientID }) => {
    await Promise.all([
      setSetting('youtubeApiKey', nextAPIKey),
      setSetting('googleOAuthClientID', clientID),
    ])
    setAPIKey(nextAPIKey)
    setGoogleClientID(clientID)
    setModal(null)
    setSearchStatus(nextAPIKey ? 'API key saved locally.' : 'API key cleared. URL-only mode is active.')
  }

  const connectGoogle = async ({ clientID, apiKey: nextAPIKey }) => {
    setAuthBusy(true)
    setAuthError('')
    try {
      await Promise.all([
        setSetting('youtubeApiKey', nextAPIKey),
        setSetting('googleOAuthClientID', clientID),
      ])
      setAPIKey(nextAPIKey)
      setGoogleClientID(clientID)
      const session = await requestYouTubeAccessToken(clientID)
      setAuthSession(session)
      setSubscriptionStatus('Google connected. Loading subscriptions…')
      await refreshSubscriptions(session)
    } catch (error) {
      setAuthError(error.message)
    } finally {
      setAuthBusy(false)
    }
  }

  const disconnectGoogle = async () => {
    const accessToken = authSession?.accessToken
    setAuthSession(null)
    setSubscriptions([])
    setSubscriptionStatus('Google disconnected. Access token removed from memory.')
    setAuthError('')
    if (accessToken) revokeYouTubeAccessToken(accessToken).catch(() => {})
  }

  const imported = async (record) => {
    setOffline((items) => [record, ...items])
    setCurrent({ ...record, kind: 'offline' })
    setPlayback(emptyPlayback)
    setScreen('watch')
  }

  if (!hydrated) return <main className="loading-screen"><LoaderCircle className="spin" aria-hidden="true" /><span>Opening Spatial Video…</span></main>
  if (displayMode === 'widget') return <WidgetPanel state={sharedState} onCommand={handleCommand} />

  return (
    <>
      <BrowserLayout
        state={sharedState}
        controllerRef={playerController}
        onPlayback={setPlayback}
        onCommand={handleCommand}
        playerOnly={spatialActive}
        screen={screen}
      />
      {modal === 'settings' && (
        <SettingsModal
          initialKey={apiKey}
          initialClientID={googleClientID}
          authSession={authSession}
          authBusy={authBusy}
          authError={authError}
          onConnect={connectGoogle}
          onDisconnect={disconnectGoogle}
          onSave={saveSettings}
          onClose={() => setModal(null)}
        />
      )}
      {modal === 'import' && <ImportModal onImported={imported} onClose={() => setModal(null)} />}
    </>
  )
}

function SecondaryApp({ panelName }) {
  const { remoteState, sendCommand } = useSpatialBus({ primary: false, sharedState: null, onCommand: null })
  return (
    <main className="single-panel-shell">
      {panelName === 'info' && <InfoPanel state={remoteState} />}
      {panelName === 'queue' && <QueuePanel state={remoteState} onCommand={sendCommand} />}
      {panelName === 'transport' && <TransportPanel state={remoteState} onCommand={sendCommand} />}
    </main>
  )
}

const reactRoot = window.__spatialVideoReactRoot ?? ReactDOM.createRoot(document.getElementById('root'))
window.__spatialVideoReactRoot = reactRoot
reactRoot.render(
  <React.StrictMode>
    {panel === 'primary' ? <PrimaryApp /> : <SecondaryApp panelName={panel} />}
  </React.StrictMode>,
)
