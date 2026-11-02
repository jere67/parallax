<script setup lang="ts">
import { onMounted, onUnmounted, ref } from 'vue'
import { onContentUpdated, useData } from 'vitepress'

interface Heading {
  id: string
  text: string
  level: number
}

const { frontmatter } = useData()
const headings = ref<Heading[]>([])
const active = ref('')

// The page's h2 and h3 headings (h2 only when the page asks for it), read after each render.
function collect() {
  const deep = frontmatter.value.outline !== 2
  const selector = deep ? '.doc-body h2[id], .doc-body h3[id]' : '.doc-body h2[id]'
  headings.value = [...document.querySelectorAll<HTMLElement>(selector)].map((el) => ({
    id: el.id,
    text: [...el.childNodes]
      .filter((n) => !(n instanceof HTMLElement && n.classList.contains('header-anchor')))
      .map((n) => n.textContent)
      .join('')
      .trim(),
    level: Number(el.tagName[1])
  }))
  spy()
}

// The active heading is the last one above a line just under the top bar.
function spy() {
  const line = 96 + 48
  let current = headings.value[0]?.id ?? ''
  for (const h of headings.value) {
    const el = document.getElementById(h.id)
    if (el && el.getBoundingClientRect().top <= line) current = h.id
  }
  if (window.innerHeight + window.scrollY >= document.body.offsetHeight - 2 && headings.value.length) {
    current = headings.value[headings.value.length - 1].id
  }
  active.value = current
}

onContentUpdated(collect)
onMounted(() => {
  collect()
  window.addEventListener('scroll', spy, { passive: true })
})
onUnmounted(() => window.removeEventListener('scroll', spy))
</script>

<template>
  <nav v-if="headings.length" class="outline" aria-labelledby="outline-title">
    <div id="outline-title" class="outline-title">On this page</div>
    <ul>
      <li v-for="h in headings" :key="h.id">
        <a :href="`#${h.id}`" class="outline-link" :class="{ active: active === h.id, nested: h.level === 3 }">{{ h.text }}</a>
      </li>
    </ul>
  </nav>
</template>
