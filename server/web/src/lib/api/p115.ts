/**
 * 115 网盘（含任务清理、二维码登录）
 *
 * 由 lib/api.ts 拆分而来；对外统一从 `@/lib/api` 导入，请不要直接引用本文件。
 */
import { API_BASE, apiFetch, parseError } from './client';
import type { Envelope } from './client';
import type {
  AuthUser,
  BrowseResult,
  FilterSize,
  FilterTime,
  MatchMode,
  ResourceDbConfig,
  ResourceItem,
  SearchResult,
  SortType,
} from '@/types/resource';

/** 115 转存入口：搜索 / 影视 / 片商 */
export type P115SaveSource = 'search' | 'media' | 'maker';

/** 旧版配置里的入口键（读旧数据时兼容映射） */
export type P115LegacySaveSource =
  | 'warehouse'
  | 'movie'
  | 'tv'
  | 'makers'
  | 'japan_censored'
  | 'japan_uncensored'
  | 'japan_amateur'
  | 'fc2'
  | 'china'
  | 'western';

export type P115TargetFolder = {
  folderCid: string;
  folderName: string;
};

export type P115Config = {
  enabled: boolean;
  folderCid: string;
  folderName: string;
  label: string;
  targets?: Partial<
    Record<P115SaveSource | P115LegacySaveSource, P115TargetFolder>
  >;
  hasCookie: boolean;
  cookieHint: string;
  configured?: boolean;
  /** 仅在 /p115/status 返回：Cookie 是否仍然有效（false = 未登录/已失效） */
  authOk?: boolean;
  authError?: string;
  updated_at?: string;
  /** 云转存剩余任务数 */
  quota?: number | null;
  /** 云转存总额度 */
  quotaTotal?: number | null;
  quotaError?: string;
  spaceTotal?: number | null;
  spaceTotalText?: string | null;
  spaceUsed?: number | null;
  spaceUsedText?: string | null;
  spaceRemain?: number | null;
  spaceRemainText?: string | null;
  /** 离线单任务大小上限（字节） */
  offlineLimit?: number | null;
};

export type P115FolderItem = { cid: string; name: string };

export type P115FolderList = {
  path: P115FolderItem[];
  folders: P115FolderItem[];
};

export async function getP115(): Promise<P115Config> {
  const res = await apiFetch('/settings/p115');
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<P115Config>).data;
}

export async function getP115Status(): Promise<P115Config> {
  const res = await apiFetch('/settings/p115/status');
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<P115Config>).data;
}

export async function putP115(body: {
  cookie?: string;
  folderCid?: string;
  folderName?: string;
  label?: string;
  targets?: Partial<
    Record<P115SaveSource | P115LegacySaveSource, P115TargetFolder>
  >;
  validate?: boolean;
}): Promise<P115Config & { message?: string }> {
  const search = body.targets?.search;
  const res = await apiFetch('/settings/p115', {
    method: 'PUT',
    body: JSON.stringify({
      cookie: body.cookie,
      folderCid: body.folderCid ?? search?.folderCid ?? '0',
      folderName: body.folderName ?? search?.folderName ?? '',
      label: body.label ?? '',
      targets: body.targets,
      validate: body.validate ?? true,
      enabled: true,
    }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as Envelope<P115Config> & { message: string };
  return { ...json.data, message: json.message };
}

export async function listP115Folders(body: {
  cid?: string;
  cookie?: string;
}): Promise<P115FolderList> {
  const res = await apiFetch('/settings/p115/folders', {
    method: 'POST',
    body: JSON.stringify({
      cid: body.cid || '0',
      cookie: body.cookie,
    }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<P115FolderList>).data;
}

export async function validateP115(body: {
  cookie?: string;
  folderCid?: string;
}): Promise<{
  ok: boolean;
  message: string;
  folderName?: string;
  quota?: number | null;
  quotaTotal?: number | null;
  spaceTotalText?: string | null;
  spaceUsedText?: string | null;
  spaceRemainText?: string | null;
  spaceTotal?: number | null;
  spaceUsed?: number | null;
  spaceRemain?: number | null;
  offlineLimit?: number | null;
}> {
  const res = await apiFetch('/settings/p115/validate', {
    method: 'POST',
    body: JSON.stringify({
      cookie: body.cookie,
      folderCid: body.folderCid || '0',
    }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as Envelope<{
    ok?: boolean;
    folderName?: string;
    quota?: number | null;
    quotaTotal?: number | null;
    spaceTotalText?: string | null;
    spaceUsedText?: string | null;
    spaceRemainText?: string | null;
    spaceTotal?: number | null;
    spaceUsed?: number | null;
    spaceRemain?: number | null;
    offlineLimit?: number | null;
  }> & { message: string };
  return {
    ok: Boolean(json.data?.ok ?? true),
    message: json.message || '',
    folderName: json.data?.folderName,
    quota: json.data?.quota,
    quotaTotal: json.data?.quotaTotal,
    spaceTotalText: json.data?.spaceTotalText,
    spaceUsedText: json.data?.spaceUsedText,
    spaceRemainText: json.data?.spaceRemainText,
    spaceTotal: json.data?.spaceTotal,
    spaceUsed: json.data?.spaceUsed,
    spaceRemain: json.data?.spaceRemain,
    offlineLimit: json.data?.offlineLimit,
  };
}

export type P115Task = {
  name: string;
  /** 数值状态由 /pan/cloud 推导：2=已完成（percent>=100）、1=下载中（percent>0）、0=排队、-1=失败（status_text 含「失败」） */
  status: number;
  statusLabel: string;
  percent: number;
  error?: string;
  infoHash?: string;
  size?: number | null;
  addTime?: number | null;
  updateTime?: number | null;
  fileId?: string | null;
};

export type P115TasksResult = {
  tasks: P115Task[];
  page?: number | null;
  pageCount?: number | null;
  count?: number | null;
  quota?: number | null;
  quotaTotal?: number | null;
};

export type P115ClearMode = 'done' | 'failed' | 'all';

/** /api/pan/cloud 原始返回（snake_case，非信封直返） */
type PanCloudResult = {
  counts?: { total?: number | null };
  quota?: { remaining?: number | null; total?: number | null };
  page?: number | null;
  page_count?: number | null;
  tasks?: Array<{
    info_hash?: string;
    name?: string;
    size?: number | null;
    add_time?: number | null;
    status?: string;
    status_text?: string;
    percent?: number | null;
  }>;
};

function panTaskStatus(statusText: string, percent: number): number {
  if (percent >= 100) return 2;
  if (/失败/.test(statusText)) return -1;
  if (percent > 0) return 1;
  return 0;
}

export async function listP115Tasks(page = 1): Promise<P115TasksResult> {
  const res = await apiFetch(`/pan/cloud?page=${Math.max(1, page)}`);
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as PanCloudResult;
  return {
    tasks: (json.tasks || []).map((t) => {
      const statusLabel = String(t.status_text || '');
      const percent = Number(t.percent) || 0;
      return {
        name: String(t.name || ''),
        status: panTaskStatus(statusLabel, percent),
        statusLabel,
        percent,
        infoHash: t.info_hash,
        size: t.size ?? null,
        addTime: t.add_time ?? null,
      };
    }),
    page: json.page ?? null,
    pageCount: json.page_count ?? null,
    count: json.counts?.total ?? null,
    quota: json.quota?.remaining ?? null,
    quotaTotal: json.quota?.total ?? null,
  };
}

export async function clearP115Tasks(
  mode: P115ClearMode,
): Promise<{
  ok?: boolean;
  mode?: string;
  message?: string;
  tasks?: P115Task[];
  quota?: number | null;
  quotaTotal?: number | null;
}> {
  const res = await apiFetch('/pan/cloud/clear', {
    method: 'POST',
    body: JSON.stringify({ mode }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  return (await res.json().catch(() => ({}))) as {
    ok?: boolean;
    mode?: string;
    message?: string;
    tasks?: P115Task[];
    quota?: number | null;
    quotaTotal?: number | null;
  };
}

export async function deleteP115Task(
  infoHash: string,
): Promise<{
  ok?: boolean;
  infoHash?: string;
  message?: string;
  tasks?: P115Task[];
  quota?: number | null;
  quotaTotal?: number | null;
}> {
  const res = await apiFetch('/pan/cloud/delete', {
    method: 'POST',
    body: JSON.stringify({ info_hash: infoHash }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  return (await res.json().catch(() => ({}))) as {
    ok?: boolean;
    infoHash?: string;
    message?: string;
    tasks?: P115Task[];
    quota?: number | null;
    quotaTotal?: number | null;
  };
}

export type P115ExtractConfig = {
  folderCid: string;
  folderName: string;
  password: string;
};

export type P115ExtractItem = {
  id: string;
  name: string;
  size: number;
  /** queued | running | waiting | done | failed */
  state: string;
  stage: string;
  message: string;
  attempts: number;
  percent: number;
  /** 通道：cloud（115 云端解压）/ local（本地兜底） */
  lane?: string;
  /** 阶段：prepare / extract / verify，空表示还没开始 */
  phase?: string;
};

export type P115ExtractStatus = {
  running: boolean;
  scanning: boolean;
  /** 本地下载/解压的工作目录（挂载出来方便查看） */
  workDir?: string;
  /** 上一次扫描的清单（后端持久化，刷新页面后可直接恢复） */
  preview?: P115ExtractItem[] | null;
  previewCid?: string;
  startedAt: number;
  finishedAt: number;
  folderCid: string;
  folderName: string;
  current: P115ExtractItem | null;
  items: P115ExtractItem[];
  counts: {
    total: number;
    done: number;
    failed: number;
    waiting: number;
    queued: number;
  };
  config: P115ExtractConfig;
};

async function readExtract<T>(res: Response): Promise<T> {
  if (!res.ok) throw new Error(await parseError(res));
  return (await res.json()) as T;
}

export async function getP115ExtractConfig(): Promise<P115ExtractConfig> {
  return readExtract<P115ExtractConfig>(await apiFetch('/pan/extract/config'));
}

export async function putP115ExtractConfig(
  body: P115ExtractConfig,
): Promise<P115ExtractConfig> {
  const res = await apiFetch('/pan/extract/config', {
    method: 'PUT',
    body: JSON.stringify(body),
  });
  return readExtract<P115ExtractConfig>(res);
}

export async function getP115ExtractStatus(): Promise<P115ExtractStatus> {
  return readExtract<P115ExtractStatus>(await apiFetch('/pan/extract/status'));
}

export type P115ExtractPreview = {
  folderCid: string;
  items: P115ExtractItem[];
};

/** 预览目录下待解压的压缩包，不启动队列 */
export async function getP115ExtractPreview(cid?: string): Promise<P115ExtractPreview> {
  const qs = cid ? `?cid=${encodeURIComponent(cid)}` : '';
  return readExtract<P115ExtractPreview>(await apiFetch(`/pan/extract/preview${qs}`));
}

export async function startP115Extract(): Promise<P115ExtractStatus> {
  const res = await apiFetch('/pan/extract/start', { method: 'POST' });
  return readExtract<P115ExtractStatus>(res);
}

export async function stopP115Extract(): Promise<P115ExtractStatus> {
  const res = await apiFetch('/pan/extract/stop', { method: 'POST' });
  return readExtract<P115ExtractStatus>(res);
}

export type P115QrApp = { key: string; label: string };

export type P115QrStart = {
  uid: string;
  time: string | number;
  sign: string;
  qrImage?: string | null;
  qrcode?: string | null;
  app: string;
  /** 可选扫码端（客户端类型），默认第一个为推荐端 */
  apps?: P115QrApp[];
};

export type P115QrStatus = {
  status: number | null;
  statusLabel: string;
  done: boolean;
  expired: boolean;
};

export async function startP115Qrcode(app = 'alipaymini'): Promise<P115QrStart> {
  const res = await apiFetch('/settings/p115/qrcode/start', {
    method: 'POST',
    body: JSON.stringify({ app }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<P115QrStart>).data;
}

export async function pollP115Qrcode(body: {
  uid: string;
  time: string | number;
  sign: string;
}): Promise<P115QrStatus> {
  const res = await apiFetch('/settings/p115/qrcode/status', {
    method: 'POST',
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<P115QrStatus>).data;
}

export async function completeP115Qrcode(body: {
  uid: string;
  app?: string;
  save?: boolean;
}): Promise<P115Config & { cookie?: string; saved?: boolean; message?: string }> {
  const res = await apiFetch('/settings/p115/qrcode/complete', {
    method: 'POST',
    body: JSON.stringify({
      uid: body.uid,
      app: body.app || 'alipaymini',
      save: body.save !== false,
    }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as Envelope<
    P115Config & { cookie?: string; saved?: boolean }
  > & { message: string };
  return { ...json.data, message: json.message };
}

/**
 * 外链封面 → 同源 /cover-proxy（服务端走 settings.proxyUrl）。
 * 已是 /api、相对路径或已代理的地址原样返回。
 * @param opts.w 列表缩略最长边（服务端 JPEG 压缩）
 */
