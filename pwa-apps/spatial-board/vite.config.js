import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'

const pathPrefix = (process.env.PWA_BASE_PATH ?? '').replace(/^\/+|\/+$/g, '')
const appBase = `/${[pathPrefix, 'spatial-board'].filter(Boolean).join('/')}/`

export default defineConfig({
  base: appBase,
  plugins: [
    react(),
    VitePWA({
      registerType: 'autoUpdate',
      injectRegister: 'auto',
      manifest: {
        id: appBase,
        name: 'Spatial Board',
        short_name: 'Board',
        description: 'An offline-first spatial whiteboard.',
        start_url: appBase,
        scope: appBase,
        display: 'standalone',
        background_color: '#F0FDFA',
        theme_color: '#0D9488',
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
        maximumFileSizeToCacheInBytes: 4 * 1024 * 1024,
        cleanupOutdatedCaches: true,
      },
      devOptions: { enabled: true },
    }),
  ],
})
