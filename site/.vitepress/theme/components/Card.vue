<script setup lang="ts">
import { computed } from 'vue'
import { withBase } from 'vitepress'
import Icon from './Icon.vue'

const props = defineProps<{ title: string; icon?: string; link?: string }>()
const external = computed(() => !!props.link && /^https?:/.test(props.link))
const href = computed(() => (props.link && !external.value ? withBase(props.link) : props.link))
</script>

<template>
  <component
    :is="link ? 'a' : 'div'"
    :href="href"
    class="card"
    :class="{ linked: !!link }"
    :target="external ? '_blank' : undefined"
    :rel="external ? 'noreferrer' : undefined"
  >
    <span v-if="icon" class="card-icon"><Icon :name="icon" /></span>
    <span class="card-title">
      {{ title }}
      <Icon v-if="external" name="external" class="card-external" />
    </span>
    <span class="card-body"><slot /></span>
  </component>
</template>
