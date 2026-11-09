'use client';

import {
  ArrowUpCircle,
  Download,
  FileText,
  HeartPulse,
  RefreshCw,
  RotateCcw,
  Settings2,
  Trash2,
} from 'lucide-react';
import { AppMsg } from '@/components/ui/AppMsg';
import { AppPush } from '@/components/ui/AppPush';
import { Switch } from '@/components/ui/switch';
import type { PluginEntry, PluginMarketEntry } from '@/lib/api';
import { PluginIcon } from './PluginIcon';
import {
  capabilityFeatures,
  categoryLabel,
  pluginGroup,
  runtimeLabel,
  statusChip,
  statusText,
} from './types';

export function PluginDetail({
  entry,
  marketEntry,
  repository,
  isInstalled,
  latest,
  health,
  busy,
  readOnly = false,
  msg,
  setMsg,
  onBack,
  onCheckHealth,
  onOpenConfig,
  onOpenExport,
  onOpenLogs,
  onRestart,
  onInstall,
  onUpdate,
  onRollback,
  onRemove,
  onToggle,
  onToggleProxy,
  onToggleShortdrama,
}: {
  entry: PluginEntry;
  marketEntry?: PluginMarketEntry;
  repository?: string;
  isInstalled: boolean;
  latest: string;
  health: string;
  busy: boolean;
  readOnly?: boolean;
  msg: string;
  setMsg: (next: string) => void;
  onBack: () => void;
  onCheckHealth: () => void;
  onOpenConfig: () => void;
  onOpenExport: () => void;
  onOpenLogs: () => void;
  onRestart: () => void;
  onInstall: () => void;
  onUpdate: () => void;
  onRollback: () => void;
  onRemove: () => void;
  onToggle: (enabled: boolean) => void;
  onToggleProxy: (enabled: boolean) => void;
  onToggleShortdrama: (enabled: boolean) => void;
}) {
  const version = entry.installed_version || entry.version || marketEntry?.version || '';
  const capabilities = entry.capabilities || [];
  const widgetModules = entry.widget_meta?.modules || [];
  const dramaVisible = pluginGroup(entry.category) === 'shortdrama';
  const dramaShown = entry.show_in_drama ?? entry.id === 'rexhub.hongguo.video';
  return (
    <>
      <AppPush title={entry.name} onBack={onBack} bodyClassName="plugin-fw-page">
        <div className="stremio-addon-hero">
          <PluginIcon entry={entry} hero />
          <div className="stremio-addon-hero__main">
            <div className="stremio-hero__heading">
              <h2 className="stremio-hero__title">{entry.name}</h2>
              {version ? <span className="stremio-chip stremio-hero__version">v{version}</span> : null}
            </div>
            <div className="stremio-chips">
              <span className={`stremio-chip ${isInstalled ? statusChip(entry) : ''}`}>
                {isInstalled ? statusText(entry) : '未安装'}
              </span>
              {latest ? <span className="stremio-chip">最新 v{latest}</span> : null}
              <span className="stremio-chip">{runtimeLabel(entry)}</span>
              {entry.protocol ? <span className="stremio-chip">{entry.protocol}</span> : null}
              {entry.category ? (
                <span className="stremio-chip">{categoryLabel(entry.category)}</span>
              ) : null}
            </div>
          </div>
        </div>

        {entry.description ? <p className="stremio-hero__note allow-select">{entry.description}</p> : null}
        {entry.error ? <p className="stremio-hero__note allow-select">错误：{entry.error}</p> : null}
        {health ? <p className="stremio-hero__note allow-select">{health}</p> : null}

        {!isInstalled ? (
          <>
            <p className="settings-group-label">来源</p>
            <ul className="settings-group">
              <li>
                <div className="settings-kv">
                  <span className="settings-kv__key">仓库</span>
                  <span className="settings-kv__val allow-select">
                    {marketEntry?.repository_url || repository || '—'}
                  </span>
                </div>
              </li>
              <li>
                <div className="settings-kv">
                  <span className="settings-kv__key">声明能力</span>
                  <span className="settings-kv__val">
                    {capabilityFeatures(capabilities).join('、') || '无'}
                  </span>
                </div>
              </li>
            </ul>
            <div className="app-actions">
              {readOnly ? (
                <p className="app-hint">仅管理员可安装插件。</p>
              ) : (
                <button
                  type="button"
                  className="app-btn-primary"
                  style={{ flex: 1 }}
                  disabled={busy || !marketEntry}
                  onClick={() => {
                    if (marketEntry) onInstall();
                  }}
                >
                  <Download size={15} strokeWidth={2.3} /> 安装
                </button>
              )}
            </div>
          </>
        ) : (
          <>
            <p className="settings-group-label">能力与运行时</p>
            <ul className="settings-group">
              <li>
                <div className="settings-kv">
                  <span className="settings-kv__key">能力</span>
                  <span className="settings-kv__val">
                    {capabilityFeatures(capabilities).join('、') || '未声明'}
                  </span>
                </div>
              </li>
              <li>
                <div className="settings-kv">
                  <span className="settings-kv__key">运行时</span>
                  <span className="settings-kv__val">
                    {runtimeLabel(entry)}
                    {entry.port ? ` · 端口 ${entry.port}` : ''}
                  </span>
                </div>
              </li>
              <li>
                <div className="settings-kv">
                  <span className="settings-kv__key">启用</span>
                  {readOnly ? (
                    <span className="settings-kv__val">
                      {entry.enabled ? '已启用' : '已停用'}
                    </span>
                  ) : (
                    <Switch
                      checked={Boolean(entry.enabled)}
                      disabled={busy}
                      onCheckedChange={onToggle}
                    />
                  )}
                </div>
              </li>
              {dramaVisible ? (
                <li>
                  <div className="settings-kv">
                    <span className="settings-kv__key">短剧页显示</span>
                    {readOnly ? (
                      <span className="settings-kv__val">{dramaShown ? '已开启' : '已关闭'}</span>
                    ) : (
                      <Switch
                        checked={Boolean(dramaShown)}
                        disabled={busy}
                        onCheckedChange={onToggleShortdrama}
                      />
                    )}
                  </div>
                </li>
              ) : null}
              {entry.runtime?.type !== 'http' ? (
                <li>
                  <div className="settings-kv">
                    <span className="settings-kv__key">运行时走代理</span>
                    {readOnly ? (
                      <span className="settings-kv__val">{entry.proxy ? '已开启' : '已关闭'}</span>
                    ) : (
                      <Switch
                        checked={Boolean(entry.proxy)}
                        disabled={busy}
                        onCheckedChange={onToggleProxy}
                      />
                    )}
                  </div>
                </li>
              ) : null}
            </ul>
            {entry.runtime?.type !== 'http' ? (
              <p className="app-hint">
                {entry.proxy_available === false
                  ? '全局代理未启用，请先在「设置 → 网络代理」中开启代理。'
                  : '开启后该插件自身的出站请求使用全局代理地址，其他插件不受影响。'}
              </p>
            ) : null}

            {widgetModules.length ? (
              <>
                <p className="settings-group-label">模块</p>
                <ul className="settings-group">
                  {widgetModules.map((module) => (
                    <li key={module.id}>
                      <div className="settings-kv">
                        <span className="settings-kv__key">{module.title || module.id}</span>
                        <span className="settings-kv__val">
                          {module.id}
                          {module.type ? ` · ${module.type}` : ''}
                        </span>
                      </div>
                    </li>
                  ))}
                  {entry.widget_meta?.search ? (
                    <li>
                      <div className="settings-kv">
                        <span className="settings-kv__key">
                          {entry.widget_meta.search.title || '搜索'}
                        </span>
                        <span className="settings-kv__val">search</span>
                      </div>
                    </li>
                  ) : null}
                </ul>
              </>
            ) : null}

            {readOnly ? (
              <p className="app-hint">仅管理员可管理插件，当前为只读视图。</p>
            ) : null}

            {!readOnly ? (
              <>
                <p className="settings-group-label">操作</p>
                <ul className="settings-group">
                  <li>
                    <button type="button" className="settings-nav" onClick={onCheckHealth}>
                      <span className="settings-nav__icon settings-nav__icon--teal" aria-hidden>
                        <HeartPulse size={17} strokeWidth={2.2} />
                      </span>
                      <span className="settings-nav__main">
                        <span className="settings-nav__title">健康检查</span>
                        <span className="settings-nav__desc">探测插件当前是否可达</span>
                      </span>
                    </button>
                  </li>
                  <li>
                    <button type="button" className="settings-nav" onClick={onOpenConfig}>
                      <span className="settings-nav__icon settings-nav__icon--blue" aria-hidden>
                        <Settings2 size={17} strokeWidth={2.2} />
                      </span>
                      <span className="settings-nav__main">
                        <span className="settings-nav__title">配置</span>
                        <span className="settings-nav__desc">按插件声明的表单填写</span>
                      </span>
                    </button>
                  </li>
                  <li>
                    <button type="button" className="settings-nav" onClick={onOpenExport}>
                      <span className="settings-nav__icon settings-nav__icon--green" aria-hidden>
                        <Download size={17} strokeWidth={2.2} />
                      </span>
                      <span className="settings-nav__main">
                        <span className="settings-nav__title">导出 JS 文件</span>
                        <span className="settings-nav__desc">
                          {entry.protocol === 'widget-js'
                            ? '完整导出原始 JS，App 可直接使用'
                            : entry.runtime?.type === 'http'
                              ? '生成可直接访问插件地址的 JS'
                              : '地址留空，App 加载后填写，由服务端代理转发'}
                        </span>
                      </span>
                    </button>
                  </li>
                  <li>
                    <button type="button" className="settings-nav" onClick={onOpenLogs}>
                      <span className="settings-nav__icon settings-nav__icon--indigo" aria-hidden>
                        <FileText size={17} strokeWidth={2.2} />
                      </span>
                      <span className="settings-nav__main">
                        <span className="settings-nav__title">日志</span>
                        <span className="settings-nav__desc">查看最近 200 行运行日志</span>
                      </span>
                    </button>
                  </li>
                  <li>
                    <button type="button" className="settings-nav" onClick={onRestart}>
                      <span className="settings-nav__icon settings-nav__icon--orange" aria-hidden>
                        <RefreshCw size={17} strokeWidth={2.2} />
                      </span>
                      <span className="settings-nav__main">
                        <span className="settings-nav__title">重启</span>
                        <span className="settings-nav__desc">重新拉起插件进程</span>
                      </span>
                    </button>
                  </li>
                </ul>

                {latest ? (
                  <div className="app-actions">
                    <button
                      type="button"
                      className="app-btn-primary"
                      style={{ flex: 1 }}
                      disabled={busy}
                      onClick={onUpdate}
                    >
                      <ArrowUpCircle size={15} strokeWidth={2.3} /> 更新到 v{latest}
                    </button>
                  </div>
                ) : null}

                <div className="app-actions">
                  <button
                    type="button"
                    className="app-btn-secondary"
                    style={{ flex: 1 }}
                    disabled={busy}
                    onClick={onRollback}
                  >
                    <RotateCcw size={15} strokeWidth={2.3} /> 回滚
                  </button>
                  <button
                    type="button"
                    className="app-btn-secondary"
                    style={{ flex: 1 }}
                    disabled={busy}
                    onClick={onRemove}
                  >
                    <Trash2 size={15} strokeWidth={2.3} /> 卸载
                  </button>
                </div>
              </>
            ) : null}
          </>
        )}
        {msg ? <AppMsg allowSelect onDismiss={() => setMsg('')}>{msg}</AppMsg> : null}
      </AppPush>
    </>
  );
}
