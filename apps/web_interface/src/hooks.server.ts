import type { Handle } from '@sveltejs/kit';
import { api } from '$lib/server/api';

export const handle: Handle = async ({ event, resolve }) => {
  if (event.url.pathname.startsWith('/api')) {
    return api.fetch(event.request);
  }
  return resolve(event);
};
