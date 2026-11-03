<script setup lang="ts">
import { computed } from 'vue'

// A framed figure from the repo's docs/figures, by file name without the extension. The glob
// bundles every figure in dev and build alike, so pages never path outside site/ themselves.
const FIGURES = import.meta.glob<string>('@repo/docs/figures/*.png', { eager: true, import: 'default', query: '?url' })

const props = defineProps<{ name: string; alt: string; caption?: string }>()
const src = computed(() => {
  const key = Object.keys(FIGURES).find((k) => k.endsWith(`/${props.name}.png`))
  if (!key) throw new Error(`No figure named ${props.name} in docs/figures`)
  return FIGURES[key]
})
</script>

<template>
  <figure class="figure">
    <div class="figure-frame"><img :src="src" :alt="alt" loading="lazy" /></div>
    <figcaption v-if="caption">{{ caption }}</figcaption>
  </figure>
</template>
