import { parseYouTubeVideoID } from './media.js'

let iframeAPI

export function loadYouTubeIframeAPI() {
  if (window.YT?.Player) return Promise.resolve(window.YT)
  if (iframeAPI) return iframeAPI

  iframeAPI = new Promise((resolve, reject) => {
    const previousReady = window.onYouTubeIframeAPIReady
    window.onYouTubeIframeAPIReady = () => {
      previousReady?.()
      resolve(window.YT)
    }

    const existing = document.querySelector('script[data-spatial-video-youtube]')
    if (existing) return
    const script = document.createElement('script')
    script.src = 'https://www.youtube.com/iframe_api'
    script.async = true
    script.dataset.spatialVideoYoutube = 'true'
    script.onerror = () => reject(new Error('Unable to load the YouTube player.'))
    document.head.append(script)
  })
  return iframeAPI
}

function decodeText(value) {
  const document = new DOMParser().parseFromString(String(value ?? ''), 'text/html')
  return document.documentElement.textContent ?? ''
}

function videoFromSearchItem(item) {
  const videoId = item.id?.videoId ?? item.id
  if (!parseYouTubeVideoID(videoId)) return null
  return {
    kind: 'youtube',
    videoId,
    title: decodeText(item.snippet?.title) || `YouTube video ${videoId}`,
    channelTitle: decodeText(item.snippet?.channelTitle) || 'YouTube',
    thumbnailURL: item.snippet?.thumbnails?.medium?.url
      ?? item.snippet?.thumbnails?.default?.url
      ?? `https://i.ytimg.com/vi/${videoId}/mqdefault.jpg`,
  }
}

async function youtubeRequest(path, parameters, apiKey, signal) {
  if (!apiKey.trim()) throw new Error('Add a YouTube Data API key in settings to search.')
  const url = new URL(`https://www.googleapis.com/youtube/v3/${path}`)
  Object.entries({ ...parameters, key: apiKey.trim() }).forEach(([key, value]) => {
    url.searchParams.set(key, value)
  })
  const response = await fetch(url, { credentials: 'omit', signal })
  if (!response.ok) {
    const payload = await response.json().catch(() => null)
    throw new Error(payload?.error?.message || `YouTube API returned HTTP ${response.status}.`)
  }
  return response.json()
}

export async function searchYouTube(query, apiKey, signal) {
  const payload = await youtubeRequest('search', {
    part: 'snippet',
    type: 'video',
    videoEmbeddable: 'true',
    videoSyndicated: 'true',
    safeSearch: 'moderate',
    maxResults: '20',
    q: query.trim(),
  }, apiKey, signal)
  return payload.items.map(videoFromSearchItem).filter(Boolean)
}

export async function lookupYouTubeVideo(videoId, apiKey, signal) {
  const payload = await youtubeRequest('videos', {
    part: 'snippet',
    id: videoId,
  }, apiKey, signal)
  return videoFromSearchItem(payload.items?.[0] ?? { id: videoId })
}

export function youtubeFallbackItem(videoId) {
  return {
    kind: 'youtube',
    videoId,
    title: `YouTube video ${videoId}`,
    channelTitle: 'YouTube',
    thumbnailURL: `https://i.ytimg.com/vi/${videoId}/mqdefault.jpg`,
  }
}
