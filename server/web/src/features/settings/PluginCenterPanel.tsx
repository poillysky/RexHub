'use client';

/**
 * 插件中心：市场 / 已安装 / 更新 / 仓库。
 *
 * 所有插件信息来自 Plugin Framework 的 Manifest：能力、运行时、配置表单都由
 * 插件自己声明，这里只渲染与操作，不再写死任何插件名称。
 */

import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react';
import {
  ArrowUpCircle,
  Boxes,
  Download,
  FileText,
  HeartPulse,
  Package,
  RefreshCw,
  RotateCcw,
  Search,
  Settings2,
  Store,
  Trash2,
  X,
} from 'lucide-react';
import { AppPush } from '@/components/ui/AppPush';
import { AppCenterModal } from '@/components/ui/AppCenterModal';
import { AppMsg } from '@/components/ui/AppMsg';
import { SoftImg } from '@/components/SoftImg';
import { Switch } from '@/components/ui/switch';
import { usePanelAction, errorText } from '@/hooks/usePanelAction';
import {
  API_BASE,
  addPluginRepository,
  deletePluginRepository,
  disablePlugin,
  enablePlugin,
  exportPluginJs,
  getPluginConfig,
  getPluginHealth,
  getPluginLogs,
  getPluginMarket,
  getPluginOverview,
  getPluginUpdates,
  installPlugin,
  refreshPluginRepository,
  restartPlugin,
  rollbackPlugin,
  savePluginConfig,
  savePluginProxy,
  savePluginShortdrama,
  uninstallPlugin,
  updatePlugin,
  type PluginConfigField,
  type PluginEntry,
  type PluginFrameworkRepository,
  type PluginMarket,
  type PluginMarketEntry,
  type PluginOverview,
  type PluginUpdate,
} from '@/lib/api';

type View = 'market' | 'installed';
type Detail = { entry: PluginEntry; repository?: string; market?: PluginMarketEntry };

const VIEWS: { id: View; title: string; Icon: typeof Store }[] = [
  { id: 'installed', title: '已安装', Icon: Boxes },
  { id: 'market', title: '市场', Icon: Store },
];

function runtimeLabel(entry: PluginEntry) {
  const engine = entry.runtime?.engine;
  if (engine === 'widget-js') return 'Widget JS';
  if (engine === 'python') return 'Python 进程';
  if (engine === 'process') return '独立进程';
  const type = entry.runtime?.type || 'isolated';
  if (type === 'http') return '外部 HTTP';
  if (type === 'shared') return '共享运行时';
  return '独立进程';
}

function statusText(entry: PluginEntry) {
  if (entry.error) return '异常';
  if (!entry.enabled) return '已停用';
  return entry.running ? '运行中' : '未运行';
}

function statusTone(entry: PluginEntry) {
  if (entry.error) return 'error';
  if (!entry.enabled) return 'mute';
  return entry.running ? 'ok' : 'warn';
}

function statusChip(entry: PluginEntry) {
  if (entry.error) return 'is-bad';
  if (!entry.enabled) return 'is-off';
  return entry.running ? 'is-on' : 'is-warn';
}

const PLUGIN_GROUPS = ['video', 'shortdrama', 'studio', 'subtitle', 'danmaku', 'other'] as const;

const GROUP_LABELS: Record<string, string> = {
  video: '影视',
  shortdrama: '短剧',
  studio: '片商',
  subtitle: '字幕',
  danmaku: '弹幕',
  other: '其他',
};

function pluginGroup(category?: string) {
  const key = (category || '').toLowerCase();
  if (key === 'shortdrama') return 'shortdrama';
  if (key === 'subtitle') return 'subtitle';
  if (key === 'danmaku') return 'danmaku';
  if (key === 'studio' || key === 'provider') return 'studio';
  if (['video', 'resource', 'playback', 'metadata', 'cloud'].includes(key)) return 'video';
  return 'other';
}

function categoryLabel(category?: string) {
  return GROUP_LABELS[pluginGroup(category)] || GROUP_LABELS.other;
}

function categoryRank(category?: string) {
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

function capabilityFeatures(capabilities: string[]) {
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

/** 已安装插件才有可用的 logo 接口；市场里未安装的插件继续用分类图标 */
function pluginLogo(entry: PluginEntry): string {
  if (!entry.install_path) return '';
  const raw = String(entry.ui?.shortdrama?.logo || '').trim();
  if (!raw) return '';
  if (raw.startsWith('/') && !raw.startsWith('//') && !raw.startsWith('/api/')) {
    return `${API_BASE}/v1/plugins/${encodeURIComponent(entry.id)}/media?path=${encodeURIComponent(raw)}`;
  }
  return raw;
}

function PluginIcon({ entry, hero = false }: { entry: PluginEntry; hero?: boolean }) {
  const logo = pluginLogo(entry);
  const [broken, setBroken] = useState(false);
  const base = hero
    ? 'settings-nav__icon stremio-addon-hero__icon'
    : 'settings-nav__icon settings-nav__icon--orange';

  useEffect(() => {
    setBroken(false);
  }, [logo]);

  // 有品牌 logo 时用真实图标，去掉底色/阴影，尺寸由容器决定
  if (logo && !broken) {
    return (
      <span className={`${base} plugin-fw-logo`} aria-hidden>
        <SoftImg
          className="plugin-fw-logo__img"
          src={logo}
          loading="lazy"
          onError={() => setBroken(true)}
        />
      </span>
    );
  }

  return (
    <span className={base} aria-hidden>
      {hero ? (
        <Package size={24} strokeWidth={2.1} />
      ) : entry.category === 'resource' ? (
        <Download size={17} strokeWidth={2.2} />
      ) : entry.category === 'subtitle' ? (
        <FileText size={17} strokeWidth={2.2} />
      ) : (
        <Package size={17} strokeWidth={2.2} />
      )}
    </span>
  );
}

function PluginCard({
  entry,
  hint,
  onClick,
  action,
  tone,
}: {
  entry: PluginEntry;
  hint: string;
  onClick: () => void;
  action?: ReactNode;
  tone?: string;
}) {
  return (
    <li className={action ? 'plugin-fw-card has-action' : 'plugin-fw-card'}>
      <button type="button" className="plugin-fw-card__main" onClick={onClick}>
        <span className="plugin-fw-card__icon">
          <PluginIcon entry={entry} />
        </span>
        <span className="plugin-fw-card__body">
          <span className="plugin-fw-card__head">
            <span
              className={`plugin-fw-card__dot is-${tone || statusTone(entry)}`}
              aria-hidden
            />
            <span className="plugin-fw-card__name">{entry.name}</span>
          </span>
          <span className="plugin-fw-card__desc">{hint}</span>
        </span>
      </button>
      {action ? <span className="plugin-fw-card__action">{action}</span> : null}
    </li>
  );
}

function ConfigEditor({
  fields,
  values,
  onChange,
}: {
  fields: PluginConfigField[];
  values: Record<string, string>;
  onChange: (key: string, value: string) => void;
}) {
  if (!fields.length) {
    return <p className="stremio-hero__note">该插件没有声明配置项。</p>;
  }
  return (
    <section className="app-section">
      <div className="app-section-body">
        {fields.map((field) => {
          const value = values[field.key] ?? field.default ?? '';
          if (field.type === 'boolean') {
            return (
              <div key={field.key} className="settings-kv">
                <span className="settings-kv__key">{field.title}</span>
                <Switch
                  checked={value === 'true'}
                  onCheckedChange={(v) => onChange(field.key, v ? 'true' : 'false')}
                />
              </div>
            );
          }
          if (field.type === 'select') {
            return (
              <label key={field.key} className="app-field app-field--stack">
                <span className="app-label">{field.title}</span>
                <select
                  className="allow-select"
                  value={value}
                  onChange={(e) => onChange(field.key, e.target.value)}
                >
                  <option value="">未设置</option>
                  {(field.options || []).map((option) => (
                    <option key={option.value} value={option.value}>
                      {option.label}
                    </option>
                  ))}
                </select>
                {field.description ? (
                  <span className="app-hint">{field.description}</span>
                ) : null}
              </label>
            );
          }
          if (field.type === 'textarea') {
            return (
              <label key={field.key} className="app-field app-field--stack">
                <span className="app-label">{field.title}</span>
                <textarea
                  className="allow-select"
                  rows={3}
                  value={value}
                  onChange={(e) => onChange(field.key, e.target.value)}
                />
                {field.description ? (
                  <span className="app-hint">{field.description}</span>
                ) : null}
              </label>
            );
          }
          return (
            <label key={field.key} className="app-field app-field--stack">
              <span className="app-label">{field.title}</span>
              <input
                className="allow-select"
                type={field.type === 'password' ? 'password' : field.type === 'number' ? 'number' : 'text'}
                placeholder={field.required ? '必填' : '可选'}
                value={value}
                onChange={(e) => onChange(field.key, e.target.value)}
                autoCapitalize="off"
                spellCheck={false}
              />
              {field.description ? (
                <span className="app-hint">{field.description}</span>
              ) : null}
            </label>
          );
        })}
      </div>
    </section>
  );
}

export function PluginCenterPanel({ onBack }: { onBack: () => void }) {
  const { msg, setMsg, busy, run } = usePanelAction();
  const [view, setView] = useState<View>('installed');
  const [overview, setOverview] = useState<PluginOverview | null>(null);
  const [repositories, setRepositories] = useState<PluginFrameworkRepository[]>([]);
  const [updates, setUpdates] = useState<PluginUpdate[]>([]);
  const [market, setMarket] = useState<PluginMarket | null>(null);
  const [repoFilter, setRepoFilter] = useState('');
  const [keyword, setKeyword] = useState('');
  const [detail, setDetail] = useState<Detail | null>(null);
  const [health, setHealth] = useState('');
  const [configId, setConfigId] = useState('');
  const [configFields, setConfigFields] = useState<PluginConfigField[]>([]);
  const [configValues, setConfigValues] = useState<Record<string, string>>({});
  const [logsId, setLogsId] = useState('');
  const [logs, setLogs] = useState<string[]>([]);
  const [repoModalOpen, setRepoModalOpen] = useState(false);
  const [repoModalTab, setRepoModalTab] = useState<'add' | 'list'>('list');
  const [repoForm, setRepoForm] = useState({ url: '', name: '', index_path: 'repository.json', branch: '' });

  const installed = useMemo(() => overview?.installed || [], [overview]);

  const loadOverview = useCallback(async () => {
    const [data, nextUpdates] = await Promise.all([getPluginOverview(), getPluginUpdates()]);
    setOverview(data);
    setRepositories(data.repositories);
    setUpdates(nextUpdates.items);
  }, []);

  const loadMarket = useCallback(async () => {
    setMarket(await getPluginMarket(repoFilter));
  }, [repoFilter]);

  useEffect(() => {
    /* eslint-disable react-hooks/set-state-in-effect */
    void loadOverview().catch((e) => setMsg(errorText(e, '插件列表读取失败')));
    /* eslint-enable react-hooks/set-state-in-effect */
  }, [loadOverview, setMsg]);

  useEffect(() => {
    if (view !== 'market' || detail || configId || logsId) return;
    void run('插件市场读取失败', async () => {
      await loadMarket();
    });
  }, [view, repoFilter, detail, configId, logsId, loadMarket, run]);

  const installedById = useMemo(
    () => Object.fromEntries(installed.map((item) => [item.id, item])) as Record<string, PluginEntry>,
    [installed],
  );
  const updateById = useMemo(
    () => Object.fromEntries(updates.map((item) => [item.id, item])),
    [updates],
  );

  const installedGroups = useMemo(() => {
    const groups = new Map<string, PluginEntry[]>();
    for (const entry of installed) {
      const key = pluginGroup(entry.category);
      const list = groups.get(key) || [];
      list.push(entry);
      groups.set(key, list);
    }
    return Array.from(groups.entries()).sort(
      ([left], [right]) => categoryRank(left) - categoryRank(right),
    );
  }, [installed]);

  /* 市场只展示未安装插件；卸载后重新回到市场 */
  const marketAvailable = useMemo(
    () => (market?.plugins || []).filter((item) => !item.installed),
    [market],
  );

  const marketRows = useMemo(() => {
    const text = keyword.trim().toLowerCase();
    if (!text) return marketAvailable;
    return marketAvailable.filter((item) =>
      `${item.id} ${item.name} ${item.description || ''}`.toLowerCase().includes(text),
    );
  }, [marketAvailable, keyword]);

  const marketGroups = useMemo(() => {
    const groups = new Map<string, PluginMarketEntry[]>();
    for (const item of marketRows) {
      const key = pluginGroup(item.category);
      const list = groups.get(key) || [];
      list.push(item);
      groups.set(key, list);
    }
    return Array.from(groups.entries()).sort(
      ([left], [right]) => categoryRank(left) - categoryRank(right),
    );
  }, [marketRows]);

  const refreshAll = useCallback(async () => {
    await loadOverview();
    if (view === 'market') await loadMarket();
  }, [loadOverview, loadMarket, view]);

  const refreshStatus = useCallback(async () => {
    await run('刷新失败', async () => {
      await refreshAll();
      setMsg('已刷新插件状态');
    });
  }, [refreshAll, run, setMsg]);

  /** 从市场或已安装列表打开详情页 */
  function openEntry(entry: PluginEntry, repository?: string, marketEntry?: PluginMarketEntry) {
    setDetail({ entry, repository, market: marketEntry });
    setHealth('');
    setMsg('');
  }

  async function openConfig(entry: PluginEntry) {
    const data = await getPluginConfig(entry.id);
    setConfigFields(data.fields || []);
    setConfigValues(data.config || {});
    setConfigId(entry.id);
    setDetail(null);
    setMsg('');
  }

  async function openLogs(entry: PluginEntry) {
    const data = await getPluginLogs(entry.id, 200);
    setLogs(data.lines || []);
    setLogsId(entry.id);
    setDetail(null);
  }

  async function installFromMarket(entry: PluginMarketEntry) {
    await run('安装失败', async () => {
      const result = await installPlugin(entry.repository, entry.id);
      setMsg(result.error || `已安装 ${entry.name}`);
      await refreshAll();
    });
  }

  async function updateOne(entry: PluginEntry) {
    await run('更新失败', async () => {
      const result = await updatePlugin(entry.id);
      setMsg(result.error || `已更新 ${entry.name}`);
      await refreshAll();
    });
  }

  function downloadJs(filename: string, content: string) {
    const blob = new Blob([content], { type: 'text/javascript;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    window.setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  async function startExport(entry: PluginEntry, baseUrl = '') {
    await run('导出失败', async () => {
      const result = await exportPluginJs(entry.id, baseUrl);
      downloadJs(result.filename, result.content);
      setMsg(`已导出 ${result.filename}`);
    });
  }

  function openExport(entry: PluginEntry) {
    void startExport(entry);
  }

  async function toggleProxy(entry: PluginEntry, enabled: boolean) {
    await run('代理设置失败', async () => {
      const result = await savePluginProxy(entry.id, enabled);
      const next = { ...entry, ...(result.plugin || {}), proxy: enabled };
      setDetail((prev) =>
        prev && prev.entry.id === entry.id ? { ...prev, entry: next } : prev,
      );
      setMsg(result.error || (enabled ? '已开启运行时走代理' : '已关闭运行时走代理'));
      await refreshAll();
    });
  }

  async function toggleShortdrama(entry: PluginEntry, enabled: boolean) {
    await run('短剧页设置失败', async () => {
      const result = await savePluginShortdrama(entry.id, enabled);
      const next = { ...entry, ...(result.plugin || {}), show_in_drama: enabled };
      setDetail((prev) =>
        prev && prev.entry.id === entry.id ? { ...prev, entry: next } : prev,
      );
      setMsg(enabled ? '已显示在短剧页' : '已从短剧页隐藏');
      window.dispatchEvent(new Event('rexhub:shortdrama-sites'));
      await refreshAll();
    });
  }

  async function toggle(entry: PluginEntry, enabled: boolean) {
    await run(enabled ? '启用失败' : '停用失败', async () => {
      const result = enabled ? await enablePlugin(entry.id) : await disablePlugin(entry.id);
      setDetail({ entry: { ...entry, enabled, running: enabled }, repository: detail?.repository });
      setMsg(result.error || (enabled ? '已启用' : '已停用'));
      await refreshAll();
    });
  }

  async function checkHealth(entry: PluginEntry) {
    await run('健康检查失败', async () => {
      const result = await getPluginHealth(entry.id);
      setHealth(
        result.ok
          ? `健康检查通过（HTTP ${result.status}）`
          : result.error || `健康检查失败（HTTP ${result.status}）`,
      );
    });
  }

  async function rollback(entry: PluginEntry) {
    if (!window.confirm(`回滚「${entry.name}」到上一版本？`)) return;
    await run('回滚失败', async () => {
      const result = await rollbackPlugin(entry.id);
      setMsg(result.error || '已回滚');
      await refreshAll();
    });
  }

  async function remove(entry: PluginEntry) {
    if (!window.confirm(`卸载「${entry.name}」？插件数据默认保留。`)) return;
    if (!window.confirm('同时删除该插件的用户数据？选择「取消」将保留配置与数据。')) {
      await run('卸载失败', async () => {
        await uninstallPlugin(entry.id, false);
        setDetail(null);
        setMsg('已卸载插件，数据已保留');
        await refreshAll();
      });
      return;
    }
    await run('卸载失败', async () => {
      await uninstallPlugin(entry.id, true);
      setDetail(null);
      setMsg('已卸载插件并删除数据');
      await refreshAll();
    });
  }

  async function saveRepo() {
    await run('添加仓库失败', async () => {
      await addPluginRepository({
        url: repoForm.url.trim(),
        name: repoForm.name.trim() || undefined,
        index_path: repoForm.index_path.trim() || 'repository.json',
        branch: repoForm.branch.trim(),
      });
      setRepoForm({ url: '', name: '', index_path: 'repository.json', branch: '' });
      setRepoModalTab('list');
      setMsg('仓库已添加');
      await loadOverview();
    });
  }

  async function refreshRepo(repo: PluginFrameworkRepository) {
    await run('刷新仓库失败', async () => {
      const result = await refreshPluginRepository(repo.id);
      setMsg(`已刷新「${result.name || repo.name}」，${result.entries.length} 个插件`);
      await loadOverview();
      if (view === 'market') await loadMarket();
    });
  }

  async function removeRepo(repo: PluginFrameworkRepository) {
    if (!window.confirm(`删除仓库「${repo.name || repo.url}」？`)) return;
    await run('删除仓库失败', async () => {
      await deletePluginRepository(repo.id);
      setMsg('仓库已删除');
      if (repoFilter === repo.id) setRepoFilter('');
      await loadOverview();
    });
  }

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
          onChange={(key, value) => setConfigValues((prev) => ({ ...prev, [key]: value }))}
        />
        <div className="app-actions">
          <button
            type="button"
            className="app-btn-primary"
            style={{ flex: 1 }}
            disabled={busy}
            onClick={() =>
              void run('保存失败', async () => {
                const result = await savePluginConfig(configId, configValues);
                setMsg(result.restarted ? '配置已保存，插件已重启' : '配置已保存');
                await loadOverview();
              })
            }
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
            onClick={() =>
              void run('日志读取失败', async () => {
                const data = await getPluginLogs(logsId, 200);
                setLogs(data.lines || []);
              })
            }
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
    const version = entry.installed_version || entry.version || marketEntry?.version || '';
    const latest =
      updateById[entry.id]?.latest_version ||
      (marketEntry?.update_available ? marketEntry.version : '');
    const capabilities = entry.capabilities || [];
    const widgetModules = entry.widget_meta?.modules || [];
    const dramaVisible = pluginGroup(entry.category) === 'shortdrama';
    const dramaShown =
      entry.show_in_drama ?? entry.id === 'rexhub.hongguo.video';
    return (
      <>
      <AppPush title={entry.name} onBack={() => setDetail(null)} bodyClassName="plugin-fw-page">
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
                  <span className="settings-kv__value allow-select">
                    {marketEntry?.repository_url || detail.repository || '—'}
                  </span>
                </div>
              </li>
              <li>
                <div className="settings-kv">
                  <span className="settings-kv__key">声明能力</span>
                  <span className="settings-kv__value">
                    {capabilityFeatures(capabilities).join('、') || '无'}
                  </span>
                </div>
              </li>
            </ul>
            <div className="app-actions">
              <button
                type="button"
                className="app-btn-primary"
                style={{ flex: 1 }}
                disabled={busy || !marketEntry}
                onClick={() => {
                  if (marketEntry) void installFromMarket(marketEntry);
                }}
              >
                <Download size={15} strokeWidth={2.3} /> 安装
              </button>
            </div>
          </>
        ) : (
          <>
            <p className="settings-group-label">能力与运行时</p>
            <ul className="settings-group">
              <li>
                <div className="settings-kv">
                  <span className="settings-kv__key">能力</span>
                  <span className="settings-kv__value">
                    {capabilityFeatures(capabilities).join('、') || '未声明'}
                  </span>
                </div>
              </li>
              <li>
                <div className="settings-kv">
                  <span className="settings-kv__key">运行时</span>
                  <span className="settings-kv__value">
                    {runtimeLabel(entry)}
                    {entry.port ? ` · 端口 ${entry.port}` : ''}
                  </span>
                </div>
              </li>
              <li>
                <div className="settings-kv">
                  <span className="settings-kv__key">启用</span>
                  <Switch
                    checked={Boolean(entry.enabled)}
                    disabled={busy}
                    onCheckedChange={(v) => void toggle(entry, v)}
                  />
                </div>
              </li>
              {dramaVisible ? (
                <li>
                  <div className="settings-kv">
                    <span className="settings-kv__key">短剧页显示</span>
                    <Switch
                      checked={Boolean(dramaShown)}
                      disabled={busy}
                      onCheckedChange={(v) => void toggleShortdrama(entry, v)}
                    />
                  </div>
                </li>
              ) : null}
              {entry.runtime?.type !== 'http' ? (
                <li>
                  <div className="settings-kv">
                    <span className="settings-kv__key">运行时走代理</span>
                    <Switch
                      checked={Boolean(entry.proxy)}
                      disabled={busy}
                      onCheckedChange={(v) => void toggleProxy(entry, v)}
                    />
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
                        <span className="settings-kv__value">
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
                        <span className="settings-kv__value">search</span>
                      </div>
                    </li>
                  ) : null}
                </ul>
              </>
            ) : null}

            <p className="settings-group-label">操作</p>
            <ul className="settings-group">
              <li>
                <button type="button" className="settings-nav" onClick={() => void checkHealth(entry)}>
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
                <button type="button" className="settings-nav" onClick={() => void openConfig(entry)}>
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
                <button type="button" className="settings-nav" onClick={() => openExport(entry)}>
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
                <button type="button" className="settings-nav" onClick={() => void openLogs(entry)}>
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
                <button type="button" className="settings-nav" onClick={() => void restartPluginAction(entry)}>
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
                  onClick={() => void updateOne(entry)}
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
                onClick={() => void rollback(entry)}
              >
                <RotateCcw size={15} strokeWidth={2.3} /> 回滚
              </button>
              <button
                type="button"
                className="app-btn-secondary"
                style={{ flex: 1 }}
                disabled={busy}
                onClick={() => void remove(entry)}
              >
                <Trash2 size={15} strokeWidth={2.3} /> 卸载
              </button>
            </div>
          </>
        )}
        {msg ? <AppMsg allowSelect onDismiss={() => setMsg('')}>{msg}</AppMsg> : null}
      </AppPush>
      </>
    );
  }

  async function restartPluginAction(entry: PluginEntry) {
    await run('重启失败', async () => {
      const result = await restartPlugin(entry.id);
      setMsg(result.error || '已重启');
      await refreshAll();
    });
  }

  // -------------------------------------------------------------------------
  // 主页面
  // -------------------------------------------------------------------------
  const counts: Record<View, number> = {
    market: marketAvailable.length,
    installed: installed.length,
  };

  const repoModal = (
    <AppCenterModal
      open={repoModalOpen}
      title="插件仓库"
      onClose={() => setRepoModalOpen(false)}
      cardClassName="plugin-fw-repo-modal"
      footer={
        <button
          type="button"
          className="app-btn-primary plugin-fw-modal__done"
          onClick={() => setRepoModalOpen(false)}
        >
          完成
        </button>
      }
    >
      <div className="plugin-fw-modal__summary">
        <span className="plugin-fw-modal__summary-icon" aria-hidden>
          <Package size={18} strokeWidth={2.2} />
        </span>
        <div className="plugin-fw-modal__summary-main">
          <span className="plugin-fw-modal__eyebrow">GitHub 插件仓库</span>
        </div>
        <span className="plugin-fw-modal__count">{repositories.length}</span>
      </div>

      <div className="plugin-fw-modal__tabs" role="tablist" aria-label="插件仓库管理">
        <button
          type="button"
          role="tab"
          aria-selected={repoModalTab === 'add'}
          className={`plugin-fw-modal__tab${repoModalTab === 'add' ? ' is-on' : ''}`}
          onClick={() => setRepoModalTab('add')}
        >
          添加仓库
        </button>
        <button
          type="button"
          role="tab"
          aria-selected={repoModalTab === 'list'}
          className={`plugin-fw-modal__tab${repoModalTab === 'list' ? ' is-on' : ''}`}
          onClick={() => setRepoModalTab('list')}
        >
          已添加
          <span className="plugin-fw-modal__tab-count">{repositories.length}</span>
        </button>
      </div>

      {repoModalTab === 'add' ? (
        <div className="plugin-fw-modal__form">
          <label className="plugin-fw-modal__field">
            <span className="plugin-fw-modal__label">仓库地址</span>
            <input
              className="allow-select"
              placeholder="owner/repo 或 GitHub 地址"
              value={repoForm.url}
              onChange={(e) => setRepoForm({ ...repoForm, url: e.target.value })}
              autoCapitalize="off"
              spellCheck={false}
            />
          </label>
          <div className="plugin-fw-modal__form-row">
            <label className="plugin-fw-modal__field">
              <span className="plugin-fw-modal__label">显示名称</span>
              <input
                className="allow-select"
                placeholder="可选"
                value={repoForm.name}
                onChange={(e) => setRepoForm({ ...repoForm, name: e.target.value })}
              />
            </label>
            <label className="plugin-fw-modal__field">
              <span className="plugin-fw-modal__label">分支</span>
              <input
                className="allow-select"
                placeholder="main / master"
                value={repoForm.branch}
                onChange={(e) => setRepoForm({ ...repoForm, branch: e.target.value })}
                autoCapitalize="off"
                spellCheck={false}
              />
            </label>
          </div>
          <label className="plugin-fw-modal__field">
            <span className="plugin-fw-modal__label">索引文件</span>
            <input
              className="allow-select"
              placeholder="repository.json / registry.json"
              value={repoForm.index_path}
              onChange={(e) => setRepoForm({ ...repoForm, index_path: e.target.value })}
              autoCapitalize="off"
              spellCheck={false}
            />
          </label>
          <button
            type="button"
            className="app-btn-primary plugin-fw-modal__save"
            disabled={busy || !repoForm.url.trim()}
            onClick={() => void saveRepo()}
          >
            保存仓库
          </button>
        </div>
      ) : repositories.length ? (
        <ul className="plugin-fw-modal__list">
          {repositories.map((repo) => (
            <li key={repo.id} className="plugin-fw-modal__repo">
              <span className="plugin-fw-modal__repo-icon" aria-hidden>
                <Package size={15} strokeWidth={2.2} />
              </span>
              <div className="plugin-fw-modal__repo-main">
                <div className="plugin-fw-modal__repo-name">{repo.name || repo.id}</div>
                <div className="plugin-fw-modal__repo-url allow-select">{repo.url}</div>
                <div className="plugin-fw-modal__repo-chips">
                  <span className="plugin-fw-modal__chip">
                    {repo.index_path || 'repository.json'}
                  </span>
                  {repo.branch ? <span className="plugin-fw-modal__chip">{repo.branch}</span> : null}
                </div>
              </div>
              <div className="plugin-fw-modal__repo-actions">
                <button
                  type="button"
                  className="plugin-fw-modal__icon-btn"
                  aria-label="刷新仓库"
                  title="刷新仓库"
                  disabled={busy}
                  onClick={() => void refreshRepo(repo)}
                >
                  <RefreshCw size={14} strokeWidth={2.3} />
                </button>
                <button
                  type="button"
                  className="plugin-fw-modal__icon-btn plugin-fw-modal__icon-btn--danger"
                  aria-label="删除仓库"
                  title="删除仓库"
                  disabled={busy}
                  onClick={() => void removeRepo(repo)}
                >
                  <Trash2 size={14} strokeWidth={2.3} />
                </button>
              </div>
            </li>
          ))}
        </ul>
      ) : (
        <div className="plugin-fw-modal__empty">
          <span className="plugin-fw-modal__empty-icon" aria-hidden>
            <Package size={20} strokeWidth={2.1} />
          </span>
          <p>还没有插件仓库</p>
          <span>添加一个包含 repository.json 的 GitHub 仓库，即可浏览与安装插件。</span>
        </div>
      )}
    </AppCenterModal>
  );

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
        {VIEWS.map(({ id, title, Icon }) => (
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
            <p className="plugin-empty__desc">到「市场」选择一个插件安装。</p>
          </div>
        )
      ) : null}

      {msg ? <AppMsg allowSelect onDismiss={() => setMsg('')}>{msg}</AppMsg> : null}
      </AppPush>
      {repoModal}
    </>
  );
}
