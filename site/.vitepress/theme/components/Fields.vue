<script setup lang="ts">
import Icon from './Icon.vue'

// A collapsible list of child fields under a parameter, closed until opened.
withDefaults(defineProps<{ title?: string; open?: boolean }>(), { title: 'Show child attributes', open: false })
</script>

<template>
  <details class="fields" :open="open">
    <summary class="fields-summary">
      <Icon name="chevron" class="fields-caret" />
      <span>{{ title }}</span>
    </summary>
    <div class="fields-body">
      <slot />
    </div>
  </details>
</template>
