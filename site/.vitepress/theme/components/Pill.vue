<script setup lang="ts">
// A small status label in the dashboard's pill style: full-strength text on a 15% fill.
withDefaults(defineProps<{ tone?: 'accent' | 'up' | 'down' | 'warn' | 'muted' }>(), { tone: 'muted' })
</script>

<template>
  <span class="pill" :class="tone"><slot /></span>
</template>
