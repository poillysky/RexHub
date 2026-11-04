/**
 * RexHub 明文插件执行器（Bun）
 *
 * 从 stdin 读取 {source, functionName, params}，用 new Function 载入
 * ForwardWidget 插件源码并调用目标函数，结果以 JSON 写到 stdout。
 * stdout 只允许出现结果 JSON，日志统一走 stderr。
 */

const DEFAULT_TIMEOUT = 15000;
let PROXY = "";

function logLine(...args) {
  try {
    const text = args
      .map((item) => (typeof item === "string" ? item : JSON.stringify(item)))
      .join(" ");
    process.stderr.write(text + "\n");
  } catch {
    process.stderr.write("[plugin] 日志无法序列化\n");
  }
}

for (const name of ["log", "info", "warn", "error", "debug"]) {
  console[name] = logLine;
}

async function emit(payload, code) {
  let text;
  try {
    text = JSON.stringify(payload);
  } catch (error) {
    text = JSON.stringify({ ok: false, error: `插件返回值无法序列化：${error && error.message}` });
  }
  // 大结果可能超过管道缓冲区，等写入完成再退出，避免 stdout 被截断
  await Bun.write(Bun.stdout, text);
  process.exit(code);
}

function timeoutOf(options) {
  const value = Number(options && options.timeout);
  return Number.isFinite(value) && value > 0 ? value : DEFAULT_TIMEOUT;
}

async function httpRequest(options) {
  const opts = typeof options === "string" ? { url: options } : options || {};
  const url = String(opts.url || opts.href || "").trim();
  if (!/^https?:\/\//i.test(url)) throw new Error("仅支持 http(s) 地址");

  const method = String(opts.method || "GET").toUpperCase();
  const headers = {};
  if (opts.headers && typeof opts.headers === "object") {
    for (const [key, value] of Object.entries(opts.headers)) {
      if (value !== undefined && value !== null) headers[key] = String(value);
    }
  }

  let body = opts.body !== undefined ? opts.body : opts.data;
  if (body !== undefined && body !== null && typeof body !== "string") {
    body = JSON.stringify(body);
    if (!Object.keys(headers).some((key) => key.toLowerCase() === "content-type")) {
      headers["Content-Type"] = "application/json";
    }
  }
  if (!Object.keys(headers).some((key) => key.toLowerCase() === "user-agent")) {
    headers["User-Agent"] = "RexHub-Plugin/1.0";
  }

  // 插件声明了代理时一并走代理：TMDB 等上游在部分网络下必须经代理访问
  const proxy = PROXY ? { proxy: PROXY } : {};
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutOf(opts));
  try {
    const response = await fetch(url, {
      method,
      headers,
      body: method === "GET" || method === "HEAD" ? undefined : body,
      signal: controller.signal,
      ...proxy,
    });
    const text = await response.text();
    let data = text;
    try {
      data = JSON.parse(text);
    } catch {
      data = text;
    }
    const responseHeaders = {};
    response.headers.forEach((value, key) => {
      responseHeaders[key] = value;
    });
    return { status: response.status, data, headers: responseHeaders };
  } catch (error) {
    if (error && error.name === "AbortError") throw new Error("上游请求超时");
    throw new Error(`网络请求失败：${(error && error.message) || error}`);
  } finally {
    clearTimeout(timer);
  }
}

const Widget = {
  http: {
    get: (url, options) => httpRequest({ ...(options || {}), url, method: "GET" }),
    post: (url, body, options) =>
      httpRequest({ ...(options || {}), url, body, method: "POST" }),
    request: (options) => httpRequest(options || {}),
  },
};

async function main() {
  const chunks = [];
  for await (const chunk of Bun.stdin.stream()) chunks.push(chunk);
  let payload;
  try {
    payload = JSON.parse(Buffer.concat(chunks).toString("utf-8") || "{}");
  } catch {
    await emit({ ok: false, error: "运行时参数不是合法 JSON" }, 1);
    return;
  }

  const source = String(payload.source || "");
  const functionName = String(payload.functionName || "");
  const params = payload.params && typeof payload.params === "object" ? payload.params : {};
  const proxy = String(payload.proxy || "").trim();
  PROXY = /^https?:\/\//i.test(proxy) ? proxy : "";

  if (!source.trim()) await emit({ ok: false, error: "插件源码为空" }, 1);
  if (!/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(functionName)) {
    await emit({ ok: false, error: "插件函数名无效" }, 1);
  }

  let factory;
  try {
    factory = new Function(
      "Widget",
      `${source}\n;return { WidgetMetadata, ${functionName} };`
    );
  } catch (error) {
    await emit({ ok: false, error: `插件加载失败：${(error && error.message) || error}` }, 1);
    return;
  }

  let exported;
  try {
    exported = factory(Widget);
  } catch (error) {
    await emit({ ok: false, error: `插件加载失败：${(error && error.message) || error}` }, 1);
    return;
  }

  if (typeof exported[functionName] !== "function") {
    await emit({ ok: false, error: `插件中没有函数 ${functionName}()` }, 1);
    return;
  }

  try {
    const result = await exported[functionName](params);
    await emit({ ok: true, result }, 0);
  } catch (error) {
    await emit({ ok: false, error: String((error && error.message) || error) }, 1);
  }
}

main().catch(async (error) => {
  await emit({ ok: false, error: String((error && error.message) || error) }, 1);
});
