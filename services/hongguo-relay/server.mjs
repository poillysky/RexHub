// 红果播放中转服务（v3.0.1）本地运行外壳。
// worker.mjs 是标准 Worker 模块（export default { fetch }），这里用 Node
// 起一个最小 HTTP 服务把请求转成 web Request，并提供一个 waitUntil 版 ctx。
import http from 'node:http';
import worker from './worker.mjs';

const PORT = Number(process.env.PORT || 8788);
const HOST = process.env.HOST || '127.0.0.1';
const env = { RELAY_KEY: process.env.RELAY_KEY || 'rexhub-hg' };

const ctx = {
  waitUntil(promise) {
    Promise.resolve(promise).catch(() => {});
  },
};

async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return chunks.length ? Buffer.concat(chunks) : null;
}

const server = http.createServer(async (req, res) => {
  try {
    const body = await readBody(req);
    const headers = new Headers();
    for (const [k, v] of Object.entries(req.headers)) {
      if (Array.isArray(v)) for (const item of v) headers.append(k, item);
      else if (v !== undefined) headers.set(k, v);
    }
    const request = new Request('http://' + (req.headers.host || HOST + ':' + PORT) + req.url, {
      method: req.method,
      headers,
      body: body && req.method !== 'GET' && req.method !== 'HEAD' ? body : undefined,
    });
    const response = await worker.fetch(request, env, ctx);
    const outHeaders = {};
    response.headers.forEach((value, key) => { outHeaders[key] = value; });
    res.writeHead(response.status, outHeaders);
    const buffer = Buffer.from(await response.arrayBuffer());
    res.end(buffer);
  } catch (error) {
    console.error('[hongguo-relay] handler error:', error);
    res.writeHead(500, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ ok: false, error: String(error && error.message) }));
  }
});

server.listen(PORT, HOST, () => {
  console.log('[hongguo-relay] listening on http://' + HOST + ':' + PORT + ' key=' + env.RELAY_KEY);
});
