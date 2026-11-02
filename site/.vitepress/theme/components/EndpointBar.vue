<script setup lang="ts">
import { ref } from 'vue'
import Icon from './Icon.vue'

// The method and route of an API page, with the local base URL the quickstart serves on.
const props = defineProps<{ api: { method: string; path: string; auth?: string } }>()
const BASE = 'http://localhost:8000'
const copied = ref(false)

async function copy() {
  try {
    await navigator.clipboard.writeText(BASE + props.api.path)
    copied.value = true
    setTimeout(() => (copied.value = false), 1500)
  } catch {}
}
</script>

<template>
  <div class="endpoint">
    <div class="endpoint-route">
      <span class="method-pill large" :class="api.method.toLowerCase()">{{ api.method }}</span>
      <span class="endpoint-url mono">
        <span class="endpoint-base">{{ BASE }}</span>
        <template v-for="(part, i) in api.path.split('/').filter(Boolean)" :key="i">
          <span class="endpoint-slash">/</span><span class="endpoint-part">{{ part }}</span>
        </template>
      </span>
      <button type="button" class="endpoint-copy" :aria-label="copied ? 'Copied' : 'Copy URL'" @click="copy">
        <Icon :name="copied ? 'check' : 'copy'" />
      </button>
    </div>
    <span class="auth-pill" :class="{ locked: api.auth && api.auth !== 'none' }">
      {{ api.auth && api.auth !== 'none' ? api.auth : 'No auth' }}
    </span>
  </div>
</template>
