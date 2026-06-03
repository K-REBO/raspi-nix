import { Hono } from 'hono';
import { spawn } from 'child_process';
import { existsSync } from 'fs';
import { resolve } from 'path';
import {
  getJob, isRunning, startJob, appendLog, finishJob, failJob, nextRoundTime,
} from '$lib/server/scheduler';

export const schedulerRouter = new Hono();

function resolveCmd(): string {
  if (process.env.SCHEDULER_CMD) return process.env.SCHEDULER_CMD;
  const local = resolve(process.cwd(), 'scripts/daily-note-scheduler');
  if (existsSync(local)) return local;
  return 'daily-note-scheduler';
}

function runBackground(startTime: string) {
  const cmd = resolveCmd();
  const [bin, ...args] = cmd.split(' ');

  const proc = spawn(bin, args, {
    env: { ...process.env, SCHEDULE_START_TIME: startTime },
  });

  proc.stdout.on('data', (d: Buffer) => appendLog(d.toString()));
  proc.stderr.on('data', (d: Buffer) => appendLog(d.toString()));

  proc.on('close', (code: number | null) => finishJob(code ?? 1));
  proc.on('error', (e: Error) => failJob(e.message));
}

// バックグラウンド開始
schedulerRouter.post('/run', (c) => {
  if (isRunning()) {
    return c.json({ status: 'already_running', job: getJob() });
  }
  const startTime = nextRoundTime();
  const job = startJob(startTime);
  runBackground(startTime);
  return c.json({ status: 'started', job });
});

// 現在のジョブ状態
schedulerRouter.get('/job', (c) => {
  return c.json(getJob() ?? { status: 'none' });
});

// SSE: リアルタイムログストリーム
schedulerRouter.get('/logs', (c) => {
  let timer: ReturnType<typeof setInterval> | null = null;

  const stream = new ReadableStream({
    start(ctrl) {
      const enc = new TextEncoder();
      const send = (data: unknown) =>
        ctrl.enqueue(enc.encode(`data: ${JSON.stringify(data)}\n\n`));

      send(getJob() ?? { status: 'none' });

      timer = setInterval(() => {
        const job = getJob();
        send(job ?? { status: 'none' });
        if (!job || job.status !== 'running') {
          clearInterval(timer!);
          timer = null;
          ctrl.close();
        }
      }, 1000);
    },
    cancel() {
      if (timer) clearInterval(timer);
    },
  });

  return new Response(stream, {
    headers: {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'X-Accel-Buffering': 'no',
    },
  });
});
