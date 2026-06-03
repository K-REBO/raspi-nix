<script lang="ts">
  import { onMount, onDestroy, tick } from 'svelte';

  interface Step {
    id: string;
    label: string;
    status: 'pending' | 'running' | 'done' | 'error';
    startedAt?: string;
    finishedAt?: string;
    log: string;
  }
  interface Job {
    id?: string;
    status: 'running' | 'done' | 'error' | 'none';
    startTime?: string;
    startedAt?: string;
    finishedAt?: string;
    steps?: Step[];
    exitCode?: number;
  }

  let job: Job = { status: 'none' };
  let submitting = false;
  let expandedStep: string | null = null;
  let es: EventSource | null = null;
  let logEl: HTMLPreElement | null = null;

  function elapsed(a?: string, b?: string): string {
    if (!a) return '';
    const ms = (b ? new Date(b) : new Date()).getTime() - new Date(a).getTime();
    const s = Math.round(ms / 1000);
    return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${s % 60}s`;
  }

  function autoExpand(j: Job) {
    // 実行中のステップを自動展開
    const running = j.steps?.find(s => s.status === 'running');
    if (running) expandedStep = running.id;
    else if (j.status !== 'running' && !expandedStep) {
      expandedStep = j.steps?.at(-1)?.id ?? null;
    }
  }

  async function scrollLog() {
    await tick();
    logEl?.scrollTo({ top: logEl.scrollHeight, behavior: 'smooth' });
  }

  function connectSSE() {
    es?.close();
    es = new EventSource('/api/scheduler/logs');
    es.onmessage = async (e) => {
      job = JSON.parse(e.data);
      autoExpand(job);
      await scrollLog();
      if (job.status !== 'running') { es?.close(); es = null; }
    };
    es.onerror = () => { es?.close(); es = null; };
  }

  async function run() {
    submitting = true;
    expandedStep = null;
    try {
      const res = await fetch('/api/scheduler/run', { method: 'POST' });
      const data = await res.json();
      job = data.job ?? job;
      autoExpand(job);
      connectSSE();
    } finally {
      submitting = false;
    }
  }

  onMount(async () => {
    const res = await fetch('/api/scheduler/job');
    job = await res.json();
    autoExpand(job);
    if (job.status === 'running') connectSSE();
  });

  onDestroy(() => es?.close());
</script>

<svelte:head><title>Scheduler — nixpi</title></svelte:head>

<div class="space-y-4">
  <!-- Header -->
  <div class="flex items-center justify-between">
    <div>
      <h1 class="text-xl font-semibold text-gray-900">Daily Note Scheduler</h1>
      <p class="text-sm text-gray-500 mt-0.5">habit / scheduled / tasks からスケジュールを生成して Obsidian vault に書き戻します</p>
    </div>
    <button
      class="btn btn-primary"
      on:click={run}
      disabled={submitting || job.status === 'running'}
    >
      {#if job.status === 'running'}
        <svg class="animate-spin w-4 h-4" fill="none" viewBox="0 0 24 24">
          <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/>
          <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8z"/>
        </svg>
        実行中...
      {:else}
        <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
            d="M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z"/>
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
            d="M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>
        </svg>
        Run scheduler
      {/if}
    </button>
  </div>

  {#if job.status === 'none'}
    <div class="card px-4 py-10 text-center text-gray-400 text-sm">まだ実行されていません</div>

  {:else}
    <!-- Summary bar -->
    <div class="card px-4 py-3 flex items-center gap-3">
      {#if job.status === 'running'}
        <svg class="animate-spin w-5 h-5 text-blue-500 shrink-0" fill="none" viewBox="0 0 24 24">
          <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/>
          <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8z"/>
        </svg>
        <span class="font-medium text-gray-900">実行中</span>
      {:else if job.status === 'done'}
        <svg class="w-5 h-5 text-green-600 shrink-0" viewBox="0 0 20 20" fill="currentColor">
          <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd"/>
        </svg>
        <span class="font-medium text-gray-900">完了</span>
      {:else}
        <svg class="w-5 h-5 text-red-500 shrink-0" viewBox="0 0 20 20" fill="currentColor">
          <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z" clip-rule="evenodd"/>
        </svg>
        <span class="font-medium text-gray-900">エラー</span>
      {/if}

      {#if job.startTime}
        <span class="text-gray-500 text-sm">開始: {job.startTime}</span>
      {/if}
      <span class="ml-auto text-xs text-gray-400">
        {#if job.startedAt}{new Date(job.startedAt).toLocaleString('ja-JP')}{/if}
        {#if job.startedAt} · {elapsed(job.startedAt, job.finishedAt)}{/if}
      </span>
    </div>

    <!-- Steps (GitHub Actions style) -->
    {#if job.steps && job.steps.length > 0}
      <div class="card divide-y divide-gray-100 overflow-hidden">
        {#each job.steps as step}
          {@const isExpanded = expandedStep === step.id}
          <!-- Step header (clickable) -->
          <button
            class="w-full flex items-center gap-3 px-4 py-2.5 text-left hover:bg-gray-50 transition-colors"
            on:click={() => expandedStep = isExpanded ? null : step.id}
          >
            <!-- Icon -->
            <span class="shrink-0 w-5 h-5 flex items-center justify-center">
              {#if step.status === 'running'}
                <svg class="animate-spin w-4 h-4 text-blue-500" fill="none" viewBox="0 0 24 24">
                  <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/>
                  <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8z"/>
                </svg>
              {:else if step.status === 'done'}
                <svg class="w-4 h-4 text-green-600" viewBox="0 0 20 20" fill="currentColor">
                  <path fill-rule="evenodd" d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" clip-rule="evenodd"/>
                </svg>
              {:else if step.status === 'error'}
                <svg class="w-4 h-4 text-red-500" viewBox="0 0 20 20" fill="currentColor">
                  <path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd"/>
                </svg>
              {:else}
                <span class="w-4 h-4 rounded-full border-2 border-gray-300"/>
              {/if}
            </span>

            <span class="flex-1 text-sm font-medium text-gray-800">{step.label}</span>

            <span class="text-xs text-gray-400 shrink-0">
              {elapsed(step.startedAt, step.finishedAt)}
            </span>

            <!-- Expand arrow -->
            <svg class="w-4 h-4 text-gray-400 shrink-0 transition-transform {isExpanded ? 'rotate-90' : ''}"
              fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7"/>
            </svg>
          </button>

          <!-- Log output (collapsible) -->
          {#if isExpanded && step.log}
            <pre bind:this={logEl}
              class="font-mono text-xs text-gray-200 bg-gray-900 px-5 py-3
                     overflow-auto max-h-80 whitespace-pre-wrap leading-relaxed
                     border-t border-gray-700">{step.log}</pre>
          {/if}
        {/each}
      </div>
    {/if}
  {/if}
</div>
