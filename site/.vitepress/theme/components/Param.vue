<script setup lang="ts">
// One parameter or response field: its name, type, and whether it is required, then a
// Markdown description in the slot. Nested fields go inside a <Fields> in that slot.
const props = defineProps<{ name: string; type?: string; required?: boolean; default?: string; location?: string }>()
// `default` is a reserved word in a template, so the template reads it through this.
const fallback = props.default
</script>

<template>
  <div class="param">
    <div class="param-head">
      <code class="param-name">{{ name }}</code>
      <span v-if="location" class="param-tag">{{ location }}</span>
      <span v-if="type" class="param-type">{{ type }}</span>
      <span v-if="required" class="param-required">required</span>
      <span v-if="fallback !== undefined" class="param-default">
        default: <code>{{ fallback }}</code>
      </span>
    </div>
    <div class="param-body">
      <slot />
    </div>
  </div>
</template>
