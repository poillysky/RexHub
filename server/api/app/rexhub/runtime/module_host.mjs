/**
 * RexHub 本地功能模块宿主机（Node 22+）
 *
 * 用法：
 *   node module_host.mjs /path/to/module.mjs
 *
 * 模块契约（二选一）：
 *   1. Worker 风格：export default { fetch(request, env, ctx) }
 *      —— 宿主机起 HTTP 服务，把请求转给模块的 fetch，响应原样回传（支持 Range 流）。
 *   2. 启动脚本：export default function start(ctx) 或 export function start(ctx)
 *      —— 宿主机把端口/环境变量交给模块，由模块自行监听或执行任务。
 *
 * 端口、监听地址、模块环境变量经环境变量传入：
 *   REXHUB_MODULE_PORT / REXHUB_MODULE_HOST / REXHUB_MODULE_ENV(JSON) / REXHUB_MODULE_ID
 * 就绪后 stdout 输出一行 `REXHUB_MODULE_READY {"port":1234}`，供 Python 侧判定启动成功。
 */

import { createServer } from 'node:http';
import { Readable } from 'node:stream';
import { pathToFileURL } from 'node:url';
import process from 'node:process';

const sourcePath = process.argv[2] || '';
const port = Number(process.env.REXHUB_MODULE_PORT || 0);
const host = process.env.REXHUB_MODULE_HOST || '0.0.0.0';
const moduleId = process.env.REXHUB_MODULE_ID || 'module';

function stringify(value) {
  if (typeof value === 'string') return value;
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

function logLine(...args) {
  process.stdout.write(`[${moduleId}] ${args.map(stringify).join(' ')}\n`);
}

// 模块内 console 输出统一进日志管道（stderr 也由 Python 侧合并）
for (const name of ['log', 'info', 'warn', 'error', 'debug']) {
  console[name] = (...args) => logLine(name.toUpperCase(), ...args);
}

let env = {};
try {
  env = JSON.parse(process.env.REXHUB_MODULE_ENV || '{}');
} catch {
  logLine('WARN', 'REXHUB_MODULE_ENV 不是合法 JSON，已忽略');
}

function ready(actualPort) {
  process.stdout.write(`REXHUB_MODULE_READY ${JSON.stringify({ port: actualPort })}\n`);
}

function requestHeaders(raw) {
  const headers = new Headers();
  for (const [key, value] of Object.entries(raw)) {
    if (value === undefined) continue;
    if (Array.isArray(value)) value.forEach((item) => headers.append(key, item));
    else headers.set(key, String(value));
  }
  return headers;
}

const waitUntil = (promise) => {
  Promise.resolve(promise).catch((error) => {
    logLine('ERROR', 'waitUntil 任务失败', String((error && error.message) || error));
  });
};

const context = { waitUntil, passThroughOnException() {} };

function startHttpServer(fetchHandler) {
  const server = createServer(async (req, res) => {
    const origin = `http://${req.headers.host || `127.0.0.1:${port}`}`;
    try {
      const url = new URL(req.url || '/', origin);
      const method = req.method || 'GET';
      const request = new Request(url, {
        method,
        headers: requestHeaders(req.headers),
        body: method === 'GET' || method === 'HEAD' ? undefined : Readable.toWeb(req),
        duplex: 'half',
      });
      const response = await fetchHandler(request, env, context);
      if (!response) {
        res.statusCode = 204;
        res.end();
        return;
      }
      res.statusCode = response.status;
      if (response.statusText) res.statusMessage = response.statusText;
      response.headers.forEach((value, key) => {
        // 传输层头交给 Node 决定，其余（含 Content-Length / Content-Range）原样转发
        if (['transfer-encoding', 'connection'].includes(key.toLowerCase())) return;
        res.setHeader(key, value);
      });
      if (!response.body || method === 'HEAD') {
        res.end();
        return;
      }
      Readable.fromWeb(response.body)
        .on('error', () => res.destroy())
        .pipe(res);
    } catch (error) {
      logLine('ERROR', '请求处理失败', String((error && error.stack) || error));
      if (!res.headersSent) {
        res.statusCode = 500;
        res.setHeader('content-type', 'application/json; charset=utf-8');
      }
      res.end(JSON.stringify({ error: { code: 'MODULE_ERROR', message: '模块处理请求失败' } }));
    }
  });

  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, () => {
      const actual = server.address();
      const bound = typeof actual === 'object' && actual ? actual.port : port;
      logLine('HTTP 服务已启动', `http://${host}:${bound}`);
      ready(bound);
      resolve(server);
    });
  });
}

let cleanup = null;
let closing = false;

async function shutdown(signal) {
  if (closing) return;
  closing = true;
  logLine('收到退出信号', signal);
  try {
    if (typeof cleanup === 'function') await cleanup();
  } catch (error) {
    logLine('WARN', '模块清理失败', String((error && error.message) || error));
  }
  process.exit(0);
}

process.on('SIGTERM', () => void shutdown('SIGTERM'));
process.on('SIGINT', () => void shutdown('SIGINT'));

async function main() {
  if (!sourcePath) throw new Error('缺少模块文件路径');
  const mod = await import(pathToFileURL(sourcePath).href);
  const exported = mod.default ?? mod;

  if (exported && typeof exported.fetch === 'function') {
    await startHttpServer(exported.fetch.bind(exported));
    return;
  }

  const start = typeof exported === 'function' ? exported : exported && exported.start;
  if (typeof start !== 'function') {
    throw new Error('模块需导出 fetch(request, env, ctx) 或 start(ctx)');
  }

  // 脚本型模块：先把端口交给模块，再输出就绪标记（模块通常自行 listen）。
  ready(port);
  const result = await start({
    id: moduleId,
    port,
    host,
    env,
    log: (...args) => logLine(...args),
    waitUntil,
  });
  if (typeof result === 'function') {
    cleanup = result;
    await new Promise(() => {});
  }
}

main().catch((error) => {
  logLine('FATAL', String((error && error.stack) || error));
  process.exit(1);
});
