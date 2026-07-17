import { mkdir, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { createCatalog } from './catalog-data.mjs'

const publicBaseURL = process.env.PWA_PUBLIC_BASE_URL ?? process.argv[2]
if (!publicBaseURL) {
  throw new Error('Set PWA_PUBLIC_BASE_URL or pass an HTTPS base URL as the first argument.')
}

const outputPath = resolve('dist/catalog.json')
await mkdir(resolve('dist'), { recursive: true })
await writeFile(outputPath, `${JSON.stringify(createCatalog(publicBaseURL), null, 2)}\n`)
console.log(`Wrote ${outputPath}`)
