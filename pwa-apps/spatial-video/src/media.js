export const SUPPORTED_MEDIA_TYPES = Object.freeze({
  'video/mp4': ['mp4', 'm4v'],
  'video/webm': ['webm'],
  'video/quicktime': ['mov'],
  'application/mp4': ['mp4', 'm4v'],
})

const YOUTUBE_ID_PATTERN = /^[A-Za-z0-9_-]{11}$/

export function parseYouTubeVideoID(value) {
  const trimmed = String(value ?? '').trim()
  if (YOUTUBE_ID_PATTERN.test(trimmed)) return trimmed

  let url
  try {
    url = new URL(trimmed)
  } catch {
    return null
  }

  const host = url.hostname.toLowerCase().replace(/^www\./, '')
  let candidate = null
  if (host === 'youtu.be') {
    candidate = url.pathname.split('/').filter(Boolean)[0]
  } else if (host === 'youtube.com' || host.endsWith('.youtube.com')) {
    candidate = url.searchParams.get('v')
    if (!candidate) {
      const parts = url.pathname.split('/').filter(Boolean)
      const marker = parts.findIndex((part) => part === 'shorts' || part === 'embed' || part === 'live')
      candidate = marker >= 0 ? parts[marker + 1] : null
    }
  }

  return candidate && YOUTUBE_ID_PATTERN.test(candidate) ? candidate : null
}

export function normalizeMimeType(value) {
  return String(value ?? '').split(';', 1)[0].trim().toLowerCase()
}

export function fileExtension(value) {
  const clean = String(value ?? '').split(/[?#]/, 1)[0]
  const match = clean.toLowerCase().match(/\.([a-z0-9]+)$/)
  return match?.[1] ?? ''
}

export function inferMediaType(name, declaredType = '') {
  const normalized = normalizeMimeType(declaredType)
  if (SUPPORTED_MEDIA_TYPES[normalized]) return normalized

  const extension = fileExtension(name)
  return Object.entries(SUPPORTED_MEDIA_TYPES)
    .find(([, extensions]) => extensions.includes(extension))?.[0] ?? ''
}

export function validateMediaSource({ name, type }, canPlayType) {
  const mimeType = inferMediaType(name, type)
  if (!mimeType) throw new Error('Choose an MP4, WebM, MOV, or M4V video.')

  const playableType = mimeType === 'application/mp4' ? 'video/mp4' : mimeType
  if (canPlayType && canPlayType(playableType) === '') {
    throw new Error(`This device cannot play ${playableType}.`)
  }
  return { mimeType: playableType, extension: fileExtension(name) || SUPPORTED_MEDIA_TYPES[mimeType][0] }
}

export function sanitizeFilename(value, fallback = 'offline-video') {
  const cleaned = String(value ?? '')
    .replace(/[\\/:*?"<>|\u0000-\u001F]/g, '-')
    .replace(/\s+/g, ' ')
    .trim()
  return (cleaned || fallback).slice(0, 120)
}

export function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes < 0) return 'Unknown size'
  const units = ['B', 'KB', 'MB', 'GB']
  let value = bytes
  let unit = 0
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024
    unit += 1
  }
  return `${value >= 10 || unit === 0 ? value.toFixed(0) : value.toFixed(1)} ${units[unit]}`
}

export function formatDuration(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return '0:00'
  const whole = Math.floor(seconds)
  const hours = Math.floor(whole / 3600)
  const minutes = Math.floor((whole % 3600) / 60)
  const remaining = whole % 60
  return hours > 0
    ? `${hours}:${String(minutes).padStart(2, '0')}:${String(remaining).padStart(2, '0')}`
    : `${minutes}:${String(remaining).padStart(2, '0')}`
}
