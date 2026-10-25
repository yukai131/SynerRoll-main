<script setup lang="ts">
import brand from '~~/config/brand.json'
useHead({ title: brand.displayName, link: [{ rel: 'icon', type: 'image/x-icon', href: '/favicon.ico' }] })
</script>

<template>
  <div class="min-h-screen">
    <NuxtRouteAnnouncer />
    <NuxtPage />
    <AppToastHost />
  </div>
</template>
