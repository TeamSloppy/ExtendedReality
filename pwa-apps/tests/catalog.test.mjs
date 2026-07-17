import assert from 'node:assert/strict'
import test from 'node:test'
import { createCatalog, normalizeOrigin } from '../scripts/catalog-data.mjs'

test('normalizes a secure deployment origin', () => {
  assert.equal(normalizeOrigin('https://apps.example.com/'), 'https://apps.example.com')
})

test('rejects insecure or path-scoped deployment origins', () => {
  assert.throws(() => normalizeOrigin('http://apps.example.com'), /HTTPS/)
  assert.throws(() => normalizeOrigin('https://apps.example.com/pwa'), /scheme and host/)
})

test('generates valid pilot entries for both display modes', () => {
  const catalog = createCatalog('https://apps.example.com')

  assert.equal(catalog.schemaVersion, 1)
  assert.deepEqual(catalog.apps.map((app) => app.id), [
    'com.extendreality.spatial-board',
    'com.extendreality.pwa-lab',
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
  ])
})
