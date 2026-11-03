<script setup lang="ts">
import { withBase } from 'vitepress'
</script>

<template>
  <div class="not-found">
    <p class="eyebrow">404</p>
    <h1 class="page-title display">Nothing filed under this page.</h1>
    <p class="page-description">The link may be old, or the page may have moved when the docs were reorganized.</p>
    <a :href="withBase('/')" class="btn btn-primary">Back to the docs home</a>
  </div>
</template>
