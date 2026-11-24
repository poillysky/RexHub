// Service worker for offline shell only — never cache API / media
const CACHE_NAME = 'app-v5';
// 安装时预缓存离线外壳与图标；页面 JS/CSS 带 hash，首次访问时再按需缓存
const PRECACHE_URLS = [
  '/',
  '/manifest.json',
  '/icon-192.png',
  '/icon-512.png',
  '/apple-touch-icon.png',
];
// 缓存条目上限：超出后按插入顺序淘汰最旧的，避免长期使用无限膨胀
const MAX_ENTRIES = 120;

// 只缓存成功的同源响应；重定向后的 404/500 不能写进缓存
async function cachePut(request, response) {
  if (!response || !response.ok) return;
  try {
    const cache = await caches.open(CACHE_NAME);
    await cache.put(request, response.clone());
    await trimCache(cache);
  } catch {
    // 206/不可缓存响应会 reject，忽略即可
  }
}

async function trimCache(cache) {
  const keys = await cache.keys();
  if (keys.length <= MAX_ENTRIES) return;
  const overflow = keys.slice(0, keys.length - MAX_ENTRIES);
  await Promise.all(overflow.map((key) => cache.delete(key)));
}

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches
      .open(CACHE_NAME)
      .then((cache) =>
        Promise.all(
          PRECACHE_URLS.map((url) => cache.add(url).catch(() => {}))
        )
      )
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) => {
      return Promise.all(
        keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))
      );
    })
  );
  self.clients.claim();
});

function shouldBypassCache(url) {
  try {
    const u = new URL(url);
    const p = u.pathname || '';
    // API / 封面 / 代理图：始终走网络，避免 iOS PWA 钉死旧 poster
    if (p.startsWith('/api/')) return true;
    if (p.includes('/cover-proxy')) return true;
  } catch {
    /* ignore */
  }
  return false;
}

self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;
  if (!event.request.url.startsWith(self.location.origin)) return;
  if (shouldBypassCache(event.request.url)) return;

  // Navigation: network-first, fall back to cache
  if (event.request.mode === 'navigate') {
    event.respondWith(
      fetch(event.request)
        .then((response) => {
          void cachePut(event.request, response);
          return response;
        })
        .catch(() => caches.match(event.request).then((c) => c || caches.match('/')))
    );
    return;
  }

  // Static assets: stale-while-revalidate
  event.respondWith(
    caches.match(event.request).then((cached) => {
      const fetchPromise = fetch(event.request).then((response) => {
        void cachePut(event.request, response);
        return response;
      });
      return cached || fetchPromise;
    })
  );
});
