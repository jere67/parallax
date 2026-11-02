<script setup lang="ts">
// A framed figure: the slot holds a Markdown image so Vite bundles it; the caption sits below.
defineProps<{ caption?: string }>()
</script>

<template>
  <figure class="figure">
    <div class="figure-frame"><slot /></div>
    <figcaption v-if="caption">{{ caption }}</figcaption>
  </figure>
</template>
