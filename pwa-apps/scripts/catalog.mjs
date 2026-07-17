import { mkdir, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { createCatalog } from './catalog-data.mjs'

const publicOrigin = process.env.PWA_PUBLIC_ORIGIN ?? process.argv[2]
if (!publicOrigin) {
  throw new Error('Set PWA_PUBLIC_ORIGIN or pass an HTTPS origin as the first argument.')
}

const outputPath = resolve('dist/catalog.json')
await mkdir(resolve('dist'), { recursive: true })
await writeFile(outputPath, `${JSON.stringify(createCatalog(publicOrigin), null, 2)}\n`)
console.log(`Wrote ${outputPath}`)
