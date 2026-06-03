import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';

export interface Module {
  id: string;
  name: string;
  description: string;
  enabled: boolean;
  route: string;
}

const DATA_DIR = process.env.DATA_DIR ?? './data';
const MODULES_FILE = join(DATA_DIR, 'modules.json');

const MODULE_REGISTRY: Module[] = [
  {
    id: 'downloader',
    name: 'Downloader',
    description: 'iPod sync utility',
    enabled: true,
    route: '/downloader',
  },
  {
    id: 'ipod',
    name: 'iPod',
    description: 'iPod management utilities',
    enabled: true,
    route: '/ipod',
  },
  {
    id: 'scheduler',
    name: 'Scheduler',
    description: 'Daily note scheduler',
    enabled: true,
    route: '/scheduler',
  },
];

function loadModules(): Module[] {
  try {
    if (existsSync(MODULES_FILE)) {
      const saved: { id: string; enabled: boolean }[] = JSON.parse(
        readFileSync(MODULES_FILE, 'utf-8')
      );
      return MODULE_REGISTRY.map((m) => {
        const override = saved.find((s) => s.id === m.id);
        return override ? { ...m, enabled: override.enabled } : m;
      });
    }
  } catch {
    // ignore read errors, return defaults
  }
  return [...MODULE_REGISTRY];
}

function saveModules(modules: Module[]): void {
  try {
    mkdirSync(DATA_DIR, { recursive: true });
    writeFileSync(
      MODULES_FILE,
      JSON.stringify(modules.map(({ id, enabled }) => ({ id, enabled })), null, 2)
    );
  } catch {
    // ignore write errors
  }
}

let _modules: Module[] = loadModules();

export function getModules(): Module[] {
  return _modules;
}

export function toggleModule(id: string): Module | null {
  const idx = _modules.findIndex((m) => m.id === id);
  if (idx === -1) return null;
  _modules[idx] = { ..._modules[idx], enabled: !_modules[idx].enabled };
  saveModules(_modules);
  return _modules[idx];
}
