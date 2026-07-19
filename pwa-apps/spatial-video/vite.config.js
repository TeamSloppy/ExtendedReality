import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'

const pathPrefix = (process.env.PWA_BASE_PATH ?? '').replace(/^\/+|\/+$/g, '')
const appBase = `/${[pathPrefix, 'spatial-video'].filter(Boolean).join('/')}/`

export default defineConfig({
  base: appBase,
  plugins: [
    react(),
    VitePWA({
      registerType: 'autoUpdate',
      injectRegister: 'auto',
      manifest: {
        id: appBase,
        name: 'Spatial Video',
        short_name: 'Video',
        description: 'A spatial online player and offline library for media you own.',
        start_url: appBase,
        scope: appBase,
        display: 'standalone',
        background_color: '#000000',
        theme_color: '#000000',
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
        runtimeCaching: [],
      },
      devOptions: { enabled: true },
    }),
  ],
})
