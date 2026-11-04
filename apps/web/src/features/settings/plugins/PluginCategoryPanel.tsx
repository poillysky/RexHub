'use client';

/**
 * 插件分类面板：按分类（影视 / 短剧 / 片商 / 字幕 / 弹幕）展示本地插件与订阅模块，
 * 点进条目看详情与设置。订阅地址的管理集中在「Stremio 插件库」下方的订阅区。
 */

import { useCallback, useEffect, useMemo, useState } from 'react';
import { ChevronRight, Plus, RefreshCw } from 'lucide-react';
import { AppPush } from '@/components/ui/AppPush';
import { AppMsg } from '@/components/ui/AppMsg';
import { Switch } from '@/components/ui/switch';
import { usePanelAction, type StatusReporter } from '@/hooks/usePanelAction';
import {
  deletePlugin,
  getAdminPlugins,
  refreshPluginFeed,
  savePlugin,
  setPluginAutoUpdate,
  setPluginEnabled,
  setPluginFeedWidgetEnabled,
  updatePlugin,
  updatePluginFeedWidget,
  type FeedWidget,
  type PluginCatalog,
  type PluginRow,
} from '@/lib/api';
import { cn } from '@/lib/utils';

type Item = {
  kind: 'local' | 'widget';
  id: string;
  title: string;
  description: string;
  version: string;
  author: string;
  enabled: boolean;
  note: string;
  apiUrl: string;
  apiKey: string;
  proxyUrl: string;
  proxyEnabled: boolean;
  category: string;
  sourceBytes: number;
  encrypted: boolean;
  error: string;
  feedUrl?: string;
  modules: number;
};

const CATEGORY_META: Record<string, { title: string; desc: string; hint: string }> = {
  video: { title: '影视插件', desc: '影视条目与播放源', hint: '影视类插件决定片单、搜索与播放模块。' },
  drama: { title: '短剧插件', desc: '短剧聚合与剧集列表', hint: '短剧插件同时为 App 短剧 Tab 提供站点与列表。' },
  maker: { title: '片商插件', desc: '片商 / 番号资料', hint: '片商插件补充厂商、番号与演员资料。' },
  subtitle: { title: '字幕插件', desc: '字幕搜索与下载', hint: '字幕插件在播放页提供外挂字幕。' },
  danmu: { title: '弹幕插件', desc: '弹幕源与弹幕匹配', hint: '弹幕插件为播放页提供弹幕数据。' },
};

const CATEGORY_ORDER = ['video', 'drama', 'maker', 'subtitle', 'danmu'];

function toItem(row: PluginRow, kind: Item['kind'], feedUrl?: string): Item {
  return {
    kind,
    id: row.id,
    title: row.title_override || row.title || row.id,
    description: row.description_override || row.description || '',
    version: row.version || '',
    author: row.author || '',
    enabled: row.enabled !== false,
    note: row.note || '',
    apiUrl: row.api_url || '',
    apiKey: row.api_key || '',
    proxyUrl: row.proxy_url || '',
    proxyEnabled: Boolean(row.proxy_enabled),
    category: row.category || '',
    sourceBytes: Number(row.source_bytes || 0),
    encrypted: Boolean(row.source_encrypted),
    error: row.source_error || (row.analysis && row.analysis.ok === false ? String(row.analysis.error || '') : ''),
    feedUrl,
    modules: Array.isArray(row.analysis?.modules) ? row.analysis.modules.length : 0,
  };
}

function bytesText(n: number): string {
  if (!n) return '未知';
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

export function PluginCategoryPanel({
  category,
  onBack,
  onStatus,
}: {
  category: string;
  onBack: () => void;
  onStatus: StatusReporter;
}) {
  const meta = CATEGORY_META[category] || {
    title: '插件',
    desc: '插件列表',
    hint: '',
  };
  const [catalog, setCatalog] = useState<PluginCatalog | null>(null);
  const [detail, setDetail] = useState<Item | null>(null);
  const [source, setSource] = useState('');
  const [showAdd, setShowAdd] = useState(false);
  const { msg, setMsg, busy, run } = usePanelAction();

  const load = useCallback(async () => {
    const data = await getAdminPlugins();
    setCatalog(data);
    const widgets = data.feeds.flatMap((feed) => feed.widgets || []);
    const items = [...data.plugins, ...widgets].filter(
      (item) => (item.category || '') === category,
    );
    const on = items.filter((item) => item.enabled !== false).length;
    onStatus(
      items.length ? `${on}/${items.length} 启用` : '未添加',
      items.length ? (on ? 'ok' : 'warn') : 'mute',
    );
  }, [category, onStatus]);

  useEffect(() => {
    void run('读取失败', async () => {
      await load();
    });
  }, [load]);

  const items = useMemo(() => {
    if (!catalog) return [];
    return [
      ...catalog.plugins.map((row) => toItem(row, 'local')),
      ...catalog.feeds.flatMap((feed) =>
        (feed.widgets || []).map((row: FeedWidget) => toItem(row, 'widget', feed.url)),
      ),
    ].filter((item) => item.category === category);
  }, [catalog, category]);

  async function toggle(item: Item, enabled: boolean) {
    await run('操作失败', async () => {
      if (item.kind === 'local') await setPluginEnabled(item.id, enabled);
      else if (item.feedUrl)
        await setPluginFeedWidgetEnabled(item.feedUrl, item.id, enabled);
      setDetail((d) => (d && d.id === item.id ? { ...d, enabled } : d));
      await load();
    });
  }

  async function remove(item: Item) {
    if (!window.confirm(`删除插件「${item.title}」？`)) return;
    await run('删除失败', async () => {
      if (item.kind === 'local') await deletePlugin(item.id);
      setDetail(null);
      setMsg('已删除');
      await load();
    });
  }

  async function saveDetail(item: Item) {
    await run('保存失败', async () => {
      if (item.kind === 'local') {
        await updatePlugin(item.id, {
          title: item.title,
          description: item.description,
          note: item.note,
          apiUrl: item.apiUrl,
          apiKey: item.apiKey,
          proxyUrl: item.proxyUrl,
          proxyEnabled: item.proxyEnabled,
          enabled: item.enabled,
          category,
        });
      } else if (item.feedUrl) {
        await updatePluginFeedWidget({
          feedUrl: item.feedUrl,
          widgetId: item.id,
          title: item.title,
          description: item.description,
          note: item.note,
          apiUrl: item.apiUrl,
          enabled: item.enabled,
        });
      }
      setMsg('已保存');
      await load();
    });
  }

  async function addLocal() {
    if (!source.trim()) {
      setMsg('请粘贴插件源码');
      return;
    }
    await run('导入失败', async () => {
      await savePlugin(source, category);
      setSource('');
      setShowAdd(false);
      setMsg('已导入');
      await load();
    });
  }

  const feedUrl = catalog?.feeds[0]?.url || '';
  const auto = catalog?.auto_update;

  if (detail) {
    return (
      <AppPush title={detail.title} onBack={() => setDetail(null)}>
        <ul className="settings-group">
          <li>
            <div className="settings-kv">
              <span className="settings-kv__key">状态</span>
              <Switch
                checked={detail.enabled}
                disabled={busy}
                onCheckedChange={(v) => {
                  setDetail({ ...detail, enabled: v });
                  void toggle(detail, v);
                }}
              />
            </div>
          </li>
          <li>
            <div className="settings-kv">
              <span className="settings-kv__key">版本</span>
              <span className="settings-kv__val">{detail.version || '—'}</span>
            </div>
          </li>
          <li>
            <div className="settings-kv">
              <span className="settings-kv__key">作者</span>
              <span className="settings-kv__val">{detail.author || '—'}</span>
            </div>
          </li>
          <li>
            <div className="settings-kv">
              <span className="settings-kv__key">来源</span>
              <span className="settings-kv__val">
                {detail.kind === 'local' ? '本地上传' : '订阅'}
              </span>
            </div>
          </li>
          <li>
            <div className="settings-kv">
              <span className="settings-kv__key">大小</span>
              <span className="settings-kv__val">{bytesText(detail.sourceBytes)}</span>
            </div>
          </li>
          <li>
            <div className="settings-kv">
              <span className="settings-kv__key">模块</span>
              <span className="settings-kv__val">
                {detail.modules ? `${detail.modules} 个` : '—'}
              </span>
            </div>
          </li>
          <li>
            <div className="settings-kv">
              <span className="settings-kv__key">插件 ID</span>
              <span className="settings-kv__val allow-select">{detail.id}</span>
            </div>
          </li>
        </ul>

        {detail.error || detail.encrypted ? (
          <AppMsg>{detail.error || '插件为加密模块，运行时无法执行'}</AppMsg>
        ) : null}

        <p className="settings-group-label">设置</p>
        <section className="app-section">
          <div className="app-section-body">
            <label className="app-field app-field--stack">
              <span className="app-label">显示名称</span>
              <input
                className="allow-select"
                value={detail.title}
                onChange={(e) => setDetail({ ...detail, title: e.target.value })}
                disabled={busy}
              />
            </label>
            <label className="app-field app-field--stack">
              <span className="app-label">简介</span>
              <textarea
                className="allow-select"
                rows={3}
                value={detail.description}
                onChange={(e) => setDetail({ ...detail, description: e.target.value })}
                disabled={busy}
              />
            </label>
            <label className="app-field app-field--stack">
              <span className="app-label">接口地址</span>
              <input
                className="allow-select"
                placeholder="https://…"
                value={detail.apiUrl}
                onChange={(e) => setDetail({ ...detail, apiUrl: e.target.value })}
                autoCapitalize="off"
                spellCheck={false}
                disabled={busy}
              />
            </label>
            {detail.kind === 'local' ? (
              <>
                <label className="app-field app-field--stack">
                  <span className="app-label">API Key</span>
                  <input
                    className="allow-select"
                    value={detail.apiKey}
                    onChange={(e) => setDetail({ ...detail, apiKey: e.target.value })}
                    autoCapitalize="off"
                    spellCheck={false}
                    disabled={busy}
                  />
                </label>
                <label className="app-field app-field--stack">
                  <span className="app-label">代理地址</span>
                  <input
                    className="allow-select"
                    placeholder="http://主机:端口"
                    value={detail.proxyUrl}
                    onChange={(e) => setDetail({ ...detail, proxyUrl: e.target.value })}
                    autoCapitalize="off"
                    spellCheck={false}
                    disabled={busy}
                  />
                </label>
                <div className="settings-nav">
                  <span className="settings-nav__main">
                    <span className="settings-nav__title">单独启用代理</span>
                    <span className="settings-nav__desc">仅此插件走上面的代理</span>
                  </span>
                  <Switch
                    checked={detail.proxyEnabled}
                    disabled={busy || !detail.proxyUrl.trim()}
                    onCheckedChange={(v) => setDetail({ ...detail, proxyEnabled: v })}
                  />
                </div>
              </>
            ) : null}
            <label className="app-field app-field--stack">
              <span className="app-label">备注</span>
              <input
                className="allow-select"
                value={detail.note}
                onChange={(e) => setDetail({ ...detail, note: e.target.value })}
                disabled={busy}
              />
            </label>
          </div>
        </section>

        <div className="app-actions">
          <button
            type="button"
            className="app-btn-secondary"
            disabled={busy}
            onClick={() => void remove(detail)}
          >
            删除
          </button>
          <button
            type="button"
            className="app-btn-primary"
            style={{ flex: 1 }}
            disabled={busy}
            onClick={() => void saveDetail(detail)}
          >
            {busy ? '保存中…' : '保存'}
          </button>
        </div>
        {msg ? (
          <AppMsg allowSelect onDismiss={() => setMsg('')}>
            {msg}
          </AppMsg>
        ) : null}
      </AppPush>
    );
  }

  return (
    <AppPush title={meta.title} onBack={onBack}>
      <p className="settings-group-label">{meta.desc}</p>
      {items.length ? (
        <ul className="settings-group">
          {items.map((item) => (
            <li key={`${item.kind}:${item.id}`}>
              <button
                type="button"
                className="settings-nav"
                onClick={() => {
                  setMsg('');
                  setDetail(item);
                }}
              >
                <span className="settings-nav__main">
                  <span className="settings-nav__title">{item.title}</span>
                  <span className="settings-nav__desc">
                    {item.description || item.id}
                  </span>
                </span>
                <span className="settings-nav__trail">
                  <span
                    className={cn(
                      'settings-nav__status',
                      item.enabled
                        ? 'settings-nav__status--ok'
                        : 'settings-nav__status--mute',
                    )}
                  >
                    {item.enabled ? '已启用' : '已停用'}
                  </span>
                  <ChevronRight
                    className="settings-nav__chev"
                    size={17}
                    strokeWidth={2.4}
                    aria-hidden
                  />
                </span>
              </button>
            </li>
          ))}
        </ul>
      ) : (
        <p className="settings-hub__empty">暂无{meta.title}，可在下方导入或在订阅里添加。</p>
      )}

      <p className="settings-group-label">插件来源</p>
      <section className="app-section">
        <div className="app-section-body">
          {feedUrl ? (
            <div className="settings-kv">
              <span className="settings-kv__key">订阅</span>
              <span className="settings-kv__val allow-select">{feedUrl}</span>
            </div>
          ) : null}
          {auto ? (
            <div className="settings-nav">
              <span className="settings-nav__main">
                <span className="settings-nav__title">自动更新订阅</span>
                <span className="settings-nav__desc">
                  {auto.last_result || '每 6 小时刷新一次'}
                </span>
              </span>
              <Switch
                checked={auto.enabled}
                disabled={busy || !feedUrl}
                onCheckedChange={(v) =>
                  void run('保存失败', async () => {
                    await setPluginAutoUpdate(v, auto.interval_minutes);
                    await load();
                    setMsg(v ? '已开启自动更新' : '已关闭自动更新');
                  })
                }
              />
            </div>
          ) : null}
        </div>
      </section>

      {showAdd ? (
        <>
          <p className="settings-group-label">导入插件源码</p>
          <section className="app-section">
            <div className="app-section-body">
              <textarea
                className="allow-select"
                rows={8}
                placeholder="粘贴 ForwardWidget 插件源码…"
                value={source}
                onChange={(e) => setSource(e.target.value)}
                disabled={busy}
              />
            </div>
          </section>
        </>
      ) : null}

      <div className="app-actions">
        <button
          type="button"
          className="app-btn-secondary"
          disabled={busy}
          onClick={() => setShowAdd((v) => !v)}
        >
          {showAdd ? '取消' : '导入源码'}
        </button>
        {showAdd ? (
          <button
            type="button"
            className="app-btn-primary"
            style={{ flex: 1 }}
            disabled={busy}
            onClick={() => void addLocal()}
          >
            <Plus size={15} strokeWidth={2.4} /> 导入
          </button>
        ) : (
          <button
            type="button"
            className="app-btn-primary"
            style={{ flex: 1 }}
            disabled={busy}
            onClick={() =>
              void run('更新失败', async () => {
                if (feedUrl) await refreshPluginFeed(feedUrl);
                await load();
                setMsg('订阅已更新');
              })
            }
          >
            <RefreshCw size={15} strokeWidth={2.4} /> 更新订阅
          </button>
        )}
      </div>
      {msg ? (
        <AppMsg allowSelect onDismiss={() => setMsg('')}>
          {msg}
        </AppMsg>
      ) : null}
    </AppPush>
  );
}
