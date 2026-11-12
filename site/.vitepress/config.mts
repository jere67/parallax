import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { defineConfig, type DefaultTheme, type MarkdownOptions } from 'vitepress'
import { REPO_URL } from './repo'
import { writeLlmsFiles } from './llms'
import { searchConfig } from './search'

const here = path.dirname(fileURLToPath(import.meta.url))

const markdown: MarkdownOptions = {
  theme: { light: 'github-light', dark: 'vitesse-dark' },
  // Shiki has no Jac grammar; Python's is the closest and keeps keywords and strings legible.
  languageAlias: { jac: 'python' },
  math: false
}

// The docs site: the repo's own Markdown (docs/, CONTRIBUTING.md) plus the guide, system, and
// API pages under site/. The layout follows a two-row header of tabs over a sidebar per tab.

const guide: DefaultTheme.SidebarItem[] = [
  {
    text: 'Get started',
    items: [
      { text: 'Introduction', link: '/guide/introduction' },
      { text: 'Quickstart', link: '/guide/quickstart' },
      { text: 'Configuration', link: '/guide/configuration' },
      { text: 'Demo data', link: '/guide/demo-data' },
      { text: 'Deploying to JacHammer', link: '/guide/deploy' }
    ]
  },
  {
    text: 'Operating',
    items: [
      { text: 'The forward test', link: '/guide/forward-test' },
      { text: 'Your agent', link: '/guide/your-agent' },
      { text: 'Starting a run by hand', link: '/guide/manual-run' },
      { text: 'Policies and the assistant', link: '/guide/policies' },
      { text: 'Installing on a phone', link: '/guide/mobile' },
      { text: 'Reading the dashboard', link: '/guide/dashboard' }
    ]
  },
  {
    text: 'Developing',
    items: [
      { text: 'Repository layout', link: '/guide/repository-layout' },
      { text: 'Checks and tests', link: '/guide/testing' },
      { text: 'Contributing', link: '/guide/contributing' }
    ]
  }
]

const system: DefaultTheme.SidebarItem[] = [
  {
    text: 'Overview',
    items: [
      { text: 'Architecture', link: '/system/architecture' },
      { text: 'The trading day', link: '/system/trading-day' },
      { text: 'Run Guard', link: '/system/run-guard' }
    ]
  },
  {
    text: 'Research',
    items: [
      { text: 'Universe screen', link: '/system/screener' },
      { text: 'Data sources', link: '/system/data-sources' },
      { text: 'Research pass', link: '/system/research' }
    ]
  },
  {
    text: 'Analysis',
    items: [
      { text: 'Agents and models', link: '/system/agents' },
      { text: 'Stochastic consensus', link: '/system/consensus' },
      { text: 'Vote scoring', link: '/system/scoring' },
      { text: 'Evaluation', link: '/system/evaluation' }
    ]
  },
  {
    text: 'Action',
    items: [
      { text: 'Position sizing', link: '/system/sizing' },
      { text: 'Risk gate', link: '/system/risk-gate' },
      { text: 'Execution', link: '/system/execution' },
      { text: 'Insights and baselines', link: '/system/insights-baselines' }
    ]
  },
  {
    text: 'Platform',
    items: [
      { text: 'Data model', link: '/system/data-model' },
      { text: 'Dashboard internals', link: '/system/dashboard' },
      { text: 'Market data', link: '/system/market-data' }
    ]
  }
]

const api: DefaultTheme.SidebarItem[] = [
  {
    text: 'Using the API',
    items: [
      { text: 'Overview', link: '/api/overview' },
      { text: 'Authentication', link: '/api/authentication' },
      { text: 'Data types', link: '/api/types' },
      { text: 'Policy endpoints', link: '/api/policy' }
    ]
  },
  {
    text: 'Endpoints',
    items: [
      {
        text: 'Service',
        collapsed: false,
        items: [
          { text: 'health', link: '/api/health', badge: 'POST' },
          { text: 'healthz', link: '/api/healthz', badge: 'GET' }
        ]
      },
      {
        text: 'Dashboard',
        collapsed: false,
        items: [
          { text: 'get_portfolio', link: '/api/get-portfolio', badge: 'POST' },
          { text: 'get_performance', link: '/api/get-performance', badge: 'POST' },
          { text: 'list_runs', link: '/api/list-runs', badge: 'POST' },
          { text: 'get_run', link: '/api/get-run', badge: 'POST' },
          { text: 'get_decision_trail', link: '/api/get-decision-trail', badge: 'POST' },
          { text: 'get_news_feed', link: '/api/get-news-feed', badge: 'POST' },
          { text: 'get_news_story', link: '/api/get-news-story', badge: 'POST' }
        ]
      },
      {
        text: 'Account',
        collapsed: false,
        items: [
          { text: 'Account endpoints', link: '/api/accounts' },
          { text: 'user/login', link: '/api/login', badge: 'POST' }
        ]
      },
      {
        text: 'Market',
        collapsed: false,
        items: [
          { text: 'screen_stocks', link: '/api/screen-stocks', badge: 'POST' },
          { text: 'get_stock', link: '/api/get-stock', badge: 'POST' },
          { text: 'get_stock_history', link: '/api/get-stock-history', badge: 'POST' },
          { text: 'get_stock_about', link: '/api/get-stock-about', badge: 'POST' }
        ]
      },
      {
        text: 'Admin',
        collapsed: false,
        items: [
          { text: 'start_morning_run', link: '/api/start-morning-run', badge: 'POST' }
        ]
      }
    ]
  }
]

const design: DefaultTheme.SidebarItem[] = [
  {
    text: 'Specifications',
    items: [
      { text: 'Technical design', link: '/design/tdd' },
      { text: 'Requirements', link: '/design/requirements' }
    ]
  },
  {
    text: 'Spikes',
    items: [
      { text: 'Free models', link: '/design/spike-free-models' },
      { text: 'Alpaca order rules', link: '/design/spike-alpaca-order-rules' }
    ]
  },
  {
    text: 'Evaluation',
    items: [{ text: 'Screen backtest', link: '/design/eval-screen-backtest' }]
  },
  {
    text: 'Exit runs',
    items: [
      { text: 'Research phase', link: '/design/run-research' },
      { text: 'Analysis phase', link: '/design/run-analysis' },
      { text: 'Action phase', link: '/design/run-action' },
      { text: 'Retry audit', link: '/design/run-retry-audit' }
    ]
  }
]

export default defineConfig({
  title: 'Parallax',
  titleTemplate: ':title · Parallax docs',
  description:
    "Documentation for Parallax: a Jac multi-agent system that gives each user an agent that researches S&P 500 stocks and trades them on that user's Alpaca paper account.",
  lang: 'en-US',
  // GitHub Pages serves the site under the repository name; DOCS_BASE overrides it.
  base: process.env.DOCS_BASE ?? '/parallax/',
  cleanUrls: true,
  lastUpdated: true,
  appearance: true,
  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: `${process.env.DOCS_BASE ?? '/parallax/'}mark.svg` }],
    ['meta', { name: 'theme-color', content: '#0c0b09' }]
  ],
  markdown,
  vite: {
    // Pages show figures from the repo's docs/figures as @repo/docs/figures/<name>.png.
    resolve: { alias: { '@repo': path.resolve(here, '../..') } },
    server: { fs: { allow: ['..'] } }
  },
  themeConfig: {
    nav: [
      { text: 'Guides', link: '/guide/introduction', activeMatch: '^/guide/' },
      { text: 'System', link: '/system/architecture', activeMatch: '^/system/' },
      { text: 'API Reference', link: '/api/overview', activeMatch: '^/api/' },
      { text: 'Design Docs', link: '/design/tdd', activeMatch: '^/design/' },
      { text: 'Changelog', link: '/changelog', activeMatch: '^/changelog' }
    ],
    sidebar: {
      '/guide/': guide,
      '/system/': system,
      '/api/': api,
      '/design/': design,
      '/changelog': [{ text: 'Releases', items: [{ text: 'Changelog', link: '/changelog' }] }]
    },
    search: searchConfig(path.resolve(here, '..'), markdown),
    outline: { level: [2, 3], label: 'On this page' },
    editLink: { pattern: `${REPO_URL}/edit/main/site/:path`, text: 'Edit this page' },
    socialLinks: [{ icon: 'github', link: REPO_URL }]
  },
  // Mirrored docs carry their title and description as route params; use them for <title>.
  transformPageData(pageData) {
    const params = pageData.params as { title?: string; description?: string } | undefined
    if (params?.title) pageData.title = params.title
    if (params?.description) pageData.description = params.description
  },
  buildEnd: writeLlmsFiles
})
