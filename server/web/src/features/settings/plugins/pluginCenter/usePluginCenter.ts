'use client';

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { errorText, usePanelAction } from '@/hooks/usePanelAction';
import { useAuth } from '@/providers/AuthProvider';
import {
  addPluginRepository,
  deletePluginRepository,
  disablePlugin,
  enablePlugin,
  exportPluginJs,
  getInstalledPlugins,
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
import { categoryRank, pluginGroup, type Detail, type View } from './types';
import type { RepoForm, RepoModalTab } from './RepoModal';

export function usePluginCenter() {
  const { isAdmin } = useAuth();
  const { msg, setMsg, busy, run } = usePanelAction();
  const aliveRef = useRef(true);
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
  const [configSaved, setConfigSaved] = useState<string[]>([]);
  const [logsId, setLogsId] = useState('');
  const [logs, setLogs] = useState<string[]>([]);
  const [repoModalOpen, setRepoModalOpen] = useState(false);
  const [repoModalTab, setRepoModalTab] = useState<RepoModalTab>('list');
  const [repoForm, setRepoForm] = useState<RepoForm>({
    url: '',
    name: '',
    index_path: 'repository.json',
    branch: '',
  });

  const installed = useMemo(() => overview?.installed || [], [overview]);

  useEffect(() => {
    aliveRef.current = true;
    return () => {
      aliveRef.current = false;
    };
  }, []);

  const loadOverview = useCallback(async () => {
    if (!isAdmin) {
      /* 非管理员走只读接口，避免触发管理员专属的仓库与更新查询 */
      const data = await getInstalledPlugins();
      if (!aliveRef.current) return;
      setOverview({ runtime: { node: '' }, repositories: [], installed: data.items });
      setRepositories([]);
      setUpdates([]);
      return;
    }
    const [data, nextUpdates] = await Promise.all([getPluginOverview(), getPluginUpdates()]);
    if (!aliveRef.current) return;
    setOverview(data);
    setRepositories(data.repositories);
    setUpdates(nextUpdates.items);
  }, [isAdmin]);

  const loadMarket = useCallback(async () => {
    if (!isAdmin) return;
    const data = await getPluginMarket(repoFilter);
    if (aliveRef.current) setMarket(data);
  }, [isAdmin, repoFilter]);

  useEffect(() => {
    /* eslint-disable react-hooks/set-state-in-effect */
    void loadOverview().catch((e) => setMsg(errorText(e, '插件列表读取失败')));
    /* eslint-enable react-hooks/set-state-in-effect */
  }, [loadOverview, setMsg]);

  useEffect(() => {
    if (!isAdmin || view !== 'market' || detail || configId || logsId) return;
    void run('插件市场读取失败', async () => {
      await loadMarket();
    });
  }, [isAdmin, view, repoFilter, detail, configId, logsId, loadMarket, run]);

  const installedById = useMemo(
    () => Object.fromEntries(installed.map((item) => [item.id, item])) as Record<string, PluginEntry>,
    [installed],
  );
  const updateById = useMemo(
    () => Object.fromEntries(updates.map((item) => [item.id, item])) as Record<string, PluginUpdate>,
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
    await run('配置读取失败', async () => {
      const data = await getPluginConfig(entry.id);
      setConfigFields(data.fields || []);
      setConfigValues(data.config || {});
      setConfigSaved(data.saved || []);
      setConfigId(entry.id);
      setDetail(null);
      setMsg('');
    });
  }

  async function openLogs(entry: PluginEntry) {
    await run('日志读取失败', async () => {
      const data = await getPluginLogs(entry.id, 200);
      setLogs(data.lines || []);
      setLogsId(entry.id);
      setDetail(null);
    });
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

  async function restartPluginAction(entry: PluginEntry) {
    await run('重启失败', async () => {
      const result = await restartPlugin(entry.id);
      setMsg(result.error || '已重启');
      await refreshAll();
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

  async function saveConfig(id: string) {
    await run('保存失败', async () => {
      const result = await savePluginConfig(id, configValues);
      // 重新拉一次配置：密钥字段只回显掩码，靠 saved 列表标记「已设置」
      const data = await getPluginConfig(id);
      setConfigValues(data.config || {});
      setConfigSaved(data.saved || []);
      setMsg(result.restarted ? '配置已保存，插件已重启' : '配置已保存');
      await loadOverview();
    });
  }

  async function refreshLogs(id: string) {
    await run('日志读取失败', async () => {
      const data = await getPluginLogs(id, 200);
      setLogs(data.lines || []);
    });
  }

  return {
    msg,
    setMsg,
    busy,
    run,
    isAdmin,
    view,
    setView,
    overview,
    repositories,
    updates,
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
    marketRows,
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
  };
}
