import { API_BASE, type PluginEntry, type PluginMarketEntry } from '@/lib/api';

export type View = 'market' | 'installed';

export type Detail = {
  entry: PluginEntry;
  repository?: string;
  market?: PluginMarketEntry;
};

export const PLUGIN_GROUPS = ['video', 'shortdrama', 'studio', 'subtitle', 'danmaku', 'other'] as const;

export const GROUP_LABELS: Record<string, string> = {
  video: '影视',
  shortdrama: '短剧',
  studio: '片商',
  subtitle: '字幕',
  danmaku: '弹幕',
  other: '其他',
};

export function pluginGroup(category?: string) {
  const key = (category || '').toLowerCase();
  if (key === 'shortdrama') return 'shortdrama';
  if (key === 'subtitle') return 'subtitle';
  if (key === 'danmaku') return 'danmaku';
  if (key === 'studio' || key === 'provider') return 'studio';
  if (['video', 'resource', 'playback', 'metadata', 'cloud'].includes(key)) return 'video';
  return 'other';
}

export function categoryLabel(category?: string) {
  return GROUP_LABELS[pluginGroup(category)] || GROUP_LABELS.other;
}

export function categoryRank(category?: string) {
  const index = PLUGIN_GROUPS.indexOf(pluginGroup(category) as (typeof PLUGIN_GROUPS)[number]);
  return index < 0 ? PLUGIN_GROUPS.length : index;
}

const CAPABILITY_LABELS: Record<string, string> = {
  'resource.search': '资源搜索',
  'playback.resolve': '播放解析',
  'playback.extract': '内容列表',
  'playback.headers': '播放请求头',
  'playback.stream': '播放流',
  'subtitle.search': '字幕搜索',
  'subtitle.download': '字幕下载',
  'danmaku.search': '弹幕搜索',
  'danmaku.detail': '弹幕剧集',
  'danmaku.fetch': '弹幕内容',
  'metadata.movie': '影片元数据',
  'metadata.tv': '剧集元数据',
  'cloud.search': '网盘搜索',
  'cloud.transfer': '网盘转存',
  'shortdrama.ranks': '短剧榜单',
  'shortdrama.catalog': '短剧目录',
  'shortdrama.search': '短剧搜索',
  'shortdrama.detail': '短剧详情',
  'shortdrama.stream': '短剧播放',
};

function capabilityLabel(capability: string) {
  return CAPABILITY_LABELS[capability] || capability;
}

const CAPABILITY_FEATURES: Record<string, string> = {
  'playback.extract': '浏览',
  'resource.search': '浏览',
  'playback.resolve': '播放',
  'playback.headers': '播放',
  'playback.stream': '播放',
  'metadata.movie': '详情',
  'metadata.tv': '详情',
  'subtitle.search': '字幕',
  'subtitle.download': '字幕',
  'danmaku.search': '弹幕',
  'danmaku.detail': '弹幕',
  'danmaku.fetch': '弹幕',
  'cloud.search': '网盘',
  'cloud.transfer': '网盘',
};

export function capabilityFeatures(capabilities: string[]) {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const capability of capabilities) {
    // 短剧能力统一由分类标签展示，不再重复罗列
    if (capability.startsWith('shortdrama.')) continue;
    const feature = CAPABILITY_FEATURES[capability] || capabilityLabel(capability);
    if (seen.has(feature)) continue;
    seen.add(feature);
    result.push(feature);
  }
  return result;
}

export function runtimeLabel(entry: PluginEntry) {
  const engine = entry.runtime?.engine;
  if (engine === 'widget-js') return 'Widget JS';
  if (engine === 'python') return 'Python 进程';
  if (engine === 'process') return '独立进程';
  const type = entry.runtime?.type || 'isolated';
  if (type === 'http') return '外部 HTTP';
  if (type === 'shared') return '共享运行时';
  return '独立进程';
}

export function statusText(entry: PluginEntry) {
  if (entry.error) return '异常';
  if (!entry.enabled) return '已停用';
  return entry.running ? '运行中' : '未运行';
}

export function statusTone(entry: PluginEntry) {
  if (entry.error) return 'error';
  if (!entry.enabled) return 'mute';
  return entry.running ? 'ok' : 'warn';
}

export function statusChip(entry: PluginEntry) {
  if (entry.error) return 'is-bad';
  if (!entry.enabled) return 'is-off';
  return entry.running ? 'is-on' : 'is-warn';
}

/** 已安装插件才有可用的 logo 接口；市场里未安装的插件继续用分类图标 */
export function pluginLogo(entry: PluginEntry): string {
  if (!entry.installed) return '';
  const raw = String(entry.ui?.shortdrama?.logo || '').trim();
  if (!raw) return '';
  if (raw.startsWith('/') && !raw.startsWith('//') && !raw.startsWith('/api/')) {
    return `${API_BASE}/v1/plugins/${encodeURIComponent(entry.id)}/media?path=${encodeURIComponent(raw)}`;
  }
  return raw;
}
