import { cp, mkdir, rm, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { createCatalog } from './catalog-data.mjs'

const output = resolve('dist')
const studioOutput = resolve('../ExtendRealityPWAStudio/Resources/PWAApps')
const publicBaseURL = process.env.PWA_PUBLIC_BASE_URL ?? 'https://apps.example.com'

await rm(output, { recursive: true, force: true })
await mkdir(output, { recursive: true })
await cp(resolve('spatial-board/dist'), resolve(output, 'spatial-board'), { recursive: true })
await cp(resolve('pwa-lab/dist'), resolve(output, 'pwa-lab'), { recursive: true })
await cp(resolve('spatial-video/dist'), resolve(output, 'spatial-video'), { recursive: true })
await writeFile(resolve(output, 'catalog.json'), `${JSON.stringify(createCatalog(publicBaseURL), null, 2)}\n`)

await rm(studioOutput, { recursive: true, force: true })
await cp(output, studioOutput, { recursive: true })

console.log(`Assembled static site in ${output}`)
console.log(`Synced bundled Studio apps to ${studioOutput}`)
console.log(`Catalog base URL: ${publicBaseURL}`)
