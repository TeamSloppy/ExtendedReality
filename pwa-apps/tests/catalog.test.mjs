import assert from 'node:assert/strict'
import test from 'node:test'
import { createCatalog, normalizeBaseURL } from '../scripts/catalog-data.mjs'

test('normalizes a secure deployment base URL', () => {
  assert.deepEqual(normalizeBaseURL('https://spectraldragon.github.io/ExtendedReality/'), {
    baseURL: 'https://spectraldragon.github.io/ExtendedReality',
    origin: 'https://spectraldragon.github.io',
  })
})

test('rejects insecure or ambiguous deployment base URLs', () => {
  assert.throws(() => normalizeBaseURL('http://apps.example.com'), /HTTPS/)
  assert.throws(() => normalizeBaseURL('https://apps.example.com/pwa?preview=1'), /query or fragment/)
})

test('generates valid pilot entries for both display modes', () => {
  const catalog = createCatalog('https://apps.example.com')

  assert.equal(catalog.schemaVersion, 1)
  assert.deepEqual(catalog.apps.map((app) => app.id), [
    'com.extendreality.spatial-board',
    'com.extendreality.pwa-lab',
    'com.extendreality.spatial-video',
  ])
  assert.ok(catalog.apps.every((app) => app.launchURL.startsWith('https://apps.example.com/')))
  assert.ok(catalog.apps.every((app) => app.displayModes.includes('window')))
  assert.ok(catalog.apps.every((app) => app.displayModes.includes('widget')))
  assert.deepEqual(catalog.apps[1].requestedCapabilities, [
    'camera',
    'microphone',
    'location',
    'health',
    'focusStatus',
    'spatialWindows',
  ])
  assert.deepEqual(catalog.apps[2].requestedCapabilities, ['spatialWindows'])
  assert.equal(catalog.apps[2].minimumAge, 13)
})

test('generates GitHub project Pages URLs with an origin-only allowlist', () => {
  const catalog = createCatalog('https://spectraldragon.github.io/ExtendedReality')

  assert.equal(
    catalog.apps[0].launchURL,
    'https://spectraldragon.github.io/ExtendedReality/spatial-board/',
  )
  assert.deepEqual(catalog.apps[0].allowedOrigins, ['https://spectraldragon.github.io'])
  assert.equal(
    catalog.apps[2].launchURL,
    'https://spectraldragon.github.io/ExtendedReality/spatial-video/',
  )
})
