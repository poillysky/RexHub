'use client';

/**
 * Stremio 插件库：仓库订阅、addon 列表与详情。
 * 对应原 /admin 管理台的「Stremio」页签，接口在 /api/admin/stremio。
 */

import { useCallback, useEffect, useMemo, useState } from 'react';
import { ChevronRight, Plus, RefreshCw } from 'lucide-react';
import { AppPush } from '@/components/ui/AppPush';
import { AppMsg } from '@/components/ui/AppMsg';
import { Switch } from '@/components/ui/switch';
import { usePanelAction, type StatusReporter } from '@/hooks/usePanelAction';
import {
  addStremioAddon,
  addStremioRepository,
  deleteStremioAddon,
  deleteStremioRepository,
  getStremioCatalog,
  refreshStremioRepository,
  setStremioAddonEnabled,
  testStremioAddon,
  type StremioAddon,
  type StremioCatalog,
} from '@/lib/api';

export function StremioPanel({
  onBack,
  onStatus,
}: {
  onBack: () => void;
  onStatus: StatusReporter;
}) {
  const [catalog, setCatalog] = useState<StremioCatalog | null>(null);
  const [detail, setDetail] = useState<StremioAddon | null>(null);
  const [repoUrl, setRepoUrl] = useState('');
  const [addonUrl, setAddonUrl] = useState('');
  const { msg, setMsg, busy, run } = usePanelAction();

  const load = useCallback(async () => {
    const data = await getStremioCatalog();
    setCatalog(data);
    const s = data.stats;
    onStatus(
      s.addons ? `${s.enabled}/${s.addons} addon` : '未添加',
      s.addons ? (s.enabled ? 'ok' : 'warn') : 'mute',
    );
    return data;
  }, [onStatus]);

  useEffect(() => {
    void run('读取失败', async () => {
      await load();
    });
  }, [load]);

  const addons = useMemo(() => {
    if (!catalog) return [];
    return [...catalog.addons].sort((a, b) => {
      if (Boolean(a.enabled) !== Boolean(b.enabled)) return a.enabled ? -1 : 1;
      return (a.manifest?.name || a.slug).localeCompare(b.manifest?.name || b.slug);
    });
  }, [catalog]);

  async function toggle(addon: StremioAddon, enabled: boolean) {
    await run('操作失败', async () => {
      await setStremioAddonEnabled(addon.slug, enabled);
      setDetail((d) => (d && d.slug === addon.slug ? { ...d, enabled } : d));
      await load();
    });
  }

  if (detail) {
    const manifest = detail.manifest || {};
    return (
      <AppPush title={manifest.name || detail.slug} onBack={() => setDetail(null)}>
        <ul className="settings-group">
          <li>
            <div className="settings-kv">
              <span className="settings-kv__key">启用</span>
              <Switch
                checked={detail.enabled !== false}
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
              <span className="settings-kv__key">标识</span>
              <span className="settings-kv__val allow-select">{detail.slug}</span>
            </div>
          </li>
          <li>
            <div className="settings-kv">
              <span className="settings-kv__key">类型</span>
              <span className="settings-kv__val">
                {(manifest.types || []).join(' / ') || '—'}
              </span>
            </div>
          </li>
          <li>
            <div className="settings-kv">
              <span className="settings-kv__key">版本</span>
              <span className="settings-kv__val">{manifest.version || '—'}</span>
            </div>
          </li>
          <li>
            <div className="settings-kv">
              <span className="settings-kv__key">传输</span>
              <span className="settings-kv__val">{detail.transport || '—'}</span>
            </div>
          </li>
        </ul>

        {manifest.description ? <AppMsg allowSelect>{manifest.description}</AppMsg> : null}

        <p className="settings-group-label">安装地址</p>
        <section className="app-section">
          <div className="app-section-body">
            <div className="settings-kv settings-kv--stack">
              <span className="settings-kv__key allow-select">
                {detail.manifest_url || '—'}
              </span>
            </div>
            {detail.repository ? (
              <div className="settings-kv">
                <span className="settings-kv__key">来源仓库</span>
                <span className="settings-kv__val allow-select">{detail.repository}</span>
              </div>
            ) : null}
          </div>
        </section>

        <div className="app-actions">
          <button
            type="button"
            className="app-btn-secondary"
            disabled={busy}
            onClick={() =>
              void run('测试失败', async () => {
                const r = await testStremioAddon(detail.slug);
                setMsg(r.ok ? '连通正常' : r.message || '连接失败');
              })
            }
          >
            测试连接
          </button>
          <button
            type="button"
            className="app-btn-secondary"
            disabled={busy}
            onClick={() => {
              if (!window.confirm(`删除 addon「${manifest.name || detail.slug}」？`)) return;
              void run('删除失败', async () => {
                await deleteStremioAddon(detail.slug);
                setDetail(null);
                setMsg('已删除');
                await load();
              });
            }}
          >
            删除
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
    <AppPush title="Stremio 插件库" onBack={onBack}>
      <p className="settings-group-label">已安装 addon</p>
      {addons.length ? (
        <ul className="settings-group">
          {addons.map((addon) => (
            <li key={addon.slug}>
              <button
                type="button"
                className="settings-nav"
                onClick={() => {
                  setMsg('');
                  setDetail(addon);
                }}
              >
                <span className="settings-nav__main">
                  <span className="settings-nav__title">
                    {addon.manifest?.name || addon.slug}
                  </span>
                  <span className="settings-nav__desc">
                    {addon.manifest?.description || addon.manifest_url || ''}
                  </span>
                </span>
                <span className="settings-nav__trail">
                  <span
                    className={`settings-nav__status ${
                      addon.enabled !== false
                        ? 'settings-nav__status--ok'
                        : 'settings-nav__status--mute'
                    }`}
                  >
                    {addon.enabled !== false ? '已启用' : '已停用'}
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
        <p className="settings-hub__empty">还没有 addon，先添加仓库或直接粘贴安装地址。</p>
      )}

      <p className="settings-group-label">仓库订阅</p>
      {catalog?.repositories.length ? (
        <ul className="settings-group">
          {catalog.repositories.map((repo) => (
            <li key={repo.url}>
              <div className="settings-nav settings-nav--static">
                <span className="settings-nav__main">
                  <span className="settings-nav__title">{repo.title || repo.url}</span>
                  <span className="settings-nav__desc allow-select">
                    {repo.error ? repo.error : `${repo.count || 0} 个 addon`}
                  </span>
                </span>
                <span className="settings-nav__trail">
                  <button
                    type="button"
                    className="app-icon-btn"
                    aria-label="刷新仓库"
                    disabled={busy}
                    onClick={() =>
                      void run('刷新失败', async () => {
                        await refreshStremioRepository(repo.url);
                        await load();
                        setMsg('已刷新');
                      })
                    }
                  >
                    <RefreshCw size={15} strokeWidth={2.4} />
                  </button>
                  <button
                    type="button"
                    className="app-icon-btn"
                    aria-label="删除仓库"
                    disabled={busy}
                    onClick={() => {
                      if (!window.confirm(`删除仓库「${repo.title || repo.url}」？`)) return;
                      void run('删除失败', async () => {
                        await deleteStremioRepository(repo.url);
                        await load();
                        setMsg('已删除');
                      });
                    }}
                  >
                    ×
                  </button>
                </span>
              </div>
            </li>
          ))}
        </ul>
      ) : (
        <p className="settings-hub__empty">暂无仓库订阅。</p>
      )}

      <section className="app-section">
        <div className="app-section-body">
          <label className="app-field app-field--stack">
            <span className="app-label">仓库地址</span>
            <input
              className="allow-select"
              placeholder="https://…/manifest.json"
              value={repoUrl}
              onChange={(e) => setRepoUrl(e.target.value)}
              autoCapitalize="off"
              spellCheck={false}
              disabled={busy}
            />
          </label>
          <label className="app-field app-field--stack">
            <span className="app-label">直接安装 addon</span>
            <input
              className="allow-select"
              placeholder="https://…/manifest.json"
              value={addonUrl}
              onChange={(e) => setAddonUrl(e.target.value)}
              autoCapitalize="off"
              spellCheck={false}
              disabled={busy}
            />
          </label>
          {catalog?.presets.length ? (
            <div className="stremio-presets">
              {catalog.presets.map((preset) => (
                <button
                  key={preset.url}
                  type="button"
                  className="app-chip"
                  disabled={busy}
                  onClick={() => setRepoUrl(preset.url)}
                >
                  {preset.title}
                </button>
              ))}
            </div>
          ) : null}
        </div>
      </section>

      <div className="app-actions">
        <button
          type="button"
          className="app-btn-secondary"
          disabled={busy || !addonUrl.trim()}
          onClick={() =>
            void run('添加失败', async () => {
              await addStremioAddon(addonUrl.trim());
              setAddonUrl('');
              await load();
              setMsg('addon 已添加');
            })
          }
        >
          安装 addon
        </button>
        <button
          type="button"
          className="app-btn-primary"
          style={{ flex: 1 }}
          disabled={busy || !repoUrl.trim()}
          onClick={() =>
            void run('添加失败', async () => {
              await addStremioRepository(repoUrl.trim());
              setRepoUrl('');
              await load();
              setMsg('仓库已添加');
            })
          }
        >
          <Plus size={15} strokeWidth={2.4} /> 添加仓库
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
