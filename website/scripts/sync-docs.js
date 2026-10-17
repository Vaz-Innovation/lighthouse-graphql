// Copies the guides from ../docs into this site, so docs/ stays plain Markdown
// (packaged with the gem and readable on GitHub) while VuePress renders it.
import { cpSync, mkdirSync, readdirSync, rmSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const site = join(dirname(fileURLToPath(import.meta.url)), '..')
const source = join(site, '..', 'docs')
const target = join(site, 'docs')

rmSync(target, { recursive: true, force: true })
mkdirSync(target)
const pages = readdirSync(source).filter((file) => file.endsWith('.md'))
for (const page of pages) cpSync(join(source, page), join(target, page))

console.log(`Copied ${pages.length} pages from docs/`)
