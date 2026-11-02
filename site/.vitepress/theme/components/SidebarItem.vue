<script setup lang="ts">
import { computed, ref } from 'vue'
import { useData, withBase } from 'vitepress'
import { isActive, type Item } from '../nav'
import Icon from './Icon.vue'

const props = defineProps<{ item: Item; depth: number }>()
const { page } = useData()

const active = computed(() => isActive(page.value.relativePath, props.item.link))
const holdsActive = computed(() => {
  const walk = (items: Item[] = []): boolean =>
    items.some((i) => isActive(page.value.relativePath, i.link) || walk(i.items))
  return walk(props.item.items)
})
const open = ref(props.item.collapsed !== true || holdsActive.value)
const method = computed(() => (props.item as Item & { badge?: string }).badge)
</script>

<template>
  <li class="sidebar-item" :style="{ '--depth': depth }">
    <template v-if="item.items">
      <button type="button" class="sidebar-link sidebar-toggle" :aria-expanded="open" @click="open = !open">
        <span>{{ item.text }}</span>
        <Icon name="chevron" class="sidebar-caret" :class="{ open }" />
      </button>
      <ul v-show="open">
        <SidebarItem v-for="child in item.items" :key="child.text" :item="child" :depth="depth + 1" />
      </ul>
    </template>
    <a
      v-else
      :href="withBase(item.link!)"
      class="sidebar-link"
      :class="{ active, 'has-method': method }"
      :aria-current="active ? 'page' : undefined"
    >
      <span v-if="method" class="method-pill" :class="method.toLowerCase()">{{ method }}</span>
      <span class="sidebar-text" :class="{ mono: method }">{{ item.text }}</span>
    </a>
  </li>
</template>
