<script setup lang="ts">
// A grid of link cards: two columns by default, one on a phone.
withDefaults(defineProps<{ cols?: number }>(), { cols: 2 })
</script>

<template>
  <div class="cards" :style="{ '--cols': cols }">
    <slot />
  </div>
</template>
