import { writable } from 'svelte/store';

export interface Module {
  id: string;
  name: string;
  description: string;
  enabled: boolean;
  route: string;
}

export const modulesStore = writable<Module[]>([]);

export async function fetchModules(): Promise<void> {
  try {
    const res = await fetch('/api/modules');
    const data = await res.json();
    modulesStore.set(data.modules ?? []);
  } catch {
    // ignore
  }
}

export async function toggleModule(id: string): Promise<void> {
  try {
    const res = await fetch(`/api/modules/${id}/toggle`, { method: 'POST' });
    const data = await res.json();
    if (data.module) {
      modulesStore.update((modules) =>
        modules.map((m) => (m.id === id ? data.module : m))
      );
    }
  } catch {
    // ignore
  }
}
