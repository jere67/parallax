import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { SOURCE_URL } from './repo'

// The repo Markdown the site mirrors, and where each file lives on the site.
export interface MirroredDoc {
  file: string
  route: string
  title: string
  description: string
  eyebrow: string
}

export const DOCS: MirroredDoc[] = [
  {
    file: 'docs/TDD.md',
    route: '/design/tdd',
    title: 'Technical design',
    eyebrow: 'Specifications',
    description: 'Architecture, data sources, agents, risk controls, and the build plan, with every claim cited.'
  },
  {
    file: 'docs/requirements.md',
    route: '/design/requirements',
    title: 'Requirements',
    eyebrow: 'Specifications',
    description: 'What the system must do: functional and non-functional requirements, user stories, and open gaps.'
  },
  {
    file: 'docs/spikes/2026-10-08-free-models.md',
    route: '/design/spike-free-models',
    title: 'Spike: free models',
    eyebrow: 'Spikes',
    description: 'Free OpenRouter models, typed outputs, and the tool loop, measured on October 8, 2026.'
  },
  {
    file: 'docs/spikes/2026-10-20-alpaca-order-rules.md',
    route: '/design/spike-alpaca-order-rules',
    title: 'Spike: Alpaca order rules',
    eyebrow: 'Spikes',
    description: "Every order sequence the executor uses, tried on the team's Alpaca paper account."
  },
  {
    file: 'docs/runs/2026-10-15-research-exit-run.md',
    route: '/design/run-research',
    title: 'Research exit run',
    eyebrow: 'Exit runs',
    description: '20 tickers on October 15, 2026: every report complete and cited.'
  },
  {
    file: 'docs/runs/2026-10-16-analysis-exit-run.md',
    route: '/design/run-analysis',
    title: 'Analysis exit run',
    eyebrow: 'Exit runs',
    description: '20 tickers decided by the Orchestrator on October 16, 2026, and two fallback drills.'
  },
  {
    file: 'docs/runs/2026-10-20-action-exit-run.md',
    route: '/design/run-action',
    title: 'Action exit run',
    eyebrow: 'Exit runs',
    description: 'Three simulated trading days with zero gate bypasses and zero drift.'
  },
  {
    file: 'docs/runs/issue-71-retry-audit.md',
    route: '/design/run-retry-audit',
    title: 'Retry audit',
    eyebrow: 'Exit runs',
    description: 'Request accounting by role and kind, and the Flow abstention audit (issue #71).'
  },
  {
    file: 'CONTRIBUTING.md',
    route: '/guide/contributing',
    title: 'Contributing',
    eyebrow: 'Developing',
    description: 'How the team branches, commits, reviews, and writes Jac.'
  }
]

const byFile = new Map(DOCS.map((d) => [d.file, d]))
// Personal addresses never reach the site; a placeholder keeps the sentence readable.
const EMAIL = /[\w.+-]+@[\w-]+(\.[\w-]+)+/g
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const LINK = /(!?)\[([^\]]*)\]\(([^)\s]+)([^)]*)\)/g

/** Prepare one repo Markdown file for the site: drop its H1, keep its personal details out,
 * and point each relative link at the page or source file it names. */
export function rewriteDoc(src: string, file: string): string {
  const dir = path.posix.dirname(file)
  let out = src.replace(/^# .*\n+/, '').replace(EMAIL, 'contact@example.com')
  out = out.replace(LINK, (whole, bang, text, target, rest) => {
    if (/^(https?:|mailto:|#)/.test(target)) return whole
    const [rel, hash = ''] = target.split('#')
    const repoPath = path.posix.normalize(path.posix.join(dir, rel))
    const anchor = hash ? `#${hash}` : ''
    if (bang) {
      // Figures: a path from the generated page (site/<section>/x.md) to the repo file.
      return `![${text}](../../${repoPath}${rest})`
    }
    const doc = byFile.get(repoPath)
    if (doc) return `[${text}](${doc.route}${anchor}${rest})`
    return `[${text}](${SOURCE_URL}/${repoPath}${anchor}${rest})`
  })
  return out
}

/** The dynamic-route loader for one section (e.g. "/design/"): one page per mirrored file
 * whose route sits in that section, read from the repo at build time so it never drifts. */
export function mirrorRoutes(section: string) {
  const docs = DOCS.filter((d) => d.route.startsWith(section))
  return {
    watch: docs.map((d) => path.join(ROOT, d.file)),
    paths() {
      return docs.map((d) => ({
        params: {
          doc: d.route.slice(section.length),
          title: d.title,
          description: d.description,
          eyebrow: d.eyebrow,
          source: d.file
        },
        content: rewriteDoc(fs.readFileSync(path.join(ROOT, d.file), 'utf-8'), d.file)
      }))
    }
  }
}
