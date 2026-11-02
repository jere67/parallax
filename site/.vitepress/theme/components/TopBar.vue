<script setup lang="ts">
import { useData } from 'vitepress'
import { VPNavBarSearch } from 'vitepress/theme-without-fonts'
import Mark from './Mark.vue'
import Icon from './Icon.vue'
import { useNav } from '../nav'

defineProps<{ drawer: boolean; crumb: string }>()
defineEmits<{ toggle: [] }>()

const { isDark, theme } = useData()
const { tabs, activeTab, current, withBase } = useNav()
const repo = (theme.value.socialLinks ?? [])[0]?.link
</script>

<template>
  <header class="topbar">
    <div class="topbar-row">
      <a :href="withBase('/')" class="brand" aria-label="Trading Agent docs, home">
        <Mark />
        <span class="brand-name display">Trading Agent</span>
        <span class="brand-tag">Docs</span>
      </a>
      <div class="topbar-search">
        <VPNavBarSearch />
      </div>
      <div class="topbar-end">
        <a v-if="repo" :href="repo" class="icon-button" aria-label="Source on GitHub" title="Source on GitHub">
          <Icon name="github" />
        </a>
        <button
          type="button"
          class="icon-button"
          :aria-label="isDark ? 'Switch to light theme' : 'Switch to dark theme'"
          :title="isDark ? 'Light theme' : 'Dark theme'"
          @click="isDark = !isDark"
        >
          <Icon :name="isDark ? 'sun' : 'moon'" />
        </button>
      </div>
    </div>

    <nav class="topbar-tabs" aria-label="Sections">
      <a
        v-for="tab in tabs"
        :key="tab.link"
        :href="withBase(tab.link)"
        class="topbar-tab"
        :class="{ active: activeTab?.link === tab.link }"
        :aria-current="activeTab?.link === tab.link ? 'location' : undefined"
      >
        {{ tab.text }}
      </a>
    </nav>

    <button type="button" class="crumbs" :aria-expanded="drawer" aria-controls="sidebar" @click="$emit('toggle')">
      <Icon :name="drawer ? 'close' : 'menu'" />
      <span v-if="crumb" class="crumb-group">{{ crumb }}</span>
      <Icon v-if="crumb && current" name="chevron" class="crumb-chevron" />
      <span class="crumb-page">{{ current?.text ?? activeTab?.text ?? 'Menu' }}</span>
    </button>
  </header>
</template>
