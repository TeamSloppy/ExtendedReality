import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import ReactDOM from 'react-dom/client'
import { Excalidraw } from '@excalidraw/excalidraw'
import { AppWindow, Check, CloudOff, LayoutPanelTop, LoaderCircle } from 'lucide-react'
import './styles.css'
import { loadBoard, saveBoard } from './storage.js'

const displayMode = new URLSearchParams(window.location.search).get('extendDisplayMode') ?? 'window'

function initialScene(savedBoard) {
  if (!savedBoard) {
    return {
      elements: [],
      appState: { viewBackgroundColor: '#f0fdfa' },
      scrollToContent: true,
    }
  }

  return {
    elements: savedBoard.elements ?? [],
    files: savedBoard.files ?? {},
    appState: {
      viewBackgroundColor: savedBoard.backgroundColor ?? '#f0fdfa',
    },
    scrollToContent: true,
  }
}

function SpatialBoard() {
  const [savedBoard, setSavedBoard] = useState(undefined)
  const [loadError, setLoadError] = useState('')
  const [saveState, setSaveState] = useState('saved')
  const [online, setOnline] = useState(navigator.onLine)
  const saveTimer = useRef(null)
  const isWidget = displayMode === 'widget'

  useEffect(() => {
    loadBoard()
      .then((board) => setSavedBoard(board ?? null))
      .catch((error) => {
        setLoadError(error.message)
        setSavedBoard(null)
      })

    const updateNetworkState = () => setOnline(navigator.onLine)
    window.addEventListener('online', updateNetworkState)
    window.addEventListener('offline', updateNetworkState)
    return () => {
      window.removeEventListener('online', updateNetworkState)
      window.removeEventListener('offline', updateNetworkState)
      window.clearTimeout(saveTimer.current)
    }
  }, [])

  const data = useMemo(() => initialScene(savedBoard), [savedBoard])

  const handleChange = useCallback((elements, appState, files) => {
    window.clearTimeout(saveTimer.current)
    setSaveState('saving')
    saveTimer.current = window.setTimeout(async () => {
      try {
        await saveBoard({
          elements,
          files,
          backgroundColor: appState.viewBackgroundColor,
          updatedAt: new Date().toISOString(),
        })
        setSaveState('saved')
      } catch {
        setSaveState('error')
      }
    }, 500)
  }, [])

  if (savedBoard === undefined) {
    return (
      <main className="loading-screen" aria-live="polite">
        <LoaderCircle aria-hidden="true" className="spin" />
        <span>Opening your board…</span>
      </main>
    )
  }

  return (
    <main className={isWidget ? 'app-shell widget-shell' : 'app-shell'}>
      <header className="status-bar">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true"><LayoutPanelTop /></span>
          <span className="brand-copy">
            <strong>Spatial Board</strong>
            <small>{isWidget ? 'Compact canvas' : 'Offline canvas'}</small>
          </span>
        </div>
        <div className="status-actions" aria-live="polite">
          <span className={online ? 'status-pill' : 'status-pill warning'}>
            {online ? <Check aria-hidden="true" /> : <CloudOff aria-hidden="true" />}
            {online ? (saveState === 'saving' ? 'Saving' : 'Saved') : 'Offline'}
          </span>
          {isWidget && (
            <a className="open-editor" href="./?extendDisplayMode=window">
              <AppWindow aria-hidden="true" />
              Editor
            </a>
          )}
        </div>
      </header>

      {loadError && <p className="error-banner" role="alert">Storage unavailable: {loadError}</p>}
      <section className="canvas" aria-label="Drawing canvas">
        <Excalidraw
          initialData={data}
          onChange={handleChange}
          viewModeEnabled={isWidget}
          zenModeEnabled={isWidget}
          theme="light"
        />
      </section>
    </main>
  )
}

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <SpatialBoard />
  </React.StrictMode>,
)
