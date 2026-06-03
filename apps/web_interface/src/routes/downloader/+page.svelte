<script lang="ts">
  import { onMount } from 'svelte';

  let status: { status: string; message: string } | null = null;
  let syncing = false;
  let error = false;

  async function fetchStatus() {
    try {
      const res = await fetch('/api/downloader/status');
      status = await res.json();
      error = false;
    } catch {
      error = true;
    }
  }

  async function startSync() {
    syncing = true;
    try {
      const res = await fetch('/api/downloader/sync', { method: 'POST' });
      status = await res.json();
    } catch {
      error = true;
    } finally {
      syncing = false;
    }
  }

  onMount(fetchStatus);
</script>

<svelte:head><title>Downloader — nixpi</title></svelte:head>

<div class="space-y-6">
  <h1 class="text-xl font-semibold text-gray-900">Downloader</h1>

  <div class="card p-6 space-y-4">
    <div class="text-sm text-gray-500">
      {#if error}
        <span class="text-red-500">接続エラー</span>
      {:else if status}
        <span>Status: {status.status}</span>
        {#if status.message}<span class="ml-2 text-gray-400">{status.message}</span>{/if}
      {:else}
        <span class="animate-pulse">読み込み中...</span>
      {/if}
    </div>

    <button
      class="btn"
      disabled={syncing}
      on:click={startSync}
    >
      {syncing ? '同期中...' : 'iPod Sync 開始'}
    </button>
  </div>
</div>
