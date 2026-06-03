import { writeFileSync, readFileSync, existsSync, mkdirSync } from 'fs';
import { resolve } from 'path';

export interface Step {
  id: string;
  label: string;
  status: 'pending' | 'running' | 'done' | 'error';
  startedAt?: string;
  finishedAt?: string;
  log: string;
}

export interface Job {
  id: string;
  status: 'running' | 'done' | 'error';
  startTime: string;
  startedAt: string;
  finishedAt?: string;
  steps: Step[];
  exitCode?: number;
}

// ステップマーカーのプロトコル (stderr 経由)
// ::step::<id>::<label>     → ステップ開始
// ::step-done::<id>         → ステップ完了
// ::step-error::<id>::<msg> → ステップ失敗

const RE_START = /^::step::([^:]+)::(.+)$/;
const RE_DONE  = /^::step-done::([^:]+)$/;
const RE_ERROR = /^::step-error::([^:]+)::(.*)$/;

const DATA_DIR = process.env.DATA_DIR ?? '/tmp/web-interface-data';
const JOB_FILE = resolve(DATA_DIR, 'scheduler-job.json');

let current: Job | null = null;

try {
  if (existsSync(JOB_FILE)) {
    current = JSON.parse(readFileSync(JOB_FILE, 'utf8'));
    if (current?.status === 'running') {
      markAllStepsError(current, 'サーバーが再起動されました');
      current.status = 'error';
      current.finishedAt = new Date().toISOString();
      persist();
    }
  }
} catch {}

function markAllStepsError(job: Job, msg: string) {
  for (const s of job.steps) {
    if (s.status === 'running' || s.status === 'pending') {
      s.status = 'error';
      s.log += `\n${msg}`;
      s.finishedAt = new Date().toISOString();
    }
  }
}

function persist() {
  try {
    mkdirSync(DATA_DIR, { recursive: true });
    writeFileSync(JOB_FILE, JSON.stringify(current));
  } catch {}
}

export function getJob(): Job | null { return current; }
export function isRunning(): boolean { return current?.status === 'running'; }

export function startJob(startTime: string): Job {
  current = {
    id: crypto.randomUUID(),
    status: 'running',
    startTime,
    startedAt: new Date().toISOString(),
    steps: [],
  };
  persist();
  return current;
}

export function appendLog(chunk: string) {
  if (!current || current.status !== 'running') return;

  const ts = () => new Date().toLocaleTimeString('ja-JP', { hour12: false });

  for (const rawLine of chunk.split('\n')) {
    const line = rawLine.trimEnd();

    // ステップ開始マーカー
    const mStart = line.match(RE_START);
    if (mStart) {
      const [, id, label] = mStart;
      // 実行中のステップを完了に
      const prev = current.steps.find(s => s.status === 'running');
      if (prev) { prev.status = 'done'; prev.finishedAt = ts(); }
      current.steps.push({ id, label, status: 'running', startedAt: ts(), log: '' });
      persist();
      continue;
    }

    // ステップ完了マーカー
    const mDone = line.match(RE_DONE);
    if (mDone) {
      const s = current.steps.find(x => x.id === mDone[1]);
      if (s) { s.status = 'done'; s.finishedAt = ts(); }
      persist();
      continue;
    }

    // ステップエラーマーカー
    const mErr = line.match(RE_ERROR);
    if (mErr) {
      const s = current.steps.find(x => x.id === mErr[1]);
      if (s) { s.status = 'error'; s.finishedAt = ts(); s.log += mErr[2]; }
      persist();
      continue;
    }

    // 通常ログ: 実行中ステップに追記
    if (line !== '') {
      const active = current.steps.findLast(s => s.status === 'running')
        ?? current.steps.at(-1);
      if (active) active.log += `[${ts()}] ${line}\n`;
    }
  }

  persist();
}

export function finishJob(exitCode: number) {
  if (!current) return;
  current.status = exitCode === 0 ? 'done' : 'error';
  current.exitCode = exitCode;
  current.finishedAt = new Date().toISOString();
  // 残っている running/pending ステップを閉じる
  for (const s of current.steps) {
    if (s.status === 'running') s.status = exitCode === 0 ? 'done' : 'error';
    if (s.status === 'pending') s.status = exitCode === 0 ? 'done' : 'error';
    if (!s.finishedAt) s.finishedAt = current.finishedAt;
  }
  persist();
}

export function failJob(message: string) {
  if (!current) return;
  current.status = 'error';
  current.finishedAt = new Date().toISOString();
  markAllStepsError(current, message);
  persist();
}

export function nextRoundTime(): string {
  const now = new Date();
  const h = now.getHours();
  const m = now.getMinutes();
  if (m === 0)  return `${h.toString().padStart(2, '0')}:00`;
  if (m <= 30)  return `${h.toString().padStart(2, '0')}:30`;
  const next = (h + 1) % 24;
  return `${next.toString().padStart(2, '0')}:00`;
}
