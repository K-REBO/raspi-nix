<script lang="ts">
  import { onMount } from 'svelte';

  interface Health {
    status: string;
    uptime: number;
    memory: { heapUsed: number; heapTotal: number; rss: number };
    bun: string;
    timestamp: string;
  }

  let health: Health | null = null;
  let error = false;

  function fmt(bytes: number) { return `${(bytes / 1024 / 1024).toFixed(0)} MB`; }
  function uptime(s: number) {
    const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
    return `${h}h ${m}m`;
  }

  onMount(async () => {
    try {
      const res = await fetch('/api/health');
      health = await res.json();
    } catch { error = true; }
  });
</script>

<svelte:head><title>Dashboard — nixpi</title></svelte:head>

<div class="space-y-6">
  <h1 class="text-xl font-semibold text-gray-900">Dashboard</h1>

  <!-- Stats -->
  <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
    {#if health}
      {#each [
        { label: 'Status', value: health.status, sub: new Date(health.timestamp).toLocaleTimeString('ja-JP') },
        { label: 'Uptime', value: uptime(health.uptime), sub: '稼働時間' },
        { label: 'Memory', value: fmt(health.memory.heapUsed), sub: `/ ${fmt(health.memory.heapTotal)}` },
        { label: 'Runtime', value: `Bun ${health.bun}`, sub: 'Linux arm64' },
      ] as s}
        <div class="card p-4">
          <div class="text-xs text-gray-500 mb-1">{s.label}</div>
          <div class="font-semibold text-gray-900">{s.value}</div>
          <div class="text-xs text-gray-400 mt-0.5">{s.sub}</div>
        </div>
      {/each}
    {:else if error}
      <div class="col-span-4 card p-4 text-red-500 text-sm">ヘルスチェック失敗</div>
    {:else}
      {#each [1,2,3,4] as _}
        <div class="card p-4 animate-pulse">
          <div class="h-3 bg-gray-100 rounded w-1/2 mb-2"/>
          <div class="h-5 bg-gray-100 rounded w-3/4"/>
        </div>
      {/each}
    {/if}
  </div>

  <!-- Quick links -->
  <div class="card divide-y divide-border">
    <div class="px-4 py-3 font-medium text-gray-700 text-sm">Quick links</div>
    {#each [
      { href: '/scheduler', icon: '📅', label: 'Daily Note Scheduler', desc: 'Obsidian デイリーノートのスケジュール生成' },
      { href: '/downloader', icon: '⬇', label: 'Downloader', desc: 'iPod sync' },
    ] as link}
      <a href={link.href} class="flex items-center gap-3 px-4 py-3 hover:bg-gray-50 transition-colors">
        <span class="text-lg">{link.icon}</span>
        <div>
          <div class="font-medium text-gray-900">{link.label}</div>
          <div class="text-xs text-gray-500">{link.desc}</div>
        </div>
        <svg class="ml-auto w-4 h-4 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7"/>
        </svg>
      </a>
    {/each}
  </div>
</div>
