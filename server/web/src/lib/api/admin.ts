/**
 * PWA 管理接口：NAS 服务卡片、115 网盘。
 *
 * 后端原 /admin HTML 管理台已移除，写操作改由这里调用 /api/admin/*（Web 会话 Cookie）。
 * 对外统一从 `@/lib/api` 导入。
 */
import { apiFetch, parseError } from './client';

async function json<T>(res: Promise<Response> | Response): Promise<T> {
  const r = await res;
  if (!r.ok) throw new Error(await parseError(r));
  return (await r.json()) as T;
}

function send(path: string, method: string, body?: unknown): Promise<Response> {
  return apiFetch(path, {
    method,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

// ---------- 115 网盘 ----------

/** 115 账号快照（头像 / 用户名 / VIP / 容量），Web 会话鉴权，Cookie 不出服务端。 */
export type Pan115Account = {
  bound: boolean;
  status: 'ok' | 'invalid' | 'pending' | 'unbound' | string;
  username: string;
  total: number | null;
  used: number | null;
  bound_at: number | null;
  checked_at: number | null;
  message: string;
  avatar: string;
  vip_active: boolean;
  vip_forever: boolean;
  vip_expire: string;
};

/** 账号详情：与 iOS 共用 /pan/account；115 未绑定时返回 null，不抛错。 */
export async function getPan115Snapshot(): Promise<Pan115Account | null> {
  const res = await apiFetch('/pan/account');
  if (!res.ok) return null;
  const data = (await res.json()) as (Pan115Account & { bound?: boolean }) | null;
  return data && data.bound !== false ? data : null;
}

// ---------- NAS 服务卡片 / 内容源 ----------

/** 服务条目：NAS 服务与内容源共用一套结构，靠 source_kind 区分。 */
export type ServiceItem = {
  id: string;
  name: string;
  category: string;
  categoryLabel?: string;
  section?: string;
  host: string;
  port: number;
  url: string;
  api_base?: string;
  source_kind?: string;
  enabled?: boolean;
  endpoints?: Record<string, unknown>;
  ui?: Record<string, unknown>;
  notes: string;
  updated_at?: number;
  online?: boolean | null;
  latency?: number | null;
};

export type ServiceListPayload = {
  items: ServiceItem[];
  categories: { key: string; label: string }[];
  sourceKinds: { key: string; label: string }[];
};

export type ServiceSaveBody = {
  id?: string;
  name: string;
  category?: string;
  section?: string;
  host?: string;
  port?: number;
  url?: string;
  api_base?: string;
  source_kind?: string;
  enabled?: boolean;
  notes?: string;
  username?: string;
  password?: string;
  database?: string;
  api_key?: string;
  endpoints?: Record<string, unknown>;
  ui?: Record<string, unknown>;
};

export async function getServices(): Promise<ServiceListPayload> {
  return json<ServiceListPayload>(apiFetch('/admin/services'));
}

export async function saveService(
  body: ServiceSaveBody,
): Promise<{ ok: boolean; id: string; created: boolean }> {
  return json(send('/admin/services', 'POST', body));
}

export async function deleteService(id: string): Promise<{ ok: boolean }> {
  return json(send(`/admin/services/${encodeURIComponent(id)}`, 'DELETE'));
}

/** 保存前试连：有主机端口走 socket，否则按 HTTP 地址探测。 */
export async function probeService(body: {
  host?: string;
  port?: number;
  api_base?: string;
  url?: string;
}): Promise<{ online: boolean; latency: number | null }> {
  return json(send('/admin/services/probe', 'POST', body));
}
