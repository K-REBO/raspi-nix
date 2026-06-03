<script lang="ts">
  import { page } from '$app/stores';

  const tabs = [
    { href: '/ipod/home', label: 'Home' },
    { href: '/ipod/config', label: 'Config' },
    { href: '/ipod/replay', label: 'Replay' },
  ];
</script>

<div class="space-y-4">
  <div class="flex items-center gap-2">
    <h1 class="text-xl font-semibold text-gray-900">iPod</h1>
  </div>

  <nav class="flex gap-1 border-b border-border">
    {#each tabs as { href, label }}
      <a
        {href}
        class="px-3 py-2 text-sm font-medium border-b-2 transition-colors -mb-px
               {$page.url.pathname === href
                 ? 'border-blue-500 text-blue-600'
                 : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300'}"
      >
        {label}
      </a>
    {/each}
  </nav>

  <slot />
</div>
