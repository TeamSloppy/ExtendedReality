export const CHANNEL_NAME = 'spatial-video-state-v1'
export const MESSAGE_VERSION = 1

export function createSpatialLayout(pageURL, displayMode = 'window') {
  const panelURL = (panel) => {
    const url = new URL(pageURL)
    url.searchParams.set('panel', panel)
    url.searchParams.set('extendDisplayMode', displayMode)
    return url.href
  }

  return {
    primaryPanelID: 'video',
    panels: [
      {
        id: 'video',
        accessibilityLabel: 'Spatial Video player',
        placement: { yaw: 0, pitch: 0, depth: 0, width: 0.86, height: 0.62, layer: 0 },
      },
      {
        id: 'info',
        accessibilityLabel: 'Now playing information',
        url: panelURL('info'),
        placement: { yaw: -30, pitch: 0, depth: 0.08, width: 0.28, height: 0.56, layer: 1 },
      },
      {
        id: 'queue',
        accessibilityLabel: 'Search, queue, and offline library',
        url: panelURL('queue'),
        placement: { yaw: 30, pitch: 0, depth: 0.08, width: 0.34, height: 0.72, layer: 1 },
      },
      {
        id: 'transport',
        accessibilityLabel: 'Video playback controls',
        url: panelURL('transport'),
        placement: { yaw: 0, pitch: -17, depth: -0.02, width: 0.58, height: 0.17, layer: 2 },
      },
    ],
  }
}

export function spatialMessage(type, payload = {}) {
  return { version: MESSAGE_VERSION, type, ...payload }
}

export function isSpatialMessage(value) {
  return Boolean(value && value.version === MESSAGE_VERSION && typeof value.type === 'string')
}
