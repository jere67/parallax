<script setup lang="ts">
import { useNav } from '../nav'
import SidebarItem from './SidebarItem.vue'

// On a phone the drawer also lists the tabs, since the tab row is hidden there.
defineProps<{ mobile: boolean }>()
const { sidebar, tabs, activeTab, withBase } = useNav()
</script>

<template>
  <nav id="sidebar" class="sidebar-nav">
    <div v-if="mobile" class="sidebar-tabs">
      <a
        v-for="tab in tabs"
        :key="tab.link"
        :href="withBase(tab.link)"
        class="sidebar-tab"
        :class="{ active: activeTab?.link === tab.link }"
      >
        {{ tab.text }}
      </a>
    </div>
    <section v-for="group in sidebar" :key="group.text" class="sidebar-group">
      <h3 class="sidebar-heading">{{ group.text }}</h3>
      <ul>
        <SidebarItem v-for="item in group.items" :key="item.text" :item="item" :depth="0" />
      </ul>
    </section>
  </nav>
</template>
