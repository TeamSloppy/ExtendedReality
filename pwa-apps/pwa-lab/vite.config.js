import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'

const pathPrefix = (process.env.PWA_BASE_PATH ?? '').replace(/^\/+|\/+$/g, '')
const appBase = `/${[pathPrefix, 'pwa-lab'].filter(Boolean).join('/')}/`

export default defineConfig({
  base: appBase,
  plugins: [
    react(),
    VitePWA({
      registerType: 'autoUpdate',
      injectRegister: 'auto',
      manifest: {
        id: appBase,
        name: 'PWA Lab',
        short_name: 'PWA Lab',
        description: 'Diagnostics for the ExtendReality PWA host.',
        start_url: appBase,
        scope: appBase,
        display: 'standalone',
        background_color: '#0F172A',
        theme_color: '#0F172A',
        icons: [
          {
            src: 'icon.svg',
            sizes: 'any',
            type: 'image/svg+xml',
            purpose: 'any maskable',
          },
        ],
      },
      workbox: {
        navigateFallback: `${appBase}index.html`,
        globPatterns: ['**/*.{js,css,html,svg,woff2}'],
        cleanupOutdatedCaches: true,
      },
      devOptions: { enabled: true },
    }),
  ],
})
