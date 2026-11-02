import { computed } from 'vue'
import { useData, withBase } from 'vitepress'
import type { DefaultTheme } from 'vitepress/theme'

export type Item = DefaultTheme.SidebarItem

/** A link's path without the site base, .html, or a trailing index. */
export function normalize(path: string): string {
  return path.replace(/(index)?(\.html)?$/, '').replace(/\/$/, '') || '/'
}

/** Is `link` the page at `relativePath` (e.g. "guide/quickstart.md")? */
export function isActive(relativePath: string, link?: string): boolean {
  if (!link) return false
  const here = normalize('/' + relativePath.replace(/\.md$/, ''))
  return here === normalize(link)
}

function flatten(items: Item[], group = ''): { text: string; link: string; group: string }[] {
  const out: { text: string; link: string; group: string }[] = []
  for (const item of items) {
    if (item.link && item.text) out.push({ text: item.text, link: item.link, group })
    if (item.items) out.push(...flatten(item.items, item.link ? group : item.text ?? group))
  }
  return out
}

/** The current tab's sidebar, the page's place in it, and its neighbours. */
export function useNav() {
  const { theme, page } = useData()

  const tabs = computed(() => (theme.value.nav ?? []) as DefaultTheme.NavItemWithLink[])

  const activeTab = computed(() => {
    const path = '/' + page.value.relativePath
    return tabs.value.find((t) => t.activeMatch && new RegExp(t.activeMatch).test(path))
  })

  const sidebar = computed<Item[]>(() => {
    const config = theme.value.sidebar as DefaultTheme.SidebarMulti | undefined
    if (!config) return []
    const path = '/' + page.value.relativePath
    const key = Object.keys(config)
      .sort((a, b) => b.length - a.length)
      .find((k) => path.startsWith(k))
    const found = key ? config[key] : []
    return Array.isArray(found) ? found : found.items
  })

  const links = computed(() => flatten(sidebar.value))
  const index = computed(() => links.value.findIndex((l) => isActive(page.value.relativePath, l.link)))
  const current = computed(() => links.value[index.value])
  const currentGroup = computed(() => current.value?.group ?? '')
  const prev = computed(() => (index.value > 0 ? links.value[index.value - 1] : undefined))
  const next = computed(() => (index.value >= 0 ? links.value[index.value + 1] : undefined))

  return { tabs, activeTab, sidebar, current, currentGroup, prev, next, withBase }
}
