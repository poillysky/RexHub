'use client';

import { useState } from 'react';
import type { ResourceItem } from '@/types/resource';
import {
  getExtractPassword,
  linkKindOf,
  linksForResource,
  normalizeLinkKind,
} from '@/lib/detailResource';
import { runP115Save } from '@/lib/p115SaveClient';
import type { P115SaveSource } from '@/lib/api';
import { P115_SOURCE_LABEL, resolveP115SaveSource } from '@/lib/p115Source';
import { useTabNavigation } from '@/shell';

type ItemPick = Pick<
  ResourceItem,
  | 'hash'
  | 'ed2k_link'
  | 'ed2k_links'
  | 'extract_password'
  | 'description'
  | 'name'
  | 'title'
  | 'link_kind'
>;

export function P115SaveButton({
  item,
  compact = false,
  onToast,
  source,
  urls: urlsOverride,
  className,
}: {
  item: ItemPick;
  compact?: boolean;
  onToast?: (msg: string) => void;
  /** 覆盖入口目录；默认读影视/片商跳转上下文 */
  source?: P115SaveSource;
  /** 覆盖可转存链接（聚合搜索卡片这类非 ResourceItem 数据） */
  urls?: string[];
  /** 覆盖按钮样式 */
  className?: string;
}) {
  const tabCtx = useTabNavigation();
  const [loading, setLoading] = useState(false);

  const urls = urlsOverride?.length ? urlsOverride : linksForResource(item);
  const password = getExtractPassword(item);
  const titleHint = (item.title || item.name || '').trim();
  const kind = normalizeLinkKind(item.link_kind || linkKindOf(urls[0]));

  if (!urls.length) return null;

  const onSave = async () => {
    if (loading) return;
    setLoading(true);
    try {
      // 点击时解析，避免渲染时 session 尚未写入 / 已被清掉
      const saveSource = resolveP115SaveSource(source);
      const result = await runP115Save({
        urls,
        password,
        titleHint,
        source: saveSource,
      });
      if (!result.ok) {
        onToast?.(result.message);
        if (result.needConfig) {
          window.setTimeout(() => tabCtx?.scrollToTab('/settings'), 600);
        }
        return;
      }
      const destHint =
        saveSource !== 'search' ? ` → ${P115_SOURCE_LABEL[saveSource]}` : '';
      // 以后端 renameScheduled 为准（有密码且已安排后台改名）
      const tip = result.renameScheduled
        ? `已转存${destHint}，完成后自动标注密码`
        : kind === '115share'
          ? `115 分享已接收${destHint}`
          : `已加入离线下载${destHint}`;
      onToast?.(tip);
    } catch (e) {
      onToast?.(e instanceof Error ? e.message : '转存失败');
    } finally {
      setLoading(false);
    }
  };

  return (
    <button
      type="button"
      className={className ?? (compact ? 'detail-compact-btn' : 'app-btn-primary')}
      disabled={loading}
      onClick={() => void onSave()}
    >
      {loading ? '转存中…' : '转存 115'}
    </button>
  );
}
