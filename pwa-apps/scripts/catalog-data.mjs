export function createCatalog(publicOrigin) {
  const origin = normalizeOrigin(publicOrigin)

  return {
    schemaVersion: 1,
    apps: [
      {
        id: 'com.extendreality.spatial-board',
        name: 'Spatial Board',
        summary: 'An offline-first spatial whiteboard powered by Excalidraw.',
        developer: 'ExtendReality',
        version: '1.0.0',
        launchURL: `${origin}/spatial-board/`,
        universalLink: `${origin}/spatial-board/`,
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
        launchURL: `${origin}/pwa-lab/`,
        universalLink: `${origin}/pwa-lab/`,
        allowedOrigins: [origin],
        displayModes: ['window', 'widget'],
        requestedCapabilities: ['camera', 'microphone', 'location', 'health', 'focusStatus'],
        minimumAge: 4,
        accentHex: '#22C55E',
      },
    ],
  }
}

export function normalizeOrigin(value) {
  const url = new URL(value)
  if (url.protocol !== 'https:') {
    throw new Error('PWA_PUBLIC_ORIGIN must use HTTPS.')
  }
  if (url.pathname !== '/' || url.search || url.hash) {
    throw new Error('PWA_PUBLIC_ORIGIN must contain only scheme and host.')
  }
  return url.origin
}
