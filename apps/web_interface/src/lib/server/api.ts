import { Hono } from 'hono';
import { getModules, toggleModule } from './modules';
import { downloaderRouter } from '../../routes/downloader/api/router';
// ipod_utils submodule not initialized — router disabled
// import { ipodRouter } from '../../../ipod_utils/web/src/lib/server/api';
import { schedulerRouter } from '../../routes/scheduler/api/router';

const app = new Hono();

// ヘルスチェック
app.get('/api/health', (c) => {
  const modules = getModules();
  return c.json({
    status: 'ok',
    uptime: process.uptime(),
    memory: process.memoryUsage(),
    bun: process.versions.bun ?? 'N/A',
    modules: {
      total: modules.length,
      enabled: modules.filter((m) => m.enabled).length,
    },
    timestamp: new Date().toISOString(),
  });
});

// モジュール一覧
app.get('/api/modules', (c) => {
  const modules = getModules();
  return c.json({ modules });
});

// モジュールon/off切り替え
app.post('/api/modules/:id/toggle', (c) => {
  const id = c.req.param('id');
  const updated = toggleModule(id);
  if (!updated) {
    return c.json({ error: 'Module not found' }, 404);
  }
  return c.json({ module: updated });
});

// 各モジュールのサブルーター
app.route('/api/downloader', downloaderRouter);
// app.route('/api/ipod', ipodRouter);
app.route('/api/scheduler', schedulerRouter);

export { app as api };
