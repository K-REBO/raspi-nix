import { Hono } from 'hono';

export const downloaderRouter = new Hono();

downloaderRouter.get('/status', (c) => {
  return c.json({
    status: 'idle',
    message: 'iPod sync is ready',
  });
});

downloaderRouter.post('/sync', (c) => {
  // TODO: downloader/ ディレクトリのスクリプトと統合
  return c.json({
    status: 'not_implemented',
    message: 'Sync functionality will be implemented when the downloader submodule is integrated',
  }, 501);
});
