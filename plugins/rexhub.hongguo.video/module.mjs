// 红果插件入口（干净版）。
// 播放链：JSTV 73532 + PlayerSign 四头 + 每集现注册身份 + 空包换身份切主机重发。
// 榜单 / 目录 / 搜索 / 详情：沿用 legacy.mjs（原有实现，未改动）。
import legacy from './legacy.mjs';
import { play } from './src/media.js';
import { createJstvClient } from './src/jstv.js';

const VIDEO_PATH = /^\/v1\/episodes\/[A-Za-z0-9_-]+\/stream\/?$/;
const client = createJstvClient();

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'Range, Content-Type',
  'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
  'Access-Control-Expose-Headers': 'Content-Range, Content-Length, Accept-Ranges, Content-Type',
};

function withCors(response) {
  const headers = new Headers(response.headers);
  for (const [key, value] of Object.entries(cors)) headers.set(key, value);
  return new Response(response.body, { status: response.status, headers });
}

export default {
  async fetch(request, env, ctx) {
    const { pathname } = new URL(request.url);
    if (!VIDEO_PATH.test(pathname)) return legacy.fetch(request, env, ctx);
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
    try {
      const videoId = decodeURIComponent(pathname.split('/')[3]);
      return withCors(await play(request, videoId, client));
    } catch (error) {
      return Response.json(
        { error: { code: 'MEDIA_UNAVAILABLE', message: error.message } },
        { status: 502, headers: { ...cors, 'Cache-Control': 'no-store' } },
      );
    }
  },
};
