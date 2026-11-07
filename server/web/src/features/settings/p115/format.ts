import type {
  P115Config,
  P115SaveSource,
  P115TargetFolder,
  P115Task,
} from '@/lib/api';
import type { P115PanelTab } from '../p115PanelCache';

export type Tab = P115PanelTab;
/** 目录浏览目标：三类转存目录 + 解压目录 */
export type BrowseTarget = P115SaveSource | 'extract';

export const TABS: Array<{ key: Tab; label: string }> = [
  { key: 'overview', label: '概览' },
  { key: 'extract', label: '解压' },
  { key: 'tasks', label: '任务' },
];

/** 转存入口：搜索 / 影视 / 片商，各自直存目标目录 */
export const SAVE_SOURCES: Array<{
  key: P115SaveSource;
  label: string;
  desc: string;
}> = [
  { key: 'search', label: '搜索', desc: '搜索结果直存本目录' },
  { key: 'media', label: '影视', desc: '电影 / 剧集直存本目录' },
  { key: 'maker', label: '片商', desc: '片商资源直存本目录' },
];

export function emptyTargets(): Record<P115SaveSource, P115TargetFolder> {
  return {
    search: { folderCid: '0', folderName: '' },
    media: { folderCid: '0', folderName: '' },
    maker: { folderCid: '0', folderName: '' },
  };
}

function folderFrom(
  t: P115TargetFolder | undefined,
  fallbackCid: string,
  fallbackName: string,
): P115TargetFolder {
  if (t?.folderCid != null || t?.folderName != null) {
    return {
      folderCid: String(t.folderCid || fallbackCid || '0') || '0',
      folderName: String(t.folderName || ''),
    };
  }
  return {
    folderCid: fallbackCid,
    folderName: fallbackName,
  };
}

export function normalizeTargets(
  data: Partial<P115Config> | null | undefined,
): Record<P115SaveSource, P115TargetFolder> {
  const base = emptyTargets();
  const legacyCid = String(data?.folderCid || '0') || '0';
  const legacyName = String(data?.folderName || '');
  for (const row of SAVE_SOURCES) {
    base[row.key] = folderFrom(data?.targets?.[row.key], legacyCid, legacyName);
  }
  return base;
}

export function folderDisplayName(t: P115TargetFolder) {
  return t.folderName || (t.folderCid === '0' ? '根目录' : '自定义目录');
}

export function formatQuota(
  remain: number | null | undefined,
  total: number | null | undefined,
) {
  if (remain == null && total == null) return null;
  if (remain != null && total != null) return `${remain} / ${total}`;
  if (remain != null) return String(remain);
  return String(total);
}

export function formatBytes(n: number | null | undefined) {
  if (n == null || !Number.isFinite(n) || n < 0) return null;
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  let v = n;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i += 1;
  }
  const digits = v >= 100 || i < 2 ? 0 : v >= 10 ? 1 : 2;
  const text =
    Number.isInteger(v) || digits === 0 ? String(Math.round(v)) : v.toFixed(digits);
  return `${text} ${units[i]}`;
}

export function formatTaskTime(ts: number | null | undefined) {
  if (ts == null || !Number.isFinite(ts) || ts <= 0) return '';
  const ms = ts < 1e12 ? ts * 1000 : ts;
  const d = new Date(ms);
  if (Number.isNaN(d.getTime())) return '';
  const weekdays = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
  const hh = String(d.getHours()).padStart(2, '0');
  const mm = String(d.getMinutes()).padStart(2, '0');
  return `${d.getMonth() + 1}/${d.getDate()} ${weekdays[d.getDay()]} ${hh}:${mm}`;
}

export function taskTone(status: number): 'ok' | 'warn' | 'run' | 'mute' {
  if (status === 2) return 'ok';
  if (status === -1) return 'warn';
  if (status === 1 || status === 0) return 'run';
  return 'mute';
}

export type TaskFilter = 'run' | 'failed' | 'done';

export const TASK_FILTERS: Array<{ key: TaskFilter; label: string }> = [
  { key: 'run', label: '下载中' },
  { key: 'failed', label: '已失败' },
  { key: 'done', label: '已完成' },
];

export function taskFilterOf(status: number): TaskFilter {
  if (status === 2) return 'done';
  if (status === -1) return 'failed';
  return 'run';
}

export function isHashLikeName(name: string, infoHash?: string) {
  const n = String(name || '').trim();
  const h = String(infoHash || '').trim();
  if (!n) return false;
  if (h && n.toLowerCase() === h.toLowerCase()) return true;
  return /^[a-f0-9]{40}$/i.test(n);
}

export function formatHashShort(raw: string) {
  const s = String(raw || '').trim();
  if (s.length <= 12) return s;
  return `${s.slice(0, 6)}…${s.slice(-4)}`;
}

export function taskDisplay(t: P115Task) {
  const raw = String(t.name || '').trim() || '未命名任务';
  const hash = String(t.infoHash || '').trim();
  if (isHashLikeName(raw, hash)) {
    const full = hash || raw;
    return {
      title: formatHashShort(full),
      subtitle: '磁力哈希',
      hashFull: full,
      isHash: true,
    };
  }
  return { title: raw, subtitle: null, hashFull: null, isHash: false };
}
