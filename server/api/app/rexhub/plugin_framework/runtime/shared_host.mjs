/**
 * RexHub Plugin Framework — Shared Runtime Host
 *
 * 一个 Node 进程托管多个 Worker 风格插件，按 `/p/<插件ID>/...` 前缀分流。
 * 配置文件由 Python 侧生成：{ "port": 1234, "plugins": [{"id","entrypoint"}] }
 *
 * 就绪后 stdout 输出 `REXHUB_MODULE_READY {"port":...}`。
 */

import { createServer } from 'node:http';
import { Readable } from 'node:stream';
import { pathToFileURL } from 'node:url';
import process from 'node:process';

const configPath = process.env.REXHUB_SHARED_CONFIG || process.argv[2] || '';

function logLine(...args) {
  process.stdout.write(`[shared] ${args.map(String).join(' ')}\n`);
}

for (const name of ['log', 'info', 'warn', 'error', 'debug']) {
  console[name] = (...args) => logLine(name.toUpperCase(), ...args);
}

let config = { port: 0, plugins: [] };
try {
  const { readFileSync } = await import('node:fs');
  config = JSON.parse(readFileSync(configPath, 'utf8'));
} catch (error) {
  logLine('FATAL', '共享运行时配置读取失败', String(error?.message || error));
  process.exit(1);
}

const host = process.env.REXHUB_MODULE_HOST || '0.0.0.0';
const port = Number(process.env.REXHUB_MODULE_PORT || config.port || 0);

const waitUntil = (promise) => {
  Promise.resolve(promise).catch((error) => logLine('ERROR', 'waitUntil 失败', String(error?.message || error)));
};
const context = { waitUntil, passThroughOnException() {} };

const plugins = new Map();
for (const item of config.plugins || []) {
  try {
    const mod = await import(pathToFileURL(item.entrypoint).href);
    const exported = mod.default ?? mod;
    if (typeof exported?.fetch === 'function') {
      plugins.set(String(item.id), exported.fetch.bind(exported));
    } else {
      logLine('WARN', `插件 ${item.id} 不是 Worker 风格，跳过`);
    }
  } catch (error) {
    logLine('ERROR', `插件 ${item.id} 加载失败`, String(error?.stack || error));
  }
}

function buildRequest(req, prefix) {
  const origin = `http://${req.headers.host || `127.0.0.1:${port}`}`;
  const raw = req.url || '/';
  if (!raw.startsWith(prefix)) return null;
  const rest = raw.slice(prefix.length) || '/';
  const url = new URL(rest, origin);
  const method = req.method || 'GET';
  const headers = new Headers();
  for (const [key, value] of Object.entries(req.headers)) {
    if (value === undefined) continue;
    if (Array.isArray(value)) value.forEach((item) => headers.append(key, item));
    else headers.set(key, String(value));
  }
  return new Request(url, {
    method,
    headers,
    body: method === 'GET' || method === 'HEAD' ? undefined : Readable.toWeb(req),
    duplex: 'half',
  });
}

const server = createServer(async (req, res) => {
  const raw = req.url || '/';
  if (raw === '/health' || raw === '/') {
    res.statusCode = 200;
    res.setHeader('content-type', 'application/json; charset=utf-8');
    res.end(JSON.stringify({ ok: true, runtime: 'shared', plugins: [...plugins.keys()] }));
    return;
  }
  const match = raw.match(/^\/p\/([^/]+)(\/.*)?$/);
  if (!match) {
    res.statusCode = 404;
    res.setHeader('content-type', 'application/json; charset=utf-8');
    res.end(JSON.stringify({ error: { code: 'NOT_FOUND', message: '插件路径不存在' } }));
    return;
  }
  const pluginId = decodeURIComponent(match[1]);
  const fetchHandler = plugins.get(pluginId);
  if (!fetchHandler) {
    res.statusCode = 404;
    res.setHeader('content-type', 'application/json; charset=utf-8');
    res.end(JSON.stringify({ error: { code: 'PLUGIN_NOT_LOADED', message: '插件未加载' } }));
    return;
  }
  try {
    const prefix = `/p/${match[1]}`;
    const request = buildRequest(req, prefix);
    const response = await fetchHandler(request, {}, context);
    if (!response) {
      res.statusCode = 204;
      res.end();
      return;
    }
    res.statusCode = response.status;
    if (response.statusText) res.statusMessage = response.statusText;
    response.headers.forEach((value, key) => {
      if (['transfer-encoding', 'connection'].includes(key.toLowerCase())) return;
      res.setHeader(key, value);
    });
    if (!response.body || req.method === 'HEAD') {
      res.end();
      return;
    }
    Readable.fromWeb(response.body).on('error', () => res.destroy()).pipe(res);
  } catch (error) {
    logLine('ERROR', `插件 ${pluginId} 处理失败`, String(error?.stack || error));
    if (!res.headersSent) {
      res.statusCode = 500;
      res.setHeader('content-type', 'application/json; charset=utf-8');
    }
    res.end(JSON.stringify({ error: { code: 'PLUGIN_ERROR', message: '插件处理请求失败' } }));
  }
});

server.listen(port, host, () => {
  const bound = server.address();
  const actual = typeof bound === 'object' && bound ? bound.port : port;
  logLine('共享运行时已启动', `http://${host}:${actual}`, `插件 ${plugins.size} 个`);
  process.stdout.write(`REXHUB_MODULE_READY ${JSON.stringify({ port: actual })}\n`);
});

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    logLine('收到退出信号', signal);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 3000).unref();
  });
}
