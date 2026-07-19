import { sanitizeFilename, validateMediaSource } from './media.js'

const DATABASE_NAME = 'spatial-video-v1'
const DATABASE_VERSION = 1
const SETTINGS_STORE = 'settings'
const MEDIA_STORE = 'media'
const BLOBS_STORE = 'mediaBlobs'
const STORAGE_HEADROOM = 16 * 1024 * 1024

let databasePromise

function requestResult(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error ?? new Error('IndexedDB request failed.'))
  })
}

function transactionComplete(transaction) {
  return new Promise((resolve, reject) => {
    transaction.oncomplete = () => resolve()
    transaction.onabort = () => reject(transaction.error ?? new Error('Storage transaction was cancelled.'))
    transaction.onerror = () => reject(transaction.error ?? new Error('Storage transaction failed.'))
  })
}

function openDatabase() {
  if (databasePromise) return databasePromise
  databasePromise = new Promise((resolve, reject) => {
    const request = indexedDB.open(DATABASE_NAME, DATABASE_VERSION)
    request.onupgradeneeded = () => {
      const database = request.result
      if (!database.objectStoreNames.contains(SETTINGS_STORE)) {
        database.createObjectStore(SETTINGS_STORE, { keyPath: 'key' })
      }
      if (!database.objectStoreNames.contains(MEDIA_STORE)) {
        database.createObjectStore(MEDIA_STORE, { keyPath: 'id' })
      }
      if (!database.objectStoreNames.contains(BLOBS_STORE)) {
        database.createObjectStore(BLOBS_STORE, { keyPath: 'id' })
      }
    }
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error ?? new Error('Unable to open offline storage.'))
  })
  return databasePromise
}

export async function getSetting(key, fallback = null) {
  const database = await openDatabase()
  const transaction = database.transaction(SETTINGS_STORE, 'readonly')
  const record = await requestResult(transaction.objectStore(SETTINGS_STORE).get(key))
  return record?.value ?? fallback
}

export async function setSetting(key, value) {
  const database = await openDatabase()
  const transaction = database.transaction(SETTINGS_STORE, 'readwrite')
  transaction.objectStore(SETTINGS_STORE).put({ key, value })
  await transactionComplete(transaction)
}

export async function listOfflineMedia() {
  const database = await openDatabase()
  const transaction = database.transaction(MEDIA_STORE, 'readonly')
  const records = await requestResult(transaction.objectStore(MEDIA_STORE).getAll())
  return records.sort((left, right) => right.createdAt.localeCompare(left.createdAt))
}

async function getBlob(id) {
  const database = await openDatabase()
  const transaction = database.transaction(BLOBS_STORE, 'readonly')
  const record = await requestResult(transaction.objectStore(BLOBS_STORE).get(id))
  return record?.blob ?? null
}

async function putRecord(record, blob = null) {
  const database = await openDatabase()
  const transaction = database.transaction([MEDIA_STORE, BLOBS_STORE], 'readwrite')
  transaction.objectStore(MEDIA_STORE).put(record)
  if (blob) transaction.objectStore(BLOBS_STORE).put({ id: record.id, blob })
  await transactionComplete(transaction)
}

async function removeRecord(id) {
  const database = await openDatabase()
  const transaction = database.transaction([MEDIA_STORE, BLOBS_STORE], 'readwrite')
  transaction.objectStore(MEDIA_STORE).delete(id)
  transaction.objectStore(BLOBS_STORE).delete(id)
  await transactionComplete(transaction)
}

function canUseOPFS() {
  return typeof navigator.storage?.getDirectory === 'function'
}

async function ensureStorageCapacity(expectedBytes) {
  if (!Number.isFinite(expectedBytes) || expectedBytes <= 0 || !navigator.storage?.estimate) return
  const estimate = await navigator.storage.estimate()
  if (!Number.isFinite(estimate.quota) || !Number.isFinite(estimate.usage)) return
  if (estimate.quota - estimate.usage < expectedBytes + STORAGE_HEADROOM) {
    throw new Error('There is not enough device storage for this video.')
  }
}

async function requestPersistentStorage() {
  if (typeof navigator.storage?.persist !== 'function') return false
  try {
    return await navigator.storage.persist()
  } catch {
    return false
  }
}

function abortError() {
  return new DOMException('The download was cancelled.', 'AbortError')
}

async function writeStreamToOPFS(stream, storageName, expectedBytes, onProgress, signal) {
  const root = await navigator.storage.getDirectory()
  const handle = await root.getFileHandle(storageName, { create: true })
  const writable = await handle.createWritable()
  const reader = stream.getReader()
  let written = 0

  try {
    while (true) {
      if (signal?.aborted) throw abortError()
      const { done, value } = await reader.read()
      if (done) break
      await writable.write(value)
      written += value.byteLength
      onProgress?.({ written, total: expectedBytes })
    }
    await writable.close()
    return written
  } catch (error) {
    await reader.cancel(error).catch(() => {})
    if (typeof writable.abort === 'function') await writable.abort().catch(() => {})
    else await writable.close().catch(() => {})
    await root.removeEntry(storageName).catch(() => {})
    throw error
  }
}

async function readStreamToBlob(stream, mimeType, expectedBytes, onProgress, signal) {
  const reader = stream.getReader()
  const chunks = []
  let written = 0
  while (true) {
    if (signal?.aborted) {
      await reader.cancel().catch(() => {})
      throw abortError()
    }
    const { done, value } = await reader.read()
    if (done) break
    chunks.push(value)
    written += value.byteLength
    onProgress?.({ written, total: expectedBytes })
  }
  return { blob: new Blob(chunks, { type: mimeType }), written }
}

async function saveStream({ stream, name, title, type, size, sourceKind, onProgress, signal, canPlayType }) {
  const { mimeType, extension } = validateMediaSource({ name, type }, canPlayType)
  await ensureStorageCapacity(size)
  await requestPersistentStorage()

  const id = crypto.randomUUID()
  const filename = sanitizeFilename(name, `offline-video.${extension}`)
  const storageName = `media-${id}.${extension}`
  const createdAt = new Date().toISOString()
  let record

  if (canUseOPFS()) {
    const written = await writeStreamToOPFS(stream, storageName, size, onProgress, signal)
    record = {
      id,
      title: sanitizeFilename(title || filename, 'Offline video'),
      filename,
      mimeType,
      extension,
      bytes: written,
      storageKind: 'opfs',
      storageName,
      sourceKind,
      createdAt,
    }
    try {
      await putRecord(record)
    } catch (error) {
      const root = await navigator.storage.getDirectory()
      await root.removeEntry(storageName).catch(() => {})
      throw error
    }
  } else {
    const { blob, written } = await readStreamToBlob(stream, mimeType, size, onProgress, signal)
    record = {
      id,
      title: sanitizeFilename(title || filename, 'Offline video'),
      filename,
      mimeType,
      extension,
      bytes: written,
      storageKind: 'indexeddb',
      storageName: null,
      sourceKind,
      createdAt,
    }
    await putRecord(record, blob)
  }

  return record
}

export function mediaCanPlayType(mimeType) {
  const element = document.createElement('video')
  return element.canPlayType(mimeType)
}

export async function importLocalMedia(file, options = {}) {
  if (!(file instanceof Blob)) throw new Error('Choose a local video file first.')
  return saveStream({
    stream: file.stream(),
    name: file.name || 'offline-video',
    title: file.name?.replace(/\.[^.]+$/, ''),
    type: file.type,
    size: file.size,
    sourceKind: 'file',
    canPlayType: options.canPlayType ?? mediaCanPlayType,
    onProgress: options.onProgress,
    signal: options.signal,
  })
}

function filenameFromURL(url) {
  const pathname = new URL(url).pathname
  return decodeURIComponent(pathname.split('/').filter(Boolean).pop() || 'offline-video')
}

export async function downloadRemoteMedia(value, options = {}) {
  let url
  try {
    url = new URL(String(value).trim())
  } catch {
    throw new Error('Enter a valid direct HTTPS video URL.')
  }
  if (url.protocol !== 'https:') throw new Error('Offline media URLs must use HTTPS.')

  const response = await fetch(url, { credentials: 'omit', signal: options.signal })
  if (!response.ok) throw new Error(`The media server returned HTTP ${response.status}.`)
  if (!response.body) throw new Error('The media server did not return a downloadable body.')

  const name = filenameFromURL(url)
  const type = response.headers.get('content-type') ?? ''
  const size = Number(response.headers.get('content-length')) || 0
  return saveStream({
    stream: response.body,
    name,
    title: name.replace(/\.[^.]+$/, ''),
    type,
    size,
    sourceKind: 'url',
    canPlayType: options.canPlayType ?? mediaCanPlayType,
    onProgress: options.onProgress,
    signal: options.signal,
  })
}

export async function offlineMediaObjectURL(record) {
  let blob
  if (record.storageKind === 'opfs') {
    const root = await navigator.storage.getDirectory()
    const handle = await root.getFileHandle(record.storageName)
    blob = await handle.getFile()
  } else {
    blob = await getBlob(record.id)
  }
  if (!blob) throw new Error('The offline video file is missing.')
  return URL.createObjectURL(blob)
}

export async function deleteOfflineMedia(record) {
  if (record.storageKind === 'opfs' && canUseOPFS() && record.storageName) {
    const root = await navigator.storage.getDirectory()
    await root.removeEntry(record.storageName).catch(() => {})
  }
  await removeRecord(record.id)
}

async function recordExists(record) {
  if (record.storageKind === 'opfs') {
    if (!canUseOPFS()) return false
    try {
      const root = await navigator.storage.getDirectory()
      await root.getFileHandle(record.storageName)
      return true
    } catch {
      return false
    }
  }
  return Boolean(await getBlob(record.id))
}

export async function cleanupOfflineStorage() {
  const records = await listOfflineMedia()
  const validRecords = []
  for (const record of records) {
    if (await recordExists(record)) validRecords.push(record)
    else await removeRecord(record.id)
  }

  if (canUseOPFS()) {
    const root = await navigator.storage.getDirectory()
    if (typeof root.entries === 'function') {
      const referenced = new Set(validRecords.map((record) => record.storageName).filter(Boolean))
      for await (const [name] of root.entries()) {
        if (name.startsWith('media-') && !referenced.has(name)) {
          await root.removeEntry(name).catch(() => {})
        }
      }
    }
  }
  return validRecords
}
