<script setup lang="ts">
import { computed } from 'vue'
import { useData, withBase } from 'vitepress'
import { useNav } from '../nav'
import Icon from './Icon.vue'

const { frontmatter, page } = useData()
const { prev, next } = useNav()

const related = computed(() => (frontmatter.value.related ?? []) as { text: string; link: string }[])
const updated = computed(() => {
  if (!page.value.lastUpdated) return ''
  return new Date(page.value.lastUpdated).toLocaleDateString('en-US', {
    year: 'numeric',
    month: 'long',
    day: 'numeric'
  })
})
</script>

<template>
  <footer class="page-footer">
    <div v-if="related.length" class="related">
      <p class="related-title">Related topics</p>
      <a v-for="r in related" :key="r.link" :href="withBase(r.link)" class="related-link">
        <Icon name="file" /> <span>{{ r.text }}</span>
      </a>
    </div>

    <nav v-if="prev || next" class="pager" aria-label="Pagination">
      <a v-if="prev" :href="withBase(prev.link)" class="pager-link prev" rel="prev">
        <span class="pager-label"><Icon name="chevron" class="flip" /> Previous</span>
        <span class="pager-title">{{ prev.text }}</span>
      </a>
      <span v-else />
      <a v-if="next" :href="withBase(next.link)" class="pager-link next" rel="next">
        <span class="pager-label">Next <Icon name="chevron" /></span>
        <span class="pager-title">{{ next.text }}</span>
      </a>
    </nav>

    <div class="page-meta">
      <p>
        An educational student project trading simulated money. Nothing here is investment advice, and past simulated
        performance does not predict future results.
      </p>
      <p v-if="updated" class="page-updated">Updated {{ updated }}</p>
    </div>
  </footer>
</template>
