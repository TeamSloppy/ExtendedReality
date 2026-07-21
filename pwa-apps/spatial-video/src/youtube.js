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
  if (typeof DOMParser !== 'function') {
    return String(value ?? '')
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
  }
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

async function authorizedYouTubeRequest(path, parameters, accessToken, signal) {
  if (!accessToken) throw new Error('Connect your Google account in settings.')
  const url = new URL(`https://www.googleapis.com/youtube/v3/${path}`)
  Object.entries(parameters).forEach(([key, value]) => {
    if (value !== undefined && value !== null && value !== '') url.searchParams.set(key, value)
  })
  const response = await fetch(url, {
    credentials: 'omit',
    headers: { Authorization: `Bearer ${accessToken}` },
    signal,
  })
  if (!response.ok) {
    const payload = await response.json().catch(() => null)
    const error = new Error(payload?.error?.message || `YouTube API returned HTTP ${response.status}.`)
    error.status = response.status
    throw error
  }
  return response.json()
}

export function subscriptionChannelIDs(payload, limit = 24) {
  const ids = payload?.items
    ?.map((item) => item.snippet?.resourceId?.channelId)
    .filter((value) => typeof value === 'string' && value.length > 0) ?? []
  return [...new Set(ids)].slice(0, limit)
}

export function uploadsPlaylists(payload) {
  return payload?.items?.map((item) => ({
    channelID: item.id,
    playlistID: item.contentDetails?.relatedPlaylists?.uploads,
  })).filter((item) => item.channelID && item.playlistID) ?? []
}

export function videoFromPlaylistItem(item) {
  const videoId = item.contentDetails?.videoId ?? item.snippet?.resourceId?.videoId
  if (!parseYouTubeVideoID(videoId)) return null
  const title = decodeText(item.snippet?.title)
  if (!title || title === 'Deleted video' || title === 'Private video') return null
  return {
    kind: 'youtube',
    videoId,
    title,
    channelTitle: decodeText(item.snippet?.videoOwnerChannelTitle ?? item.snippet?.channelTitle) || 'YouTube',
    thumbnailURL: item.snippet?.thumbnails?.medium?.url
      ?? item.snippet?.thumbnails?.default?.url
      ?? `https://i.ytimg.com/vi/${videoId}/mqdefault.jpg`,
    publishedAt: item.contentDetails?.videoPublishedAt ?? item.snippet?.publishedAt ?? '',
  }
}

async function mapWithConcurrency(items, limit, operation) {
  const results = new Array(items.length)
  let cursor = 0
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (cursor < items.length) {
      const index = cursor
      cursor += 1
      results[index] = await operation(items[index])
    }
  })
  await Promise.all(workers)
  return results
}

export async function fetchSubscriptionFeed(accessToken, signal, options = {}) {
  const maxChannels = Math.min(50, Math.max(1, options.maxChannels ?? 24))
  const videosPerChannel = Math.min(5, Math.max(1, options.videosPerChannel ?? 2))
  const subscriptionPayload = await authorizedYouTubeRequest('subscriptions', {
    part: 'snippet',
    mine: 'true',
    order: 'unread',
    maxResults: String(maxChannels),
  }, accessToken, signal)
  const channelIDs = subscriptionChannelIDs(subscriptionPayload, maxChannels)
  if (!channelIDs.length) return []

  const channelPayload = await authorizedYouTubeRequest('channels', {
    part: 'contentDetails',
    id: channelIDs.join(','),
    maxResults: String(channelIDs.length),
  }, accessToken, signal)
  const playlists = uploadsPlaylists(channelPayload)
  const batches = await mapWithConcurrency(playlists, 6, async ({ playlistID }) => {
    const payload = await authorizedYouTubeRequest('playlistItems', {
      part: 'snippet,contentDetails',
      playlistId: playlistID,
      maxResults: String(videosPerChannel),
    }, accessToken, signal)
    return payload.items?.map(videoFromPlaylistItem).filter(Boolean) ?? []
  })

  const unique = new Map()
  for (const item of batches.flat()) {
    if (!unique.has(item.videoId)) unique.set(item.videoId, item)
  }
  return [...unique.values()]
    .sort((left, right) => String(right.publishedAt).localeCompare(String(left.publishedAt)))
    .slice(0, options.maxVideos ?? 40)
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
