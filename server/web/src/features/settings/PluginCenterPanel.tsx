'use client';

/**
 * 插件中心：市场 / 已安装 / 更新 / 仓库。
 *
 * 所有插件信息来自 Plugin Framework 的 Manifest：能力、运行时、配置表单都由
 * 插件自己声明，这里只渲染与操作，不再写死任何插件名称。
 *
 * 面板本身只负责编排，状态与动作在 usePluginCenter，子页面与卡片各自拆分。
 */

import { ArrowUpCircle, Boxes, Package, RefreshCw, Search, Store, X } from 'lucide-react';
import { AppMsg } from '@/components/ui/AppMsg';
import { AppPush } from '@/components/ui/AppPush';
import { ConfigEditor } from './plugins/pluginCenter/ConfigEditor';
import { PluginCard } from './plugins/pluginCenter/PluginCard';
import { PluginDetail } from './plugins/pluginCenter/PluginDetail';
import { RepoModal } from './plugins/pluginCenter/RepoModal';
import { usePluginCenter } from './plugins/pluginCenter/usePluginCenter';
import { GROUP_LABELS, runtimeLabel, type View } from './plugins/pluginCenter/types';
import type { PluginEntry } from '@/lib/api';

const VIEWS: { id: View; title: string; Icon: typeof Store }[] = [
  { id: 'installed', title: '已安装', Icon: Boxes },
  { id: 'market', title: '市场', Icon: Store },
];

export function PluginCenterPanel({ onBack }: { onBack: () => void }) {
  const {
    msg,
    setMsg,
    busy,
    isAdmin,
    view,
    setView,
    repositories,
    market,
    repoFilter,
    setRepoFilter,
    keyword,
    setKeyword,
    detail,
    setDetail,
    health,
    configId,
    setConfigId,
    configFields,
    configValues,
    setConfigValues,
    configSaved,
    logsId,
    setLogsId,
    logs,
    repoModalOpen,
    setRepoModalOpen,
    repoModalTab,
    setRepoModalTab,
    repoForm,
    setRepoForm,
    installed,
    installedById,
    updateById,
    installedGroups,
    marketAvailable,
    marketGroups,
    refreshStatus,
    openEntry,
    openConfig,
    openLogs,
    installFromMarket,
    updateOne,
    openExport,
    toggleProxy,
    toggleShortdrama,
    toggle,
    checkHealth,
    restartPluginAction,
    rollback,
    remove,
    saveRepo,
    refreshRepo,
    removeRepo,
    saveConfig,
    refreshLogs,
  } = usePluginCenter();

  const views = isAdmin ? VIEWS : VIEWS.filter((item) => item.id === 'installed');

  // -------------------------------------------------------------------------
  // 子页面：配置
  // -------------------------------------------------------------------------
  if (configId) {
    const entry = installedById[configId] || detail?.entry;
    return (
      <AppPush title={entry?.name || '插件配置'} onBack={() => setConfigId('')} bodyClassName="plugin-fw-page">
        <ConfigEditor
          fields={configFields}
          values={configValues}
          savedKeys={configSaved}
          onChange={(key, value) => setConfigValues((prev) => ({ ...prev, [key]: value }))}
        />
        <div className="app-actions">
          <button
            type="button"
            className="app-btn-primary"
            style={{ flex: 1 }}
            disabled={busy}
            onClick={() => void saveConfig(configId)}
          >
            保存配置
          </button>
        </div>
        {msg ? <AppMsg allowSelect onDismiss={() => setMsg('')}>{msg}</AppMsg> : null}
      </AppPush>
    );
  }

  // -------------------------------------------------------------------------
  // 子页面：日志
  // -------------------------------------------------------------------------
  if (logsId) {
    const entry = installedById[logsId] || detail?.entry;
    return (
      <AppPush title={`${entry?.name || logsId} · 日志`} onBack={() => setLogsId('')} bodyClassName="plugin-fw-page">
        <div className="plugin-fw-logs allow-select">
          {logs.length ? logs.map((line, index) => <div key={`${index}-${line}`}>{line}</div>) : '暂无日志'}
        </div>
        <div className="app-actions">
          <button
            type="button"
            className="app-btn-secondary"
            style={{ flex: 1 }}
            disabled={busy}
            onClick={() => void refreshLogs(logsId)}
          >
            刷新日志
          </button>
        </div>
        {msg ? <AppMsg allowSelect onDismiss={() => setMsg('')}>{msg}</AppMsg> : null}
      </AppPush>
    );
  }

  // -------------------------------------------------------------------------
  // 子页面：插件详情
  // -------------------------------------------------------------------------
  if (detail) {
    const entry = installedById[detail.entry.id] || detail.entry;
    const marketEntry = detail.market;
    const isInstalled = Boolean(installedById[entry.id]);
    const latest =
      updateById[entry.id]?.latest_version ||
      (marketEntry?.update_available ? marketEntry.version : '') ||
      '';
    return (
      <PluginDetail
        entry={entry}
        marketEntry={marketEntry}
        repository={detail.repository}
        isInstalled={isInstalled}
        latest={latest}
        health={health}
        busy={busy}
        readOnly={!isAdmin}
        msg={msg}
        setMsg={setMsg}
        onBack={() => setDetail(null)}
        onCheckHealth={() => void checkHealth(entry)}
        onOpenConfig={() => void openConfig(entry)}
        onOpenExport={() => openExport(entry)}
        onOpenLogs={() => void openLogs(entry)}
        onRestart={() => void restartPluginAction(entry)}
        onInstall={() => {
          if (marketEntry) void installFromMarket(marketEntry);
        }}
        onUpdate={() => void updateOne(entry)}
        onRollback={() => void rollback(entry)}
        onRemove={() => void remove(entry)}
        onToggle={(v) => void toggle(entry, v)}
        onToggleProxy={(v) => void toggleProxy(entry, v)}
        onToggleShortdrama={(v) => void toggleShortdrama(entry, v)}
      />
    );
  }

  // -------------------------------------------------------------------------
  // 主页面
  // -------------------------------------------------------------------------
  const counts: Record<View, number> = {
    market: marketAvailable.length,
    installed: installed.length,
  };

  return (
    <>
      <AppPush
        title="插件中心"
        onBack={onBack}
        bodyClassName="plugin-fw-page"
        right={
          <div className="plugin-fw-top-actions">
            <button
              type="button"
              className="plugin-fw-icon-btn"
              aria-label="刷新插件状态"
              title="刷新插件状态"
              disabled={busy}
              onClick={() => void refreshStatus()}
            >
              <RefreshCw
                size={16}
                strokeWidth={2.2}
                className={busy ? 'is-spinning' : undefined}
                aria-hidden
              />
            </button>
            {view === 'market' ? (
              <button
                type="button"
                className="plugin-fw-repo-trigger"
                onClick={() => setRepoModalOpen(true)}
              >
                <Package size={15} strokeWidth={2.3} aria-hidden /> 仓库
              </button>
            ) : null}
          </div>
        }
      >
        <div className="stremio-filters" role="tablist" aria-label="插件中心">
          {views.map(({ id, title, Icon }) => (
            <button
              key={id}
              type="button"
              role="tab"
              aria-selected={view === id}
              className={`stremio-filter${view === id ? ' is-on' : ''}`}
              onClick={() => {
                setView(id);
                setMsg('');
              }}
            >
              <Icon size={14} strokeWidth={2.2} aria-hidden /> {title}
              <span className="stremio-filter__count">{counts[id]}</span>
            </button>
          ))}
        </div>

        {view === 'market' ? (
          <>
            <div className="plugin-fw-market-head">
              {repositories.length > 1 ? (
                <div
                  className="stremio-filters plugin-fw-market-head__tabs"
                  role="tablist"
                  aria-label="插件仓库"
                >
                  <button
                    type="button"
                    role="tab"
                    aria-selected={!repoFilter}
                    className={`stremio-filter${repoFilter ? '' : ' is-on'}`}
                    onClick={() => setRepoFilter('')}
                  >
                    全部
                  </button>
                  {repositories.map((repo) => (
                    <button
                      key={repo.id}
                      type="button"
                      role="tab"
                      aria-selected={repoFilter === repo.id}
                      className={`stremio-filter${repoFilter === repo.id ? ' is-on' : ''}`}
                      onClick={() => setRepoFilter(repo.id)}
                    >
                      {repo.name}
                    </button>
                  ))}
                </div>
              ) : (
                <span className="plugin-fw-market-head__lead">全部插件</span>
              )}

              <label className="plugin-fw-search">
                <Search size={15} strokeWidth={2.3} aria-hidden />
                <input
                  className="allow-select"
                  placeholder="搜索插件"
                  aria-label="搜索插件"
                  value={keyword}
                  onChange={(e) => setKeyword(e.target.value)}
                  autoCapitalize="off"
                  spellCheck={false}
                />
                {keyword ? (
                  <button
                    type="button"
                    className="plugin-fw-search__clear"
                    aria-label="清空搜索"
                    onClick={() => setKeyword('')}
                  >
                    <X size={13} strokeWidth={2.4} aria-hidden />
                  </button>
                ) : null}
              </label>
            </div>

            {marketGroups.length ? (
              <div className="plugin-fw-groups">
                {marketGroups.map(([group, rows]) => (
                  <section key={group} className="plugin-fw-group">
                    <div className="plugin-fw-group__head">
                      <span className="plugin-fw-group__title">
                        {GROUP_LABELS[group] || GROUP_LABELS.other}
                      </span>
                      <span className="plugin-fw-group__count">{rows.length}</span>
                    </div>
                    <ul className="plugin-fw-cards">
                      {rows.map((item) => {
                        const merged: PluginEntry = {
                          ...item,
                          enabled: false,
                          running: false,
                          installed_version: '',
                        };
                        return (
                          <PluginCard
                            key={`${item.repository}:${item.id}`}
                            entry={merged}
                            hint={`v${item.version}`}
                            onClick={() => openEntry(merged, item.repository, item)}
                            tone="mute"
                          />
                        );
                      })}
                    </ul>
                  </section>
                ))}
              </div>
            ) : (
              <div className="plugin-empty">
                <span className="plugin-empty__icon" aria-hidden>
                  <Store size={22} strokeWidth={2.1} />
                </span>
                <p className="plugin-empty__title">
                  {keyword
                    ? '没有匹配的插件'
                    : market && market.plugins.length
                      ? '仓库里的插件都已安装'
                      : '市场里还没有插件'}
                </p>
                <p className="plugin-empty__desc">
                  {keyword
                    ? '换个关键词试试。'
                    : market && market.plugins.length
                      ? '卸载后插件会重新出现在市场。'
                      : '点击右上角「仓库」添加 GitHub 插件仓库，或刷新已有仓库索引。'}
                </p>
              </div>
            )}
            {market?.errors.map((item) => (
              <p key={item.repository} className="stremio-hero__note allow-select">
                {item.repository}：{item.error}
              </p>
            ))}
          </>
        ) : null}

        {view === 'installed' ? (
          installed.length ? (
            <div className="plugin-fw-groups">
              {installedGroups.map(([group, rows]) => (
                <section key={group} className="plugin-fw-group">
                  <div className="plugin-fw-group__head">
                    <span className="plugin-fw-group__title">
                      {GROUP_LABELS[group] || GROUP_LABELS.other}
                    </span>
                    <span className="plugin-fw-group__count">{rows.length}</span>
                  </div>
                  <ul className="plugin-fw-cards">
                    {rows.map((entry) => {
                      const update = updateById[entry.id];
                      return (
                        <PluginCard
                          key={entry.id}
                          entry={entry}
                          hint={
                            update
                              ? `v${update.installed_version} → v${update.latest_version}`
                              : `${entry.installed_version || entry.version || '—'} · ${runtimeLabel(entry)}`
                          }
                          onClick={() => openEntry(entry)}
                          action={
                            update ? (
                              <button
                                type="button"
                                className="plugin-fw-update-btn"
                                aria-label="更新插件"
                                title="更新插件"
                                disabled={busy}
                                onClick={() => void updateOne(entry)}
                              >
                                <ArrowUpCircle size={13} strokeWidth={2.4} aria-hidden />
                              </button>
                            ) : undefined
                          }
                        />
                      );
                    })}
                  </ul>
                </section>
              ))}
            </div>
          ) : (
            <div className="plugin-empty">
              <span className="plugin-empty__icon" aria-hidden>
                <Boxes size={22} strokeWidth={2.1} />
              </span>
              <p className="plugin-empty__title">还没有安装插件</p>
              <p className="plugin-empty__desc">
                {isAdmin ? '到「市场」选择一个插件安装。' : '请联系管理员安装插件。'}
              </p>
            </div>
          )
        ) : null}

        {msg ? <AppMsg allowSelect onDismiss={() => setMsg('')}>{msg}</AppMsg> : null}
      </AppPush>
      <RepoModal
        open={repoModalOpen}
        onClose={() => setRepoModalOpen(false)}
        tab={repoModalTab}
        onTabChange={setRepoModalTab}
        form={repoForm}
        onFormChange={setRepoForm}
        repositories={repositories}
        busy={busy}
        onSave={() => void saveRepo()}
        onRefresh={(repo) => void refreshRepo(repo)}
        onRemove={(repo) => void removeRepo(repo)}
      />
    </>
  );
}
