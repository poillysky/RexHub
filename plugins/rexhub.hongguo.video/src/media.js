import { openMedia, mediaResponse } from './cenc.js';
import { selectMedia } from './media-codec.js';
import { ApiError } from './client.js';

// Bounded isolate-local preparation; raw URLs and CryptoKeys never enter JSON.
const prepared = new Map();
const MAX_ENTRIES = 12;
// Playback URLs stay valid until the upstream expire_time; keep a prepared
// entry reusable well beyond a single binge session. The upstream expiry and
// the 5s safety margin still cap every entry, so a stale entry can never
// select an expired CDN URL.
const MAX_TTL = 10 * 60 * 1000;
// One adjacent-episode prefetch per successful stream response: same client
// identity, same request shape as the real app player. Failures are silent.
const PREFETCH_ENABLED = true;

async function prepare(videoId, client, cache) {
  const now = Date.now();
  for (const [id, entry] of cache) if (entry.expires <= now) cache.delete(id);
  if (cache.has(videoId)) return cache.get(videoId).media;
  // Keep in-flight I/O inside its originating request. Only completed media
  // preparations can be reused by another Cloudflare request.
  const signal = AbortSignal.timeout(30000);
    const data = await client.play(videoId, signal);
    const model = typeof data?.video_model === 'string' ? JSON.parse(data.video_model) : null;
    if (!model || typeof model !== 'object') throw new Error('Invalid video model');
    const selected = await selectMedia(model);
    let media;
    for (const url of selected.urls) {
      try {
        const parsed = new URL(url);
        if (parsed.protocol !== 'https:') continue;
        media = await openMedia(url, selected.key, {signal});
        break;
      } catch {
        signal.throwIfAborted();
        /* The model supplies backup CDN URLs. */
      }
    }
    if (!media) throw new Error('Media unavailable');
    const expiry = Math.min(Date.now() + MAX_TTL, ...[data.expire_time, selected.expiresAt]
      .map(Number).filter(n => Number.isFinite(n) && n > 0).map(n => n * 1000 - 5000));
    if (expiry > Date.now()) {
      while (cache.size >= MAX_ENTRIES) cache.delete(cache.keys().next().value);
      cache.set(videoId, {media, expires:expiry});
    }
    return media;
}

export async function play(request, videoId, client, cache = prepared) {
  if (!['GET', 'HEAD'].includes(request.method)) return new Response(null, {status:405, headers:{Allow:'GET, HEAD'}});
  try {
    return mediaResponse(request, await prepare(videoId, client, cache instanceof Map ? cache : prepared));
  } catch (error) {
    const timeout = ['TimeoutError', 'AbortError'].includes(error?.name);
    const code = timeout ? 'MEDIA_TIMEOUT' : error instanceof ApiError ? error.code : 'MEDIA_UNAVAILABLE';
    console.error('HG_MEDIA', {event:'prepare.failed', code});
    return Response.json({error:{code,message:timeout?'影片准备超时，请重试':error instanceof ApiError?error.message:'影片暂时无法准备，请重试'}}, {status:502, headers:{'Cache-Control':'no-store'}});
  }
}

// Schedule the adjacent episode's preparation after a successful stream
// response. Runs only when a directory context supplied the neighbour id;
// reuses the very client (device identity) that served the current episode,
// adds exactly one upstream call shaped like a real player start, and never
// throws into the response path.
export function prefetchNext(videoId, nextVideoId, client, cache = prepared, waitUntil = null) {
  // Detached fetches can be cancelled when the foreground request finishes.
  if (!PREFETCH_ENABLED || typeof waitUntil !== 'function') return;
  const next = String(nextVideoId || '');
  if (!/^\d{10,24}$/.test(next) || next === String(videoId)) return;
  if (!cache.has(next)) {
    const job = prepare(next, client, cache instanceof Map ? cache : prepared)
      .catch(() => {});
    if (waitUntil) waitUntil(job);
  }
}
