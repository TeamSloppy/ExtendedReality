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

test('versions messages exchanged between spatial panels', () => {
  const message = spatialMessage('command', { command: { type: 'toggle-playback' } })
  assert.equal(isSpatialMessage(message), true)
  assert.equal(isSpatialMessage({ version: 2, type: 'command' }), false)
})
