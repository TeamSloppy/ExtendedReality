import assert from 'node:assert/strict'
import test from 'node:test'
import {
  formatBytes,
  inferMediaType,
  parseYouTubeVideoID,
  validateMediaSource,
} from '../spatial-video/src/media.js'
import {
  createSpatialLayout,
  isSpatialMessage,
  spatialMessage,
} from '../spatial-video/src/spatial.js'
import {
  DEFAULT_GOOGLE_OAUTH_CLIENT_ID,
  isGoogleWebClientID,
  normalizeGoogleClientID,
} from '../spatial-video/src/youtube-auth.js'
import {
  fetchSubscriptionFeed,
  subscriptionChannelIDs,
  uploadsPlaylists,
  videoFromPlaylistItem,
} from '../spatial-video/src/youtube.js'

test('parses supported YouTube video identifiers and rejects unrelated URLs', () => {
  assert.equal(parseYouTubeVideoID('dQw4w9WgXcQ'), 'dQw4w9WgXcQ')
  assert.equal(parseYouTubeVideoID('https://youtu.be/dQw4w9WgXcQ?t=20'), 'dQw4w9WgXcQ')
  assert.equal(parseYouTubeVideoID('https://www.youtube.com/watch?v=dQw4w9WgXcQ'), 'dQw4w9WgXcQ')
  assert.equal(parseYouTubeVideoID('https://youtube.com/shorts/dQw4w9WgXcQ'), 'dQw4w9WgXcQ')
  assert.equal(parseYouTubeVideoID('https://example.com/watch?v=dQw4w9WgXcQ'), null)
  assert.equal(parseYouTubeVideoID('too-short'), null)
})

test('recognizes original offline media formats and checks playback support', () => {
  assert.equal(inferMediaType('clip.MP4'), 'video/mp4')
  assert.equal(inferMediaType('clip.webm'), 'video/webm')
  assert.equal(inferMediaType('clip.mov'), 'video/quicktime')
  assert.equal(inferMediaType('notes.txt'), '')
  assert.deepEqual(
    validateMediaSource({ name: 'clip.m4v', type: '' }, () => 'probably'),
    { mimeType: 'video/mp4', extension: 'm4v' },
  )
  assert.throws(
    () => validateMediaSource({ name: 'clip.webm', type: 'video/webm' }, () => ''),
    /cannot play/,
  )
  assert.equal(formatBytes(1_572_864), '1.5 MB')
})

test('builds the four-panel ExtendReality composition with same-origin routes', () => {
  const layout = createSpatialLayout('https://apps.example.com/spatial-video/?extendDisplayMode=window')
  assert.equal(layout.primaryPanelID, 'video')
  assert.equal(layout.panels.length, 4)
  assert.deepEqual(layout.panels.map((panel) => panel.id), ['video', 'info', 'queue', 'transport'])
  assert.equal(layout.panels[0].placement.width, 0.86)
  assert.equal(layout.panels[1].placement.yaw, -30)
  assert.equal(layout.panels[2].placement.yaw, 30)
  assert.equal(layout.panels[3].placement.pitch, -17)
  assert.equal(new URL(layout.panels[2].url).origin, 'https://apps.example.com')
  assert.equal(new URL(layout.panels[2].url).searchParams.get('panel'), 'queue')
})

test('collapses Spatial Video to its primary window while playback is inactive', () => {
  const layout = createSpatialLayout(
    'https://apps.example.com/spatial-video/?extendDisplayMode=window',
    'window',
    false,
  )
  assert.equal(layout.primaryPanelID, 'video')
  assert.deepEqual(layout.panels.map((panel) => panel.id), ['video'])
})

test('versions messages exchanged between spatial panels', () => {
  const message = spatialMessage('command', { command: { type: 'toggle-playback' } })
  assert.equal(isSpatialMessage(message), true)
  assert.equal(isSpatialMessage({ version: 2, type: 'command' }), false)
})

test('validates Google OAuth Web client IDs without persisting access tokens', () => {
  const clientID = '123456789-spatialvideo.apps.googleusercontent.com'
  assert.equal(
    DEFAULT_GOOGLE_OAUTH_CLIENT_ID,
    '185337776045-6rt3m67ei3kjp1o8o9dd61rdduv99685.apps.googleusercontent.com',
  )
  assert.equal(isGoogleWebClientID(DEFAULT_GOOGLE_OAUTH_CLIENT_ID), true)
  assert.equal(normalizeGoogleClientID(`  ${clientID}\n`), clientID)
  assert.equal(isGoogleWebClientID(clientID), true)
  assert.equal(isGoogleWebClientID('not-a-web-client-id'), false)
})

test('normalizes subscription channels, upload playlists, and recent videos', () => {
  assert.deepEqual(subscriptionChannelIDs({ items: [
    { snippet: { resourceId: { channelId: 'channel-a' } } },
    { snippet: { resourceId: { channelId: 'channel-a' } } },
    { snippet: { resourceId: { channelId: 'channel-b' } } },
  ] }), ['channel-a', 'channel-b'])

  assert.deepEqual(uploadsPlaylists({ items: [
    { id: 'channel-a', contentDetails: { relatedPlaylists: { uploads: 'uploads-a' } } },
    { id: 'channel-b', contentDetails: { relatedPlaylists: {} } },
  ] }), [{ channelID: 'channel-a', playlistID: 'uploads-a' }])

  assert.deepEqual(videoFromPlaylistItem({
    snippet: {
      title: 'Latest &amp; greatest',
      videoOwnerChannelTitle: 'Example channel',
      thumbnails: { medium: { url: 'https://example.com/thumb.jpg' } },
      resourceId: { videoId: 'dQw4w9WgXcQ' },
    },
    contentDetails: { videoId: 'dQw4w9WgXcQ', videoPublishedAt: '2026-07-20T10:00:00Z' },
  }), {
    kind: 'youtube',
    videoId: 'dQw4w9WgXcQ',
    title: 'Latest & greatest',
    channelTitle: 'Example channel',
    thumbnailURL: 'https://example.com/thumb.jpg',
    publishedAt: '2026-07-20T10:00:00Z',
  })
})

test('loads and sorts a read-only subscription feed with bearer authorization', async () => {
  const originalFetch = globalThis.fetch
  const calls = []
  globalThis.fetch = async (input, init) => {
    const url = new URL(input)
    calls.push({ url, init })
    if (url.pathname.endsWith('/subscriptions')) {
      return Response.json({ items: [
        { snippet: { resourceId: { channelId: 'channel-a' } } },
        { snippet: { resourceId: { channelId: 'channel-b' } } },
      ] })
    }
    if (url.pathname.endsWith('/channels')) {
      return Response.json({ items: [
        { id: 'channel-a', contentDetails: { relatedPlaylists: { uploads: 'uploads-a' } } },
        { id: 'channel-b', contentDetails: { relatedPlaylists: { uploads: 'uploads-b' } } },
      ] })
    }
    const playlistID = url.searchParams.get('playlistId')
    const newest = playlistID === 'uploads-b'
    return Response.json({ items: [{
      snippet: {
        title: newest ? 'Newest video' : 'Older video',
        videoOwnerChannelTitle: newest ? 'Channel B' : 'Channel A',
        resourceId: { videoId: newest ? 'M7lc1UVf-VE' : 'dQw4w9WgXcQ' },
      },
      contentDetails: {
        videoId: newest ? 'M7lc1UVf-VE' : 'dQw4w9WgXcQ',
        videoPublishedAt: newest ? '2026-07-20T12:00:00Z' : '2026-07-19T12:00:00Z',
      },
    }] })
  }

  try {
    const feed = await fetchSubscriptionFeed('memory-only-token', undefined, { maxChannels: 2, videosPerChannel: 1 })
    assert.deepEqual(feed.map((item) => item.title), ['Newest video', 'Older video'])
    assert.equal(calls.length, 4)
    assert.ok(calls.every((call) => call.init.credentials === 'omit'))
    assert.ok(calls.every((call) => call.init.headers.Authorization === 'Bearer memory-only-token'))
    assert.equal(calls[0].url.searchParams.get('mine'), 'true')
    assert.equal(calls[0].url.searchParams.get('order'), 'unread')
  } finally {
    globalThis.fetch = originalFetch
  }
})
