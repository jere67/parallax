<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useData, useRoute } from 'vitepress'
import TopBar from './components/TopBar.vue'
import SidebarNav from './components/SidebarNav.vue'
import PageHeader from './components/PageHeader.vue'
import Outline from './components/Outline.vue'
import PageFooter from './components/PageFooter.vue'
import NotFound from './components/NotFound.vue'
import { useNav } from './nav'

const { frontmatter, page } = useData()
const route = useRoute()
const { sidebar, currentGroup } = useNav()

const isHome = computed(() => frontmatter.value.layout === 'home')
const isApi = computed(() => !!frontmatter.value.api)
const hasSidebar = computed(() => !isHome.value && sidebar.value.length > 0)
const hasOutline = computed(() => !isHome.value && !isApi.value && frontmatter.value.outline !== false)

// The phone drawer holds the tabs and the sidebar; any navigation closes it.
const drawer = ref(false)
watch(() => route.path, () => (drawer.value = false))
</script>

<template>
  <div class="docs" :class="{ 'is-home': isHome, 'is-api': isApi, 'has-sidebar': hasSidebar }">
    <a class="skip-link" href="#content">Skip to content</a>
    <TopBar :drawer="drawer" :crumb="currentGroup" @toggle="drawer = !drawer" />

    <div v-if="drawer" class="drawer-backdrop" @click="drawer = false" />
    <aside v-if="hasSidebar || drawer" class="sidebar" :class="{ open: drawer }" aria-label="Pages">
      <SidebarNav :mobile="drawer" />
    </aside>

    <main id="content" class="main">
      <NotFound v-if="page.isNotFound" />
      <Content v-else-if="isHome" class="home" />
      <div v-else class="page-grid">
        <article class="page" :class="{ api: isApi }">
          <PageHeader />
          <Content class="vp-doc doc-body" />
          <PageFooter />
        </article>
        <aside v-if="hasOutline" class="outline-col">
          <Outline />
        </aside>
      </div>
      <footer v-if="isHome" class="site-footer">
        <p>
          An educational student project trading simulated money. Nothing here is investment advice, and past
          simulated performance does not predict future results.
        </p>
      </footer>
    </main>
  </div>
</template>
