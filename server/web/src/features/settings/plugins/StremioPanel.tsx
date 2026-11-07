'use client';

/**
 * Stremio 插件库：仓库列表 → 仓库内 addon 列表 → addon 详情。
 * 对应原 /admin 管理台的「Stremio」页签，接口在 /api/admin/stremio。
 */

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Boxes, ChevronRight, LayoutGrid, Package, Plus, RefreshCw, Trash2 } from 'lucide-react';
import { AppPush } from '@/components/ui/AppPush';
import { AddonContent } from './AddonContent';
import { AppMsg } from '@/components/ui/AppMsg';
import { Switch } from '@/components/ui/switch';
import { usePanelAction } from '@/hooks/usePanelAction';
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

/** 伪仓库：不归属任何仓库、直接安装的 addon。 */
const DIRECT_REPO = '__direct__';

/** 仓库内 addon 列表每页数量，避免大仓库一次渲染几百行。 */
const PAGE_SIZE = 50;

function addonName(addon: StremioAddon) {
  return addon.manifest?.name || addon.slug;
}

/** addon 类型标签（去重）：直接使用 manifest 原始类型。 */
function addonTypes(addon: StremioAddon) {
  const labels = addon.manifest?.types || [];
  const result: string[] = [];
  labels.forEach((label) => {
    if (label && !result.includes(label)) result.push(label);
  });
  return result.length ? result : ['other'];
}

/** 筛选用分组：一个 addon 可能同时属于多个类型。 */
function addonTypeGroups(addon: StremioAddon) {
  return addonTypes(addon);
}

/** 把 manifest.logo 解析成可访问地址：相对路径按 manifest_url 补全。 */
function resolveLogo(addon: StremioAddon) {
  const raw = (addon.manifest?.logo || '').trim();
  if (!raw) return '';
  if (/^https?:\/\//i.test(raw)) return raw;
  if (raw.startsWith('//')) return `https:${raw}`;
  const base = addon.manifest_url || addon.transport || '';
  if (!base) return '';
  try {
    return new URL(raw, base).toString();
  } catch {
    return '';
  }
}

function originOf(url: string) {
  if (!url) return '';
  try {
    return new URL(url).origin;
  } catch {
    return '';
  }
}

/** 图标候选：manifest 真实 logo → 站点 favicon（真实地址，不写死任何图片 URL）。 */
function iconSources(addon: StremioAddon) {
  const sources: string[] = [];
  const logo = resolveLogo(addon);
  if (logo) sources.push(logo);
  const origin = originOf(addon.transport || addon.manifest_url || '');
  if (origin) sources.push(`${origin}/favicon.ico`);
  return sources;
}

function AddonAvatar({
  addon,
  iconSize,
  className,
}: {
  addon: StremioAddon;
  iconSize: number;
  className: string;
}) {
  const sources = iconSources(addon);
  const [stage, setStage] = useState(0);
  // eslint-disable-next-line react-hooks/set-state-in-effect
  useEffect(() => setStage(0), [addon.slug]);
  const src = sources[stage];
  if (!src) {
    return (
      <span className={className} aria-hidden>
        <Package size={iconSize} strokeWidth={2.1} />
      </span>
    );
  }
  return (
    <span className={`${className} stremio-avatar--image`} aria-hidden>
      <img
        src={src}
        alt=""
        loading="lazy"
        decoding="async"
        referrerPolicy="no-referrer"
        onError={() => setStage((v) => v + 1)}
      />
    </span>
  );
}

function RepoAvatar({
  url,
  iconSize,
  className,
}: {
  url: string;
  iconSize: number;
  className: string;
}) {
  const [failed, setFailed] = useState(false);
  // eslint-disable-next-line react-hooks/set-state-in-effect
  useEffect(() => setFailed(false), [url]);
  const origin = originOf(url);
  if (!origin || failed) {
    return (
      <span className={className} aria-hidden>
        <Boxes size={iconSize} strokeWidth={2.1} />
      </span>
    );
  }
  return (
    <span className={`${className} stremio-avatar--image`} aria-hidden>
      <img
        src={`${origin}/favicon.ico`}
        alt=""
        loading="lazy"
        decoding="async"
        referrerPolicy="no-referrer"
        onError={() => setFailed(true)}
      />
    </span>
  );
}


export function StremioPanel({ onBack }: { onBack: () => void }) {
  const [catalog, setCatalog] = useState<StremioCatalog | null>(null);
  const [detail, setDetail] = useState<StremioAddon | null>(null);
  const [contentAddon, setContentAddon] = useState<StremioAddon | null>(null);
  const [repoView, setRepoView] = useState('');
  const [showRepos, setShowRepos] = useState(false);
  const [repoUrl, setRepoUrl] = useState('');
  const [addonUrl, setAddonUrl] = useState('');
  const [visibleCount, setVisibleCount] = useState(PAGE_SIZE);
  const [typeFilter, setTypeFilter] = useState('');
  const { msg, setMsg, busy, run } = usePanelAction();
  const isDirect = repoView === DIRECT_REPO;

  useEffect(() => {
    /* eslint-disable react-hooks/set-state-in-effect */
    setVisibleCount(PAGE_SIZE);
    setTypeFilter('');
    /* eslint-enable react-hooks/set-state-in-effect */
  }, [repoView]);

  const load = useCallback(async () => {
    const data = await getStremioCatalog();
    setCatalog(data);
    return data;
  }, []);

  useEffect(() => {
    void run('读取失败', async () => {
      await load();
    });
  }, [load]);

  const addons = useMemo(() => {
    if (!catalog) return [];
    return [...catalog.addons].sort((a, b) => {
      if (Boolean(a.enabled) !== Boolean(b.enabled)) return a.enabled ? -1 : 1;
      return addonName(a).localeCompare(addonName(b));
    });
  }, [catalog]);

  const currentRepo = useMemo(
    () => catalog?.repositories.find((repo) => repo.url === repoView) || null,
    [catalog, repoView],
  );

  const directCount = useMemo(
    () => addons.filter((addon) => !addon.repository).length,
    [addons],
  );

  const repoAddons = useMemo(
    () =>
      isDirect
        ? addons.filter((addon) => !addon.repository)
        : addons.filter((addon) => addon.repository === repoView),
    [addons, isDirect, repoView],
  );

  /** 当前仓库的分类分布，按数量从多到少排列。 */
  const typeGroups = useMemo(() => {
    const counts = new Map<string, number>();
    repoAddons.forEach((addon) => {
      addonTypeGroups(addon).forEach((type) => {
        counts.set(type, (counts.get(type) || 0) + 1);
      });
    });
    return [...counts.entries()].sort(
      (a, b) => b[1] - a[1] || a[0].localeCompare(b[0]),
    );
  }, [repoAddons]);

  const filteredAddons = useMemo(
    () =>
      typeFilter
        ? repoAddons.filter((addon) => addonTypeGroups(addon).includes(typeFilter))
        : repoAddons,
    [repoAddons, typeFilter],
  );

  const shownAddons = useMemo(
    () => filteredAddons.slice(0, visibleCount),
    [filteredAddons, visibleCount],
  );

  async function toggle(addon: StremioAddon, enabled: boolean) {
    await run('操作失败', async () => {
      await setStremioAddonEnabled(addon.slug, enabled);
      setDetail((d) => (d && d.slug === addon.slug ? { ...d, enabled } : d));
      await load();
    });
  }

  function renderAddonRow(addon: StremioAddon) {
    const types = addonTypes(addon).slice(0, 4);
    return (
      <li key={addon.slug}>
        <button
          type="button"
          className="settings-nav stremio-addon"
          onClick={() => {
            setMsg('');
            setDetail(addon);
          }}
        >
          <AddonAvatar addon={addon} iconSize={20} className="stremio-addon-icon" />
          <span className="settings-nav__main">
            <span className="settings-nav__title">{addonName(addon)}</span>
            <span className="settings-nav__desc">
              {addon.manifest?.description || addon.manifest_url || ''}
            </span>
            {types.length ? (
              <span className="stremio-addon__types">
                {types.map((type) => (
                  <span key={type} className="stremio-addon__type">
                    {type}
                  </span>
                ))}
              </span>
            ) : null}
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
    );
  }

  if (contentAddon) {
    return (
      <AddonContent addon={contentAddon} onBack={() => setContentAddon(null)} />
    );
  }

  if (detail) {
    const manifest = detail.manifest || {};
    const types = addonTypes(detail);
    const title = addonName(detail);
    const subtitle = detail.slug;
    const desc = manifest.description || '';
    const installUrl = (detail.manifest_url || '').replace(/^https?:\/\//i, 'stremio://');
    const catalogCount = (manifest.catalogs || []).length;
    const canStream = (manifest.resources || []).some(
      (resource) => (typeof resource === 'string' ? resource : resource?.name) === 'stream',
    );
    return (
      <AppPush
        title={title}
        onBack={() => setDetail(null)}
        bodyClassName="stremio-page"
      >
        <div className="stremio-addon-hero">
          <AddonAvatar
            addon={detail}
            iconSize={24}
            className="stremio-addon-hero__icon"
          />
          <div className="stremio-addon-hero__main">
            <h2 className="stremio-hero__title">{title}</h2>
            <p className="stremio-hero__desc">{subtitle}</p>
            <div className="stremio-chips">
              <span
                className={`stremio-chip ${
                  detail.enabled !== false ? 'is-on' : 'is-off'
                }`}
              >
                {detail.enabled !== false ? '已启用' : '已停用'}
              </span>
              {manifest.version ? (
                <span className="stremio-chip">v{manifest.version}</span>
              ) : null}
              {types.slice(0, 4).map((type, index) => (
                <span key={`${type}-${index}`} className="stremio-chip">
                  {type}
                </span>
              ))}
            </div>
          </div>
        </div>

        {desc ? <p className="stremio-hero__note allow-select">{desc}</p> : null}

        {catalogCount > 0 || canStream ? (
          <>
            <p className="settings-group-label">内容</p>
            <ul className="settings-group">
              <li>
                <button
                  type="button"
                  className="settings-nav"
                  onClick={() => {
                    setMsg('');
                    setContentAddon(detail);
                  }}
                >
                  <span className="stremio-entry-icon" aria-hidden>
                    <LayoutGrid size={17} strokeWidth={2.2} />
                  </span>
                  <span className="settings-nav__main">
                    <span className="settings-nav__title">浏览插件内容</span>
                    <span className="settings-nav__desc">
                      {catalogCount > 0
                        ? `${catalogCount} 个目录，点条目可直接播放`
                        : '没有目录，片源会在影视页聚合'}
                    </span>
                  </span>
                  <ChevronRight
                    className="settings-nav__chev"
                    size={17}
                    strokeWidth={2.4}
                    aria-hidden
                  />
                </button>
              </li>
            </ul>
          </>
        ) : null}

        <p className="settings-group-label">配置</p>
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
              <span className="settings-kv__key">传输</span>
              <span className="settings-kv__val">{detail.transport || '—'}</span>
            </div>
          </li>
          <li>
            <div className="settings-kv">
              <span className="settings-kv__key">来源仓库</span>
              <span className="settings-kv__val allow-select">
                {detail.repository || '直接安装'}
              </span>
            </div>
          </li>
        </ul>

        <p className="settings-group-label">安装地址</p>
        <section className="app-section">
          <div className="app-section-body">
            {installUrl ? (
              <a className="stremio-url allow-select" href={installUrl}>
                {installUrl}
              </a>
            ) : (
              <div className="stremio-url allow-select">—</div>
            )}
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
            className="app-btn-secondary stremio-danger-btn"
            disabled={busy}
            onClick={() => {
              if (!window.confirm(`删除 addon「${title}」？`)) return;
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

  if (repoView) {
    return (
      <AppPush
        title={isDirect ? '直接安装' : currentRepo?.title || repoView}
        onBack={() => setRepoView('')}
        bodyClassName="stremio-page"
      >
        <div className={`stremio-repo-hero ${isDirect ? 'is-direct' : ''}`}>
          {isDirect ? (
            <span className="stremio-repo-hero__icon" aria-hidden>
              <Boxes size={24} strokeWidth={2} />
            </span>
          ) : (
            <RepoAvatar url={repoView} iconSize={24} className="stremio-repo-hero__icon" />
          )}
          <div className="stremio-repo-hero__main">
            <h2 className="stremio-hero__title">
              {isDirect ? '直接安装' : currentRepo?.title || repoView}
            </h2>
            <p className="stremio-hero__desc allow-select">
              {isDirect ? '不归属任何仓库的 addon' : repoView}
            </p>
            <div className="stremio-chips">
              <span className="stremio-chip">{repoAddons.length} 个 addon</span>
              {currentRepo?.error ? (
                <span className="stremio-chip is-bad">同步异常</span>
              ) : null}
            </div>
          </div>
        </div>

        {isDirect ? null : (
          <div className="stremio-hero-actions">
            <button
              type="button"
              className="app-btn-secondary"
              disabled={busy}
              onClick={() =>
                void run('刷新失败', async () => {
                  await refreshStremioRepository(repoView);
                  await load();
                  setMsg('已刷新');
                })
              }
            >
              <RefreshCw size={14} strokeWidth={2.2} /> 刷新
            </button>
            <button
              type="button"
              className="app-btn-secondary stremio-danger-btn"
              disabled={busy}
              onClick={() => {
                if (!window.confirm(`删除仓库「${currentRepo?.title || repoView}」？`)) return;
                void run('删除失败', async () => {
                  await deleteStremioRepository(repoView);
                  setRepoView('');
                  await load();
                  setMsg('已删除仓库');
                });
              }}
            >
              <Trash2 size={14} strokeWidth={2.2} /> 删除仓库
            </button>
          </div>
        )}

        {currentRepo?.error ? <AppMsg>{currentRepo.error}</AppMsg> : null}

        {typeGroups.length > 1 ? (
          <div className="stremio-filters" role="tablist" aria-label="按分类筛选">
            <button
              type="button"
              role="tab"
              aria-selected={!typeFilter}
              className={`stremio-filter${typeFilter ? '' : ' is-on'}`}
              onClick={() => {
                setTypeFilter('');
                setVisibleCount(PAGE_SIZE);
              }}
            >
              全部
              <span className="stremio-filter__count">{repoAddons.length}</span>
            </button>
            {typeGroups.map(([type, count]) => (
              <button
                key={type}
                type="button"
                role="tab"
                aria-selected={typeFilter === type}
                className={`stremio-filter${typeFilter === type ? ' is-on' : ''}`}
                onClick={() => {
                  setTypeFilter(type);
                  setVisibleCount(PAGE_SIZE);
                }}
              >
                {type}
                <span className="stremio-filter__count">{count}</span>
              </button>
            ))}
          </div>
        ) : null}

        {filteredAddons.length ? (
          <>
            <ul className="settings-group">{shownAddons.map(renderAddonRow)}</ul>
            {shownAddons.length < filteredAddons.length ? (
              <button
                type="button"
                className="stremio-more"
                disabled={busy}
                onClick={() => setVisibleCount((v) => v + PAGE_SIZE)}
              >
                加载更多（剩余 {filteredAddons.length - shownAddons.length}）
              </button>
            ) : (
              <p className="stremio-more__done">
                已显示全部 {filteredAddons.length} 个 addon
              </p>
            )}
          </>
        ) : (
          <div className="plugin-empty">
            <span className="plugin-empty__icon" aria-hidden>
              {isDirect ? (
                <Package size={22} strokeWidth={2.1} />
              ) : (
                <RefreshCw size={22} strokeWidth={2.1} />
              )}
            </span>
            <p className="plugin-empty__title">
              {isDirect ? '还没有直接安装的 addon' : '该仓库还没有 addon'}
            </p>
            <p className="plugin-empty__desc">
              {isDirect
                ? '回到 Stremio 插件库首页，点「添加仓库 / 直接安装」粘贴 manifest 地址即可安装。'
                : '点上方「刷新」重新拉取仓库索引，或检查仓库地址是否可用。'}
            </p>
          </div>
        )}
        {msg ? (
          <AppMsg allowSelect onDismiss={() => setMsg('')}>
            {msg}
          </AppMsg>
        ) : null}
      </AppPush>
    );
  }

  if (showRepos) {
    return (
      <AppPush
        title="添加与安装"
        onBack={() => setShowRepos(false)}
        bodyClassName="stremio-page"
      >
        <p className="settings-group-label">添加仓库</p>
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
          </div>
        </section>

        <div className="app-actions">
          <button
            type="button"
            className="app-btn-primary"
            style={{ flex: 1 }}
            disabled={busy || !repoUrl.trim()}
            onClick={() =>
              void run('添加失败', async () => {
                const result = await addStremioRepository(repoUrl.trim());
                setRepoUrl('');
                await load();
                setMsg(result.kind === 'addon' ? '已作为独立 addon 安装' : '仓库已添加');
              })
            }
          >
            <Plus size={15} strokeWidth={2.4} /> 添加仓库
          </button>
        </div>

        <p className="settings-group-label">直接安装 addon</p>
        <section className="app-section">
          <div className="app-section-body">
            <label className="app-field app-field--stack">
              <span className="app-label">安装地址</span>
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
          </div>
        </section>

        <div className="app-actions">
          <button
            type="button"
            className="app-btn-primary"
            style={{ flex: 1 }}
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
            <Plus size={15} strokeWidth={2.4} /> 安装 addon
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
    <AppPush title="Stremio 插件库" onBack={onBack} bodyClassName="stremio-page">
      <p className="settings-group-label">仓库</p>
      {catalog?.repositories.length || directCount ? (
        <ul className="settings-group">
          {catalog?.repositories.map((repo) => (
            <li key={repo.url}>
              <button
                type="button"
                className="settings-nav stremio-repo"
                onClick={() => {
                  setMsg('');
                  setRepoView(repo.url);
                }}
              >
                <RepoAvatar url={repo.url} iconSize={17} className="stremio-repo__icon" />
                <span className="settings-nav__main">
                  <span className="settings-nav__title">{repo.title || repo.url}</span>
                  <span className="settings-nav__desc allow-select">{repo.url}</span>
                </span>
                <span className="settings-nav__trail">
                  {repo.error ? (
                    <span className="settings-nav__status settings-nav__status--warn">
                      异常
                    </span>
                  ) : (
                    <span className="stremio-count">{repo.count || 0}</span>
                  )}
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
          {directCount ? (
            <li>
              <button
                type="button"
                className="settings-nav stremio-repo stremio-repo--direct"
                onClick={() => {
                  setMsg('');
                  setRepoView(DIRECT_REPO);
                }}
              >
                <span className="stremio-repo__icon" aria-hidden>
                  <Package size={17} strokeWidth={2.1} />
                </span>
                <span className="settings-nav__main">
                  <span className="settings-nav__title">直接安装</span>
                  <span className="settings-nav__desc">不归属仓库的 addon</span>
                </span>
                <span className="settings-nav__trail">
                  <span className="stremio-count">{directCount}</span>
                  <ChevronRight
                    className="settings-nav__chev"
                    size={17}
                    strokeWidth={2.4}
                    aria-hidden
                  />
                </span>
              </button>
            </li>
          ) : null}
        </ul>
      ) : (
        <div className="plugin-empty">
          <span className="plugin-empty__icon" aria-hidden>
            <Boxes size={22} strokeWidth={2.1} />
          </span>
          <p className="plugin-empty__title">还没有订阅仓库</p>
          <p className="plugin-empty__desc">
            点下方「添加仓库 / 直接安装」粘贴索引地址，即可批量导入 addon。
          </p>
        </div>
      )}

      <div className="app-actions">
        <button
          type="button"
          className="app-btn-primary"
          style={{ flex: 1 }}
          onClick={() => {
            setMsg('');
            setShowRepos(true);
          }}
        >
          <Plus size={15} strokeWidth={2.4} /> 添加仓库 / 直接安装
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
