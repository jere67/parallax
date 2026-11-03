<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { useData } from 'vitepress'
import { useNav } from '../nav'
import { SOURCE_URL } from '../../repo'
import Icon from './Icon.vue'
import EndpointBar from './EndpointBar.vue'

const { frontmatter, params, page, title } = useData()
const { currentGroup } = useNav()

// Mirrored design docs carry their title and description as route params.
const heading = computed(() => frontmatter.value.title ?? params.value?.title ?? title.value)
const description = computed(() => frontmatter.value.description ?? params.value?.description ?? '')
const eyebrow = computed(() => frontmatter.value.eyebrow ?? params.value?.eyebrow ?? currentGroup.value)
const source = computed(() => params.value?.source ?? `site/${page.value.relativePath}`)

const copied = ref(false)
const menu = ref(false)

async function copyPage() {
  const body = document.querySelector('.doc-body') as HTMLElement | null
  const text = [`# ${heading.value}`, description.value, body?.innerText ?? ''].filter(Boolean).join('\n\n')
  try {
    await navigator.clipboard.writeText(text)
    copied.value = true
    setTimeout(() => (copied.value = false), 1500)
  } catch {
    // The clipboard can be blocked (an insecure origin, a denied permission); nothing to undo.
  }
}

function closeMenu(event: MouseEvent) {
  if (!(event.target as HTMLElement).closest('.page-actions')) menu.value = false
}
onMounted(() => document.addEventListener('click', closeMenu))
onUnmounted(() => document.removeEventListener('click', closeMenu))
</script>

<template>
  <header class="page-header">
    <div v-if="eyebrow" class="eyebrow">{{ eyebrow }}</div>
    <div class="title-row">
      <h1 class="page-title display">{{ heading }}</h1>
      <div class="page-actions">
        <button type="button" class="action-main" @click="copyPage">
          <Icon :name="copied ? 'check' : 'copy'" />
          <span>{{ copied ? 'Copied' : 'Copy page' }}</span>
        </button>
        <button type="button" class="action-more" aria-label="More actions" :aria-expanded="menu" @click="menu = !menu">
          <Icon name="chevron-down" />
        </button>
        <div v-if="menu" class="action-menu" role="menu">
          <a :href="`${SOURCE_URL}/${source}`" role="menuitem" target="_blank" rel="noreferrer">
            <Icon name="file" /> <span>View source</span>
          </a>
          <a :href="`${SOURCE_URL.replace('/blob/', '/edit/')}/${source}`" role="menuitem" target="_blank" rel="noreferrer">
            <Icon name="pencil" /> <span>Edit on GitHub</span>
          </a>
        </div>
      </div>
    </div>
    <p v-if="description" class="page-description">{{ description }}</p>
    <EndpointBar v-if="frontmatter.api" :api="frontmatter.api" />
  </header>
</template>
