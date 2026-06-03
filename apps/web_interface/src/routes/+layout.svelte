<script lang="ts">
  import '../app.css';
  import { page } from '$app/stores';

  const nav = [
    { href: '/dashboard', label: 'Dashboard' },
    { href: '/scheduler', label: 'Scheduler' },
    { href: '/downloader', label: 'Downloader' },
    { href: '/ipod', label: 'iPod' },
  ];
</script>

<div class="min-h-screen bg-canvas">
  <!-- Top header -->
  <header class="bg-gray-900 text-white">
    <div class="max-w-5xl mx-auto px-4 flex items-center gap-6 h-12">
      <span class="font-semibold text-white">🍓 nixpi</span>
      <nav class="flex gap-1">
        {#each nav as { href, label }}
          <a
            {href}
            class="px-3 py-1 rounded-md text-sm transition-colors
                   {$page.url.pathname.startsWith(href)
                     ? 'bg-gray-700 text-white'
                     : 'text-gray-300 hover:text-white hover:bg-gray-700'}"
          >
            {label}
          </a>
        {/each}
      </nav>
    </div>
  </header>

  <!-- Page content -->
  <main class="max-w-5xl mx-auto px-4 py-6">
    <slot />
  </main>
</div>
