export const YOUTUBE_READONLY_SCOPE = 'https://www.googleapis.com/auth/youtube.readonly'
export const DEFAULT_GOOGLE_OAUTH_CLIENT_ID = '185337776045-6rt3m67ei3kjp1o8o9dd61rdduv99685.apps.googleusercontent.com'

let identityServicesPromise

export function normalizeGoogleClientID(value) {
  return String(value ?? '').trim()
}

export function isGoogleWebClientID(value) {
  return /^[0-9]+-[a-z0-9_-]+\.apps\.googleusercontent\.com$/i.test(normalizeGoogleClientID(value))
}

export function loadGoogleIdentityServices() {
  if (window.google?.accounts?.oauth2) return Promise.resolve(window.google)
  if (identityServicesPromise) return identityServicesPromise

  identityServicesPromise = new Promise((resolve, reject) => {
    const finish = () => {
      if (window.google?.accounts?.oauth2) resolve(window.google)
      else reject(new Error('Google authorization did not initialize.'))
    }
    const existing = document.querySelector('script[data-spatial-video-google]')
    if (existing) {
      existing.addEventListener('load', finish, { once: true })
      existing.addEventListener('error', () => reject(new Error('Unable to load Google authorization.')), { once: true })
      return
    }

    const script = document.createElement('script')
    script.src = 'https://accounts.google.com/gsi/client'
    script.async = true
    script.dataset.spatialVideoGoogle = 'true'
    script.onload = finish
    script.onerror = () => reject(new Error('Unable to load Google authorization.'))
    document.head.append(script)
  }).catch((error) => {
    identityServicesPromise = null
    throw error
  })
  return identityServicesPromise
}

function authorizationError(value) {
  const code = value?.type ?? value?.error
  if (code === 'popup_closed') return new Error('The Google sign-in window was closed.')
  if (code === 'popup_failed_to_open') return new Error('Allow pop-ups to connect your Google account.')
  if (code === 'access_denied') return new Error('YouTube read-only access was not granted.')
  return new Error(value?.error_description || value?.message || 'Google authorization failed.')
}

export async function requestYouTubeAccessToken(clientID) {
  const normalizedClientID = normalizeGoogleClientID(clientID)
  if (!isGoogleWebClientID(normalizedClientID)) {
    throw new Error('Enter a valid Google OAuth Web client ID.')
  }

  const google = await loadGoogleIdentityServices()
  const response = await new Promise((resolve, reject) => {
    const client = google.accounts.oauth2.initTokenClient({
      client_id: normalizedClientID,
      scope: YOUTUBE_READONLY_SCOPE,
      callback: (tokenResponse) => {
        if (tokenResponse?.error || !tokenResponse?.access_token) reject(authorizationError(tokenResponse))
        else resolve(tokenResponse)
      },
      error_callback: (error) => reject(authorizationError(error)),
    })
    client.requestAccessToken()
  })

  const expiresIn = Math.max(60, Number(response.expires_in) || 3_600)
  return {
    accessToken: response.access_token,
    expiresAt: Date.now() + expiresIn * 1_000,
    scope: response.scope ?? YOUTUBE_READONLY_SCOPE,
  }
}

export async function revokeYouTubeAccessToken(accessToken) {
  if (!accessToken) return
  const google = await loadGoogleIdentityServices()
  await new Promise((resolve) => google.accounts.oauth2.revoke(accessToken, resolve))
}
