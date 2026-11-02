import fs from 'node:fs'
import path from 'node:path'
import type { SiteConfig } from 'vitepress'

// After the build, write /llms.txt (an index of every page) and /llms-full.txt (every page's
// Markdown, concatenated), so an agent can read the docs without a browser.
export async function writeLlmsFiles(site: SiteConfig) {
  const dynamic = site.dynamicRoutes?.routes ?? []
  const generated = new Set(dynamic.map((r) => r.path))
  // Pages written under site/; the mirrored pages come from the dynamic routes below.
  const pages = site.pages
    .filter((p) => p !== 'index.md' && !p.includes('[') && !generated.has(p))
    .filter((p) => fs.existsSync(path.join(site.srcDir, p)))
    .sort()
  const base = site.site.base
  const index: string[] = [`# ${site.site.title}`, '', `> ${site.site.description}`, '']
  const full: string[] = []
  for (const page of pages) {
    const file = path.join(site.srcDir, page)
    const src = fs.readFileSync(file, 'utf-8')
    const title = unquote(/^title:\s*(.+)$/m.exec(src)?.[1] ?? /^#\s+(.+)$/m.exec(src)?.[1] ?? page)
    const description = unquote(/^description:\s*(.+)$/m.exec(src)?.[1] ?? '')
    const url = base + page.replace(/(index)?\.md$/, '')
    index.push(`- [${title}](${url})${description ? `: ${description}` : ''}`)
    full.push(`<!-- ${url} -->\n${src.replace(/^---[\s\S]*?---\n/, '')}`)
  }
  for (const route of dynamic) {
    const url = base + route.path.replace(/\.md$/, '')
    const title = (route.params as { title?: string }).title ?? route.path
    index.push(`- [${title}](${url})`)
    if (route.content) full.push(`<!-- ${url} -->\n# ${title}\n\n${route.content}`)
  }
  fs.writeFileSync(path.join(site.outDir, 'llms.txt'), index.join('\n') + '\n')
  fs.writeFileSync(path.join(site.outDir, 'llms-full.txt'), full.join('\n\n'))
}

function unquote(value: string): string {
  return value.trim().replace(/^(['"])(.*)\1$/, '$2')
}
