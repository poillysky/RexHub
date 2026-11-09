'use client';

import type { AiAssistantSkillGroup, AiAssistantToolMeta, AiPresetOption } from '@/lib/api';

export const LLM_BASE_DEFAULT = 'https://api.openai.com/v1';
export const LLM_MODEL_DEFAULT = 'gpt-4o-mini';

export type AiTab = 'model' | 'agent';

export const TABS: { key: AiTab; label: string }[] = [
  { key: 'model', label: '模型' },
  { key: 'agent', label: 'Agent' },
];

export const DEFAULT_ASSISTANT_TOOLS: Record<string, boolean> = {
  sehua_keyword: true,
  magnet_search: true,
  media_search: true,
  media_person_works: true,
  web_search: true,
};

export const DEFAULT_SKILL_GROUPS: AiAssistantSkillGroup[] = [
  { id: 'warehouse', label: '仓库', desc: '色花资源库' },
  { id: 'magnet', label: '磁力', desc: 'Bitmagnet' },
  { id: 'media', label: '影视', desc: 'TMDB 等元数据' },
  { id: 'web', label: '网络', desc: '公开网页搜索' },
];

export const DEFAULT_TOOL_META: AiAssistantToolMeta[] = [
  { id: 'sehua_keyword', group: 'warehouse', label: '仓库关键词', desc: '色花标题/文件名搜索' },
  { id: 'magnet_search', group: 'magnet', label: '磁力搜索', desc: 'Bitmagnet 关键词' },
  { id: 'media_search', group: 'media', label: '影视搜索', desc: 'TMDB / 豆瓣等' },
  { id: 'media_person_works', group: 'media', label: '影人作品', desc: '按演员/导演列作品' },
  { id: 'web_search', group: 'web', label: '网络搜索', desc: 'SearXNG / Serper / Brave' },
];

export function renderSourceOptions(list: AiPresetOption[], start: number, end?: number) {
  return list.slice(start, end).map((o) => (
    <option key={o.value} value={o.value}>
      {o.label}
    </option>
  ));
}
