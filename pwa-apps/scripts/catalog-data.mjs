export function createCatalog(publicBaseURL) {
  const { baseURL, origin } = normalizeBaseURL(publicBaseURL)

  return {
    schemaVersion: 1,
    apps: [
      {
        id: 'com.extendreality.spatial-board',
        name: 'Spatial Board',
        summary: 'An offline-first spatial whiteboard powered by Excalidraw.',
        developer: 'ExtendReality',
        version: '1.0.0',
        launchURL: `${baseURL}/spatial-board/`,
        universalLink: `${baseURL}/spatial-board/`,
        allowedOrigins: [origin],
        displayModes: ['window', 'widget'],
        requestedCapabilities: [],
        minimumAge: 4,
        accentHex: '#0D9488',
      },
      {
        id: 'com.extendreality.pwa-lab',
        name: 'PWA Lab',
        summary: 'Diagnose offline storage, media permissions, and ExtendReality host APIs.',
        developer: 'ExtendReality',
        version: '1.0.0',
        launchURL: `${baseURL}/pwa-lab/`,
        universalLink: `${baseURL}/pwa-lab/`,
        allowedOrigins: [origin],
        displayModes: ['window', 'widget'],
        requestedCapabilities: ['camera', 'microphone', 'location', 'health', 'focusStatus'],
        minimumAge: 4,
        accentHex: '#22C55E',
      },
    ],
  }
}

export function normalizeBaseURL(value) {
  const url = new URL(value)
  if (url.protocol !== 'https:') {
    throw new Error('PWA_PUBLIC_BASE_URL must use HTTPS.')
  }
  if (url.search || url.hash) {
    throw new Error('PWA_PUBLIC_BASE_URL must not contain a query or fragment.')
  }
  const path = url.pathname.replace(/\/+$/, '')
  return {
    baseURL: `${url.origin}${path}`,
    origin: url.origin,
  }
}
