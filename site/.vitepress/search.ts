import fs from 'node:fs'
import path from 'node:path'
import { createMarkdownRenderer, type DefaultTheme, type MarkdownOptions, type MarkdownRenderer } from 'vitepress'
import { DOCS, ROOT, rewriteDoc } from './mirror'

// Local search, adjusted for this site in two ways:
// - Pages print their title from frontmatter (PageHeader), not from a Markdown H1, so the
//   index gets the title and description as a first section; without it, results have no page
//   title and the text before the first ## is never indexed.
// - VitePress indexes a page by reading its file, which a mirrored doc (a dynamic route) does
//   not have, so mirrored docs are rendered here from the repo's own Markdown.

type Section = { anchor: string; titles: string[]; text: string }

const HEADING = /<h(\d*).*?>(.*?<a.*? href="#.*?".*?>.*?<\/a>)<\/h\1>/gi
const HEADING_CONTENT = /(.*?)<a.*? href="#(.*?)".*?>.*?<\/a>/i

function escapeHtml(text: string): string {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

function stripTags(html: string): string {
  return html.replace(/<[^>]*>/g, '')
}

/** A first section holding the page's title and description, in the shape VitePress splits on. */
function pageHead(title: string, description = ''): string {
  return `<h1>${escapeHtml(title)}<a class="header-anchor" href="#"></a></h1>` + (description ? `<p>${escapeHtml(description)}</p>` : '')
}

/** The same split VitePress does: one section per heading, titled by its parent headings. */
function splitSections(html: string): Section[] {
  const parts = html.split(HEADING)
  parts.shift()
  const sections: Section[] = []
  let parents: string[] = []
  for (let i = 0; i < parts.length; i += 3) {
    const level = parseInt(parts[i]) - 1
    const found = HEADING_CONTENT.exec(parts[i + 1])
    const title = stripTags(found?.[1] ?? '').trim()
    const content = parts[i + 2]
    if (!title || !content) continue
    const titles = parents.slice(0, level)
    titles[level] = title
    sections.push({ anchor: found?.[2] ?? '', titles: titles.filter(Boolean), text: stripTags(content) })
    if (level === 0) parents = [title]
    else parents[level] = title
  }
  return sections
}

export function searchConfig(srcDir: string, markdown: MarkdownOptions): DefaultTheme.Config['search'] {
  let renderer: Promise<MarkdownRenderer> | undefined
  const mirrored = new Map(DOCS.map((d) => [path.join(srcDir, `${d.route.slice(1)}.md`), d]))

  return {
    provider: 'local',
    options: {
      _render(src, env, md) {
        const html = md.render(src, env)
        if (env.frontmatter?.search === false) return ''
        const title = env.frontmatter?.title
        return title && env.frontmatter?.layout !== 'home' ? pageHead(title, env.frontmatter?.description) + html : html
      },
      miniSearch: {
        async _splitIntoSections(file: string, html: string) {
          const doc = mirrored.get(file)
          if (html || !doc) return undefined as unknown as Section[]
          renderer ??= createMarkdownRenderer(srcDir, markdown)
          const md = await renderer
          const src = rewriteDoc(fs.readFileSync(path.join(ROOT, doc.file), 'utf-8'), doc.file)
          return splitSections(pageHead(doc.title, doc.description) + md.render(src, { path: file, relativePath: path.relative(srcDir, file), cleanUrls: true }))
        }
      }
    }
  }
}
