/**
 * RexHub Plugin Framework — ForwardWidgets 兼容 JS Runtime Host
 *
 * 一个插件一个进程：加载单个 JS 文件，在隔离 VM Context 中执行，
 * 注入 Widget 全局对象（http/tmdb/html/dom/storage/sharedCache），
 * 对外暴露 JSON HTTP 接口供 Python Dispatcher 调用。
 *
 * 就绪后 stdout 输出：REXHUB_MODULE_READY {"port":...}
 */

import { createServer } from 'node:http';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { lookup } from 'node:dns/promises';
import vm from 'node:vm';
import process from 'node:process';
import { parse as acornParse } from 'acorn';
import * as cheerio from 'cheerio';
import AdmZip from 'adm-zip';
import { ProxyAgent, fetch as undiciFetch } from 'undici';

const PLUGIN_ID = process.env.REXHUB_PLUGIN_ID || 'plugin';
const PLUGIN_FILE = process.env.REXHUB_PLUGIN_FILE || '';
const PORT = Number(process.env.REXHUB_PLUGIN_PORT || 0);
const HOST = process.env.REXHUB_PLUGIN_HOST || '0.0.0.0';
const DATA_DIR = process.env.REXHUB_PLUGIN_DATA_DIR || '';
const SHARED_CACHE_FILE =
  process.env.REXHUB_PLUGIN_SHARED_CACHE ||
  (DATA_DIR ? join(dirname(DATA_DIR), '_shared_cache.json') : '');
const TMDB_KEY = process.env.REXHUB_TMDB_API_KEY || '';
const PROXY_URL = String(process.env.REXHUB_PLUGIN_PROXY || '').trim();
let proxyDispatcher = null;
if (/^https?:\/\//i.test(PROXY_URL)) {
  try {
    proxyDispatcher = new ProxyAgent(PROXY_URL);
    logLine('INFO', `出站代理已启用：${PROXY_URL}`);
  } catch (error) {
    logLine('WARN', `出站代理初始化失败：${error?.message || error}`);
  }
}
let CONFIG = {};
try {
  CONFIG = JSON.parse(process.env.REXHUB_PLUGIN_ENV || '{}');
} catch {
  CONFIG = {};
}
let PERMISSIONS = [];
try {
  PERMISSIONS = JSON.parse(process.env.REXHUB_PLUGIN_PERMISSIONS || '[]');
} catch {
  PERMISSIONS = [];
}
const ALLOWED = new Set(
  Array.isArray(PERMISSIONS) && PERMISSIONS.length
    ? PERMISSIONS
    : ['network', 'storage', 'shared-cache'],
);

function requirePermission(name) {
  if (!ALLOWED.has(name)) {
    throw Object.assign(new Error(`插件未声明权限：${name}`), {
      code: 'PERMISSION_DENIED',
    });
  }
}

const HTTP_TIMEOUT = 15_000;
const MAX_BODY = 8 * 1024 * 1024;
const HANDLER_TIMEOUT = 20_000;
const DETAIL_TIMEOUT = 20_000;
const PLAYBACK_TIMEOUT = 30_000;
const SUBTITLE_TIMEOUT = 30_000;
const MAX_CONCURRENCY = 3;

function logLine(...args) {
  process.stdout.write(
    `[${PLUGIN_ID}] ${args
      .map((item) => (typeof item === 'string' ? item : safeString(item)))
      .join(' ')}\n`,
  );
}

function safeString(value) {
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

// 插件内 console 统一进入日志管道
const pluginConsole = {};
for (const method of ['log', 'info', 'warn', 'error', 'debug']) {
  pluginConsole[method] = (...args) => logLine(method.toUpperCase(), ...args);
}

function ready(port) {
  process.stdout.write(`REXHUB_MODULE_READY ${JSON.stringify({ port })}\n`);
}

// ---------------------------------------------------------------------------
// 网络与安全
// ---------------------------------------------------------------------------

const PRIVATE_HOST_RE =
  /^(localhost|0\.|10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/i;

function isPrivateHost(rawHost) {
  const host = String(rawHost || '').toLowerCase().replace(/^\[|\]$/g, '');
  if (!host) return true;
  if (PRIVATE_HOST_RE.test(host)) return true;
  if (host === '::1' || host === '::' || host.startsWith('fc') || host.startsWith('fd')) {
    return true;
  }
  if (host.startsWith('fe8') || host.startsWith('fe9') || host.startsWith('fea') || host.startsWith('feb')) {
    return true;
  }
  if (host.startsWith('::ffff:')) {
    const rest = host.slice('::ffff:'.length);
    if (rest.includes('.')) return isPrivateHost(rest);
    const parts = rest.split(':');
    if (parts.length === 2) {
      const hi = Number.parseInt(parts[0], 16);
      const lo = Number.parseInt(parts[1], 16);
      if (Number.isFinite(hi) && Number.isFinite(lo)) {
        const ipv4 = [
          (hi >> 8) & 0xff,
          hi & 0xff,
          (lo >> 8) & 0xff,
          lo & 0xff,
        ].join('.');
        return isPrivateHost(ipv4);
      }
    }
    return true;
  }
  return false;
}

function assertPublicUrl(raw) {
  let parsed;
  try {
    parsed = new URL(String(raw));
  } catch {
    throw new Error('URL 不合法');
  }
  if (!['http:', 'https:'].includes(parsed.protocol)) {
    throw new Error('仅允许 http/https 请求');
  }
  if (parsed.username || parsed.password) {
    throw new Error('URL 不允许携带账号密码');
  }
  if (isPrivateHost(parsed.hostname)) {
    throw new Error('不允许访问内网地址');
  }
  return parsed;
}

async function safeFetch(rawUrl, init, allowRedirects = true) {
  let current = new URL(String(rawUrl));
  let requestInit = init;
  for (let hop = 0; hop <= 5; hop += 1) {
    assertPublicUrl(current.toString());
    await assertResolvedPublic(current);
    const requestOptions = { ...requestInit, redirect: 'manual' };
    if (proxyDispatcher) requestOptions.dispatcher = proxyDispatcher;
    const response = proxyDispatcher
      ? await undiciFetch(current, requestOptions)
      : await fetch(current, requestOptions);
    if (!allowRedirects || ![301, 302, 303, 307, 308].includes(response.status)) {
      return response;
    }
    const location = response.headers.get('location');
    if (!location) return response;
    current = new URL(location, current);
    if ([301, 302, 303].includes(response.status)) {
      requestInit = { ...requestInit, method: 'GET', body: undefined };
    }
    if (hop === 5) throw new Error('重定向次数过多');
  }
  throw new Error('重定向次数过多');
}

async function assertResolvedPublic(parsed) {
  const host = String(parsed.hostname || '').replace(/^\[|\]$/g, '');
  if (!host) throw new Error('URL 主机为空');
  try {
    const records = await lookup(host, { all: true });
    const list = Array.isArray(records) ? records : [records];
    for (const record of list) {
      if (isPrivateHost(record.address)) throw new Error('不允许访问内网地址');
    }
  } catch (error) {
    if (String(error?.message || '').includes('内网')) throw error;
    // DNS 失败交给 fetch 报错
  }
}

async function fetchLimited(url, options = {}) {
  const parsed = assertPublicUrl(url);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), options.timeout || HTTP_TIMEOUT);
  try {
    const response = await safeFetch(
      parsed,
      {
        method: options.method || 'GET',
        headers: options.headers || {},
        body: options.body,
        signal: controller.signal,
      },
      options.allowRedirects !== false,
    );
    const headers = {};
    response.headers.forEach((value, key) => {
      headers[key] = value;
    });
    const chunks = [];
    let size = 0;
    if (response.body) {
      for await (const chunk of response.body) {
        size += chunk.length;
        if (size > MAX_BODY) throw new Error('响应内容超过大小限制');
        chunks.push(chunk);
      }
    }
    const raw = Buffer.concat(chunks);
    const text = raw.toString('utf8');
    let data = text;
    const contentType = headers['content-type'] || '';
    if (contentType.includes('json')) {
      try {
        data = JSON.parse(text);
      } catch {
        data = text;
      }
    } else {
      try {
        data = JSON.parse(text);
      } catch {
        data = text;
      }
    }
    return { data, status: response.status, headers };
  } catch (error) {
    if (error?.name === 'AbortError') throw new Error('请求超时');
    throw new Error(`请求失败：${error?.message || error}`);
  } finally {
    clearTimeout(timer);
  }
}

async function fetchRaw(url) {
  const parsed = assertPublicUrl(url);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), HTTP_TIMEOUT);
  try {
    const response = await safeFetch(parsed, { signal: controller.signal }, true);
    const chunks = [];
    let size = 0;
    if (response.body) {
      for await (const chunk of response.body) {
        size += chunk.length;
        if (size > 50 * 1024 * 1024) throw new Error('字幕压缩包超过大小限制');
        chunks.push(chunk);
      }
    }
    return Buffer.concat(chunks);
  } catch (error) {
    if (error?.name === 'AbortError') throw new Error('字幕下载超时');
    throw new Error(`字幕下载失败：${error?.message || error}`);
  } finally {
    clearTimeout(timer);
  }
}

function withQuery(url, params) {
  if (!params || typeof params !== 'object') return url;
  const parsed = new URL(url);
  for (const [key, value] of Object.entries(params)) {
    if (value === undefined || value === null) continue;
    if (Array.isArray(value)) {
      value.forEach((item) => parsed.searchParams.append(key, String(item)));
    } else {
      parsed.searchParams.set(key, String(value));
    }
  }
  return parsed.toString();
}

// ---------------------------------------------------------------------------
// Widget.storage / Widget.sharedCache（文件持久化）
// ---------------------------------------------------------------------------

function loadJson(path, fallback) {
  try {
    if (!path || !existsSync(path)) return fallback;
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    return fallback;
  }
}

function saveJson(path, value) {
  if (!path) return;
  try {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, JSON.stringify(value), 'utf8');
  } catch (error) {
    logLine('WARN', '存储写入失败', String(error?.message || error));
  }
}

const storagePath = DATA_DIR ? join(DATA_DIR, 'storage.json') : '';
const storage = loadJson(storagePath, {});
const sharedCachePath = SHARED_CACHE_FILE;
const sharedCache = loadJson(sharedCachePath, {});
const MAX_STORAGE_VALUE = 256 * 1024;
const MAX_STORAGE_TOTAL = 8 * 1024 * 1024;

function boundedValue(value) {
  if (safeString(value).length > MAX_STORAGE_VALUE) {
    throw new Error('插件存储值超过 256KB 限制');
  }
}

function saveBounded(path, data, revert) {
  try {
    if (JSON.stringify(data).length > MAX_STORAGE_TOTAL) {
      revert();
      throw new Error('插件存储总量超过 8MB 限制');
    }
    saveJson(path, data);
  } catch (error) {
    revert();
    throw error;
  }
}

function storageApi() {
  return {
    get(key) {
      requirePermission('storage');
      return storage[String(key)];
    },
    set(key, value) {
      requirePermission('storage');
      boundedValue(value);
      const previous = storage[String(key)];
      const existed = Object.prototype.hasOwnProperty.call(storage, String(key));
      storage[String(key)] = value;
      saveBounded(storagePath, storage, () => {
        if (existed) storage[String(key)] = previous;
        else delete storage[String(key)];
      });
    },
    remove(key) {
      requirePermission('storage');
      delete storage[String(key)];
      saveJson(storagePath, storage);
    },
  };
}

function sharedCacheApi() {
  return {
    get(namespace, key) {
      requirePermission('shared-cache');
      return (sharedCache[String(namespace)] || {})[String(key)];
    },
    set(namespace, key, value) {
      requirePermission('shared-cache');
      boundedValue(value);
      const ns = String(namespace);
      const previous = sharedCache[ns] ? sharedCache[ns][String(key)] : undefined;
      const existed = Boolean(sharedCache[ns] && Object.prototype.hasOwnProperty.call(sharedCache[ns], String(key)));
      if (!sharedCache[ns]) sharedCache[ns] = {};
      sharedCache[ns][String(key)] = value;
      saveBounded(sharedCachePath, sharedCache, () => {
        if (existed) sharedCache[ns][String(key)] = previous;
        else delete sharedCache[ns][String(key)];
      });
    },
    remove(namespace, key) {
      requirePermission('shared-cache');
      const ns = String(namespace);
      if (sharedCache[ns]) {
        delete sharedCache[ns][String(key)];
        saveJson(sharedCachePath, sharedCache);
      }
    },
  };
}

// ---------------------------------------------------------------------------
// Widget.html / Widget.dom
// ---------------------------------------------------------------------------

const domDocs = new Map();
let domSeq = 0;

function htmlApi() {
  return {
    load(html) {
      return cheerio.load(String(html ?? ''));
    },
  };
}

function domApi() {
  return {
    parse(html) {
      const id = `doc-${++domSeq}`;
      domDocs.set(id, cheerio.load(String(html ?? '')));
      return id;
    },
    select(docId, selector) {
      const doc = domDocs.get(String(docId));
      if (!doc) return [];
      return doc(selector);
    },
  };
}

// ---------------------------------------------------------------------------
// Widget.http / Widget.tmdb
// ---------------------------------------------------------------------------

function httpApi() {
  async function request(method, url, body, options = {}) {
    requirePermission('network');
    const target = withQuery(String(url), options.params);
    const headers = { ...(options.headers || {}) };
    let payload;
    if (body !== undefined && body !== null) {
      if (typeof body === 'string') {
        payload = body;
      } else {
        payload = JSON.stringify(body);
        if (!Object.keys(headers).some((key) => key.toLowerCase() === 'content-type')) {
          headers['content-type'] = 'application/json';
        }
      }
    }
    return fetchLimited(target, {
      method,
      headers,
      body: payload,
      allowRedirects: options.allow_redirects !== false,
      timeout: HTTP_TIMEOUT,
    });
  }
  return {
    get: (url, options) => request('GET', url, undefined, options),
    post: (url, body, options) => request('POST', url, body, options),
    put: (url, body, options) => request('PUT', url, body, options),
    delete: (url, options) => request('DELETE', url, undefined, options),
  };
}

function tmdbApi() {
  return {
    async get(apiPath, options = {}) {
      requirePermission('network');
      if (!TMDB_KEY) throw new Error('未配置 TMDB API Key');
      const path = String(apiPath || '').replace(/^\/+/, '');
      if (!path) throw new Error('TMDB 路径不能为空');
      const url = withQuery(`https://api.themoviedb.org/3/${path}`, {
        ...(options.params || {}),
        api_key: TMDB_KEY,
        language: (options.params && options.params.language) || 'zh-CN',
      });
      const result = await fetchLimited(url, { timeout: HTTP_TIMEOUT });
      return result.data;
    },
  };
}

// ---------------------------------------------------------------------------
// VM Context
// ---------------------------------------------------------------------------

if (!PLUGIN_FILE) {
  logLine('FATAL', '缺少 REXHUB_PLUGIN_FILE');
  process.exit(1);
}
let source = readFileSync(PLUGIN_FILE, 'utf8');
if (source.startsWith('FWENC1')) {
  logLine('FATAL', '暂不支持 FWENC1 加密插件，请使用明文 JS');
  process.exit(1);
}
try {
  acornParse(source, { ecmaVersion: 'latest', allowAwaitOutsideFunction: true });
} catch (error) {
  logLine('FATAL', 'JS 语法错误', String(error?.message || error));
  process.exit(1);
}

const sandbox = {
  console: pluginConsole,
  Widget: {
    http: httpApi(),
    tmdb: tmdbApi(),
    html: htmlApi(),
    dom: domApi(),
    storage: storageApi(),
    sharedCache: sharedCacheApi(),
  },
  setTimeout,
  clearTimeout,
  setInterval,
  clearInterval,
  URL,
  URLSearchParams,
  TextEncoder,
  TextDecoder,
  AbortController,
  Promise,
  JSON,
  Math,
  Date,
  RegExp,
  Object,
  Array,
  String,
  Number,
  Boolean,
  parseInt,
  parseFloat,
  isNaN,
  encodeURIComponent,
  decodeURIComponent,
  encodeURI,
  decodeURI,
};
sandbox.globalThis = sandbox;
const context = vm.createContext(sandbox);
try {
  vm.runInContext(source, context, { timeout: 5000, filename: PLUGIN_FILE });
} catch (error) {
  logLine('FATAL', '插件加载失败', String(error?.stack || error));
  process.exit(1);
}

const metadata = sandbox.WidgetMetadata || context.WidgetMetadata;
if (!metadata || typeof metadata !== 'object') {
  logLine('FATAL', '未找到 WidgetMetadata');
  process.exit(1);
}
if (String(metadata.id || '') !== PLUGIN_ID) {
  logLine('WARN', `WidgetMetadata.id=${metadata.id} 与插件 ID ${PLUGIN_ID} 不一致`);
}

const modules = Array.isArray(metadata.modules) ? metadata.modules : [];
const moduleById = new Map();
for (const item of modules) {
  if (item && item.id) moduleById.set(String(item.id), item);
}

function metadataInfo() {
  return {
    id: String(metadata.id || PLUGIN_ID),
    title: String(metadata.title || PLUGIN_ID),
    version: String(metadata.version || ''),
    description: String(metadata.description || ''),
    author: String(metadata.author || ''),
    site: String(metadata.site || ''),
    icon: String(metadata.icon || ''),
    detailCacheDuration: Number(metadata.detailCacheDuration || 0),
    globalParams: Array.isArray(metadata.globalParams) ? metadata.globalParams : [],
    modules: modules.map((item) => ({
      id: String(item.id || ''),
      title: String(item.title || ''),
      functionName: String(item.functionName || item.id || ''),
      type: String(item.type || ''),
      cacheDuration: Number(item.cacheDuration || 0),
      requiresWebView: Boolean(item.requiresWebView),
      params: Array.isArray(item.params) ? item.params : [],
    })),
    search: metadata.search && typeof metadata.search === 'object' ? {
      title: String(metadata.search.title || '搜索'),
      functionName: String(metadata.search.functionName || 'search'),
      params: Array.isArray(metadata.search.params) ? metadata.search.params : [],
    } : null,
  };
}

function defaultsOf(metadataRow) {
  const out = {};
  const globalParams = Array.isArray(metadataRow.globalParams) ? metadataRow.globalParams : [];
  for (const param of globalParams) {
    if (param && param.name && param.value !== undefined) out[String(param.name)] = param.value;
  }
  for (const param of Array.isArray(metadataRow.modules) ? metadataRow.modules : []) {
    for (const entry of Array.isArray(param.params) ? param.params : []) {
      if (entry && entry.name && entry.value !== undefined && out[String(entry.name)] === undefined) {
        out[String(entry.name)] = entry.value;
      }
    }
  }
  return out;
}

const moduleDefaults = defaultsOf(metadata);

function resolveFunction(name) {
  const fn = context[name];
  if (typeof fn !== 'function') {
    throw new Error(`未找到处理函数 ${name}`);
  }
  return fn;
}

const cache = new Map();
const CACHE_LIMIT = 500;
function cacheKey(scope, params) {
  return `${scope}:${safeString(params)}`;
}
function cacheSet(key, value, expires) {
  if (cache.size >= CACHE_LIMIT) {
    const oldest = cache.keys().next().value;
    if (oldest !== undefined) cache.delete(oldest);
  }
  cache.set(key, { value, expires });
}
function cachedValue(key, duration, loader) {
  if (!duration || duration <= 0) {
    return Promise.resolve(loader()).then((value) => ({ value, cached: false }));
  }
  const hit = cache.get(key);
  const now = Date.now();
  if (hit && hit.expires > now) return Promise.resolve({ value: hit.value, cached: true });
  return Promise.resolve(loader()).then((value) => {
    cacheSet(key, value, now + Math.min(duration, 86400) * 1000);
    return { value, cached: false };
  });
}

async function withTimeout(promise, ms) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('插件执行超时')), ms);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

let running = 0;
const waiters = [];
const MAX_WAITERS = 32;
async function withConcurrency(fn) {
  if (running >= MAX_CONCURRENCY) {
    if (waiters.length >= MAX_WAITERS) {
      throw Object.assign(new Error('插件并发请求过多，请稍后重试'), {
        code: 'PLUGIN_BUSY',
      });
    }
    await new Promise((resolve) => waiters.push(resolve));
  }
  running += 1;
  try {
    return await fn();
  } finally {
    running -= 1;
    const next = waiters.shift();
    if (next) next();
  }
}

function mergeParams(params, module) {
  const merged = { ...moduleDefaults };
  if (module && Array.isArray(module.params)) {
    for (const item of module.params) {
      if (item && item.name && item.value !== undefined && merged[String(item.name)] === undefined) {
        merged[String(item.name)] = item.value;
      }
    }
  }
  return { ...merged, ...(params || {}) };
}

async function executeModule(moduleId, params) {
  const module = moduleById.get(String(moduleId));
  if (!module) throw Object.assign(new Error('模块不存在'), { code: 'MODULE_NOT_FOUND' });
  if (module.requiresWebView) {
    throw Object.assign(
      new Error('该模块需要 WebView 环境，NAS 暂不支持'),
      { code: 'PERMISSION_DENIED' },
    );
  }
  const functionName = String(module.functionName || module.id || '');
  const merged = mergeParams(params, module);
  const key = cacheKey(`module:${module.id}`, merged);
  const duration = Number(module.cacheDuration || 0);
  return withConcurrency(async () => {
    const result = await cachedValue(key, duration, () =>
      withTimeout(Promise.resolve(resolveFunction(functionName)(merged)), HANDLER_TIMEOUT),
    );
    return { data: result.value, cached: result.cached, moduleId: String(moduleId) };
  });
}

async function executeDetail(link) {
  const key = cacheKey('detail', { link });
  const duration = Number(metadata.detailCacheDuration || 0);
  return withConcurrency(async () => {
    const result = await cachedValue(key, duration, () =>
      withTimeout(Promise.resolve(resolveFunction('loadDetail')(link)), DETAIL_TIMEOUT),
    );
    return { data: result.value, cached: result.cached, moduleId: 'loadDetail' };
  });
}

async function executeSearch(params) {
  const block = metadata.search && typeof metadata.search === 'object' ? metadata.search : null;
  if (!block) throw Object.assign(new Error('插件未声明搜索'), { code: 'MODULE_NOT_FOUND' });
  const functionName = String(block.functionName || 'search');
  const merged = mergeParams(params, { params: block.params || [] });
  return withConcurrency(async () => {
    const result = await withTimeout(
      Promise.resolve(resolveFunction(functionName)(merged)),
      HANDLER_TIMEOUT,
    );
    return { data: result, cached: false, moduleId: functionName };
  });
}

async function executeFixed(moduleId, params, timeout = HANDLER_TIMEOUT) {
  if (!moduleById.has(moduleId)) {
    throw Object.assign(new Error(`模块 ${moduleId} 不存在`), { code: 'MODULE_NOT_FOUND' });
  }
  const module = moduleById.get(moduleId);
  if (module.requiresWebView) {
    throw Object.assign(
      new Error('该模块需要 WebView 环境，NAS 暂不支持'),
      { code: 'PERMISSION_DENIED' },
    );
  }
  const functionName = String(module.functionName || moduleId);
  const merged = mergeParams(params, module);
  return withConcurrency(async () => {
    const result = await withTimeout(
      Promise.resolve(resolveFunction(functionName)(merged)), timeout,
    );
    return { data: result, cached: false, moduleId };
  });
}

const SUBTITLE_EXTENSIONS = new Set(['srt', 'ass', 'ssa', 'vtt', 'sub', 'txt']);

function archiveFiles(buffer) {
  const zip = new AdmZip(buffer);
  const files = [];
  let totalSize = 0;
  for (const entry of zip.getEntries()) {
    if (entry.isDirectory) continue;
    if (files.length >= 5000) throw new Error('字幕压缩包文件数量过多');
    const rawName = String(entry.entryName || '').replace(/\\/g, '/');
    if (!rawName || rawName.startsWith('/') || rawName.split('/').includes('..')) continue;
    const name = rawName.split('/').pop() || rawName;
    const extension = (name.split('.').pop() || '').toLowerCase();
    const size = Number(entry.header?.size || 0);
    totalSize += size;
    if (totalSize > 200 * 1024 * 1024) throw new Error('字幕压缩包解压后超过大小限制');
    files.push({
      path: rawName,
      name,
      extension,
      size,
    });
  }
  return files;
}

async function executeArchive(params) {
  const input = params || {};
  if (input.url) {
    const raw = await fetchRaw(String(input.url));
    if (raw.subarray(0, 2).toString() === 'PK') {
      const files = archiveFiles(raw);
      const subtitleFiles = files.filter((item) => SUBTITLE_EXTENSIONS.has(item.extension));
      const merged = {
        ...input,
        archiveName: String(input.archiveName || 'subtitle.zip'),
        archiveUrl: String(input.url),
        files: JSON.stringify(files),
        subtitleFiles: JSON.stringify(subtitleFiles),
      };
      let selected = null;
      if (typeof context.resolveSubtitleArchive === 'function') {
        selected = await withConcurrency(() =>
          withTimeout(Promise.resolve(context.resolveSubtitleArchive(merged)), SUBTITLE_TIMEOUT),
        );
      }
      if (typeof selected === 'object' && selected) {
        selected = selected.path || (Array.isArray(selected.files) ? selected.files[0] : null);
      }
      if (Array.isArray(selected)) selected = selected[0] || null;
      if (selected && !files.some((item) => item.path === selected)) selected = null;
      return {
        data: {
          archive: true,
          archiveName: merged.archiveName,
          selected: selected || subtitleFiles[0]?.path || null,
          files,
          subtitleFiles,
        },
        cached: false,
        moduleId: 'resolveSubtitleArchive',
      };
    }
    return {
      data: { archive: false, url: String(input.url) },
      cached: false,
      moduleId: 'resolveSubtitleArchive',
    };
  }
  if (typeof context.resolveSubtitleArchive !== 'function') {
    return { data: null, cached: false, moduleId: 'resolveSubtitleArchive' };
  }
  return withConcurrency(async () => {
    const result = await withTimeout(
      Promise.resolve(context.resolveSubtitleArchive(input)),
      SUBTITLE_TIMEOUT,
    );
    return { data: result, cached: false, moduleId: 'resolveSubtitleArchive' };
  });
}

// ---------------------------------------------------------------------------
// HTTP 服务
// ---------------------------------------------------------------------------

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > 4 * 1024 * 1024) {
        reject(new Error('请求体过大'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      const text = Buffer.concat(chunks).toString('utf8');
      if (!text) return resolve({});
      try {
        resolve(JSON.parse(text));
      } catch {
        reject(new Error('请求体不是合法 JSON'));
      }
    });
    req.on('error', reject);
  });
}

function json(res, status, payload) {
  const body = Buffer.from(JSON.stringify(payload));
  res.statusCode = status;
  res.setHeader('content-type', 'application/json; charset=utf-8');
  res.setHeader('content-length', body.length);
  res.end(body);
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url || '/', `http://127.0.0.1:${PORT}`);
  try {
    if (req.method === 'GET' && (url.pathname === '/health' || url.pathname === '/')) {
      return json(res, 200, {
        ok: true,
        id: metadataInfo().id,
        version: metadataInfo().version,
        modules: metadataInfo().modules.length,
      });
    }
    if (req.method === 'GET' && url.pathname === '/metadata') {
      return json(res, 200, { ok: true, data: metadataInfo() });
    }
    if (req.method === 'POST') {
      const body = await readBody(req);
      const started = Date.now();
      let outcome;
      switch (url.pathname) {
        case '/execute':
          outcome = await executeModule(body.moduleId || body.module || '', body.params || {});
          break;
        case '/detail':
          outcome = await executeDetail(String(body.link ?? ''));
          break;
        case '/search':
          outcome = await executeSearch(body.params || body);
          break;
        case '/resource':
          outcome = await executeFixed('loadResource', body.params || body, PLAYBACK_TIMEOUT);
          break;
        case '/subtitle':
          outcome = await executeFixed('loadSubtitle', body.params || body, SUBTITLE_TIMEOUT);
          break;
        case '/subtitle/archive':
          outcome = await executeArchive(body.params || body);
          break;
        case '/danmu/search':
          outcome = await executeFixed('searchDanmu', body.params || body, HANDLER_TIMEOUT);
          break;
        case '/danmu/detail':
          outcome = await executeFixed('getDetail', body.params || body, HANDLER_TIMEOUT);
          break;
        case '/danmu/comments':
          outcome = await executeFixed('getComments', body.params || body, HANDLER_TIMEOUT);
          break;
        case '/danmu/segment':
          outcome = await executeFixed('getDanmuWithSegmentTime', body.params || body, HANDLER_TIMEOUT);
          break;
        default:
          return json(res, 404, {
            ok: false,
            error: { code: 'NOT_FOUND', message: '接口不存在' },
          });
      }
      return json(res, 200, {
        ok: true,
        ...outcome,
        executionTime: Date.now() - started,
      });
    }
    return json(res, 405, {
      ok: false,
      error: { code: 'METHOD_NOT_ALLOWED', message: '方法不支持' },
    });
  } catch (error) {
    const code = error?.code || (/超时/.test(String(error?.message)) ? 'PLUGIN_TIMEOUT' : 'PLUGIN_RUNTIME_ERROR');
    return json(res, 502, {
      ok: false,
      error: { code, message: String(error?.message || error) },
    });
  }
});

server.listen(PORT, HOST, () => {
  const bound = server.address();
  const actual = typeof bound === 'object' && bound ? bound.port : PORT;
  logLine('Widget 运行时已启动', `http://${HOST}:${actual}`, metadataInfo().title);
  ready(actual);
});

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    logLine('收到退出信号', signal);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 3000).unref();
  });
}
