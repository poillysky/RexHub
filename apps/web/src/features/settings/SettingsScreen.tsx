'use client';

import { useCallback, useEffect, useState, type ComponentType } from 'react';
import {
  Building2,
  Captions,
  ChevronRight,
  Clapperboard,
  Cloud,
  Database,
  HardDrive,
  MessageCircle,
  MessagesSquare,
  Package,
  PlayCircle,
  Search,
  Sparkles,
  Palette,
  UserRound,
  Wifi,
  type LucideProps,
} from 'lucide-react';
import { useAuth } from '@/providers/AuthProvider';
import { useTabNavigation } from '@/shell';
import {
  getP115,
  getBitmagnetDb,
  getAiLlm,
  getAiEmbed,
  getNetwork,
  getCloudSaverSettings,
  getAdminPlugins,
  getStremioCatalog,
} from '@/lib/api';
import { cn } from '@/lib/utils';
import { useStackCover } from '@/hooks/useStackCover';
import { UserManagePanel } from './UserManagePanel';
import { BitmagnetDbPanel } from './BitmagnetDbPanel';
import { P115Panel } from './P115Panel';
import { ForumManagePanel } from './ForumManagePanel';
import { AiModelsPanel, aiModelsHubStatus } from './AiModelsPanel';
import { NetworkPanel } from './NetworkPanel';
import { CloudSaverPanel } from './CloudSaverPanel';
import { AppearancePanel } from './AppearancePanel';
import { PluginCategoryPanel } from './plugins/PluginCategoryPanel';
import { StremioPanel } from './plugins/StremioPanel';
import { getThemeMode } from '@/lib/theme';
import {
  getCachedSettingsHubMeta,
  isSettingsHubMetaFresh,
  setCachedSettingsHubMeta,
  withAppearanceStatus,
  pluginCategoryStatus,
  type SettingsHubMeta,
  type SettingsHubEntryId,
} from './settingsHubCache';

type PluginKind = 'video' | 'drama' | 'maker' | 'subtitle' | 'danmu';

const PLUGIN_KINDS: PluginKind[] = ['video', 'drama', 'maker', 'subtitle', 'danmu'];

type Panel =
  | 'hub'
  | 'users'
  | 'appearance'
  | 'drive'
  | 'p115'
  | 'services'
  | 'bitmagnet'
  | 'cloudsaver'
  | 'forum'
  | `plugin:${PluginKind}`
  | 'stremio'
  | 'network'
  | 'ai';
type Tone = 'ok' | 'warn' | 'mute';
type Accent = 'blue' | 'orange' | 'teal' | 'indigo' | 'green' | 'pink';

type Entry = {
  id: Exclude<Panel, 'hub'>;
  title: string;
  desc: string;
  Icon: ComponentType<LucideProps>;
  accent: Accent;
};

type Section = {
  id: string;
  label: string;
  items: Entry[];
};

const SECTIONS: Section[] = [
  {
    id: 'account',
    label: '账号与外观',
    items: [
      {
        id: 'users',
        title: '用户管理',
        desc: '登录账号与权限',
        Icon: UserRound,
        accent: 'blue',
      },
      {
        id: 'appearance',
        title: '外观',
        desc: '浅色 / 深色 / 跟随系统',
        Icon: Palette,
        accent: 'indigo',
      },
    ],
  },
  {
    id: 'drive',
    label: '网盘管理',
    items: [
      {
        id: 'p115',
        title: '115 网盘',
        desc: '登录状态 · 转存目录',
        Icon: Cloud,
        accent: 'orange',
      },
    ],
  },
  {
    id: 'service',
    label: '服务管理',
    items: [
      {
        id: 'bitmagnet',
        title: 'Bitmagnet',
        desc: '磁力索引资源库',
        Icon: HardDrive,
        accent: 'teal',
      },
      {
        id: 'cloudsaver',
        title: 'CloudSaver',
        desc: '账号登录与资源搜索',
        Icon: Search,
        accent: 'green',
      },
      {
        id: 'forum',
        title: '色花堂',
        desc: '论坛板块与地区',
        Icon: MessagesSquare,
        accent: 'blue',
      },
    ],
  },
  {
    id: 'plugin',
    label: '插件',
    items: [
      {
        id: 'plugin:video',
        title: '影视插件',
        desc: '影视站点与播放源',
        Icon: Clapperboard,
        accent: 'blue',
      },
      {
        id: 'plugin:drama',
        title: '短剧插件',
        desc: '短剧聚合与剧集',
        Icon: PlayCircle,
        accent: 'orange',
      },
      {
        id: 'plugin:maker',
        title: '片商插件',
        desc: '片商 / 番号资料',
        Icon: Building2,
        accent: 'pink',
      },
      {
        id: 'plugin:subtitle',
        title: '字幕插件',
        desc: '字幕搜索与下载',
        Icon: Captions,
        accent: 'indigo',
      },
      {
        id: 'plugin:danmu',
        title: '弹幕插件',
        desc: '弹幕源与匹配',
        Icon: MessageCircle,
        accent: 'teal',
      },
      {
        id: 'stremio',
        title: 'Stremio 插件库',
        desc: '订阅仓库与 addon 详情',
        Icon: Package,
        accent: 'green',
      },
    ],
  },
  {
    id: 'network',
    label: '网络管理',
    items: [
      {
        id: 'network',
        title: '网络代理',
        desc: '出站 HTTP 代理 · FlareSolverr',
        Icon: Wifi,
        accent: 'teal',
      },
    ],
  },
  {
    id: 'ai',
    label: 'AI 模型管理',
    items: [
      {
        id: 'ai',
        title: 'AI 模型',
        desc: '聊天与向量嵌入',
        Icon: Sparkles,
        accent: 'green',
      },
    ],
  },
];

const HUB_FIXED_META: Record<string, { text: string; tone: Tone }> = {
  services: { text: '3 个服务', tone: 'mute' },
  drive: { text: '115 网盘', tone: 'mute' },
};

function hubStatus(id: Entry['id'], meta: SettingsHubMeta) {
  if (id === 'plugin:video') return meta.video;
  if (id === 'plugin:drama') return meta.drama;
  if (id === 'plugin:maker') return meta.maker;
  if (id === 'plugin:subtitle') return meta.subtitle;
  if (id === 'plugin:danmu') return meta.danmu;
  return HUB_FIXED_META[id] || meta[id as keyof SettingsHubMeta];
}

const emptyMeta: SettingsHubMeta = {
  users: { text: '…', tone: 'mute' },
  bitmagnet: { text: '…', tone: 'mute' },
  p115: { text: '…', tone: 'mute' },
  network: { text: '…', tone: 'mute' },
  cloudsaver: { text: '…', tone: 'mute' },
  ai: { text: '…', tone: 'mute' },
  forum: { text: '…', tone: 'mute' },
  appearance: { text: '…', tone: 'mute' },
  video: { text: '…', tone: 'mute' },
  drama: { text: '…', tone: 'mute' },
  maker: { text: '…', tone: 'mute' },
  subtitle: { text: '…', tone: 'mute' },
  danmu: { text: '…', tone: 'mute' },
  stremio: { text: '…', tone: 'mute' },
};

export function SettingsScreen() {
  const { isAdmin, logout, status } = useAuth();
  const tabCtx = useTabNavigation();
  const [panel, setPanel] = useState<Panel>('hub');
  const [meta, setMeta] = useState<SettingsHubMeta>(() =>
    withAppearanceStatus(
      { ...emptyMeta, ...(getCachedSettingsHubMeta() || {}) },
      getThemeMode(),
    ),
  );
  const hubCover = useStackCover(panel !== 'hub', 'settings-hub', 'settings-hub');

  const setEntryStatus = useCallback(
    (id: SettingsHubEntryId, text: string, tone: Tone) => {
      setMeta((m) => {
        const next = { ...m, [id]: { text, tone } };
        setCachedSettingsHubMeta(next);
        return next;
      });
    },
    [],
  );

  const refreshHub = useCallback(async () => {
    setEntryStatus(
      'users',
      status === 'authenticated' ? (isAdmin ? '管理员' : '已登录') : '未登录',
      status === 'authenticated' ? 'ok' : 'warn',
    );
    setEntryStatus('forum', '色花堂', 'ok');
    setEntryStatus(
      'appearance',
      getThemeMode() === 'system' ? '系统' : getThemeMode() === 'light' ? '浅色' : '深色',
      'mute',
    );
    // 有未过期缓存则跳过全量刷新（子页 onStatus 已即时改单项）
    // 超时只标「超时」，勿全员「异常」（影视 TMDB 外连拖慢 API 时易误报）
    const withTimeout = <T,>(p: Promise<T>, ms: number): Promise<T> =>
      new Promise((resolve, reject) => {
        const t = window.setTimeout(() => reject(new Error('timeout')), ms);
        p.then(
          (v) => {
            window.clearTimeout(t);
            resolve(v);
          },
          (e) => {
            window.clearTimeout(t);
            reject(e);
          },
        );
      });
    const failStatus = (e: unknown): { text: string; tone: Tone } =>
      e instanceof Error && e.message === 'timeout'
        ? { text: '超时', tone: 'mute' }
        : { text: '异常', tone: 'warn' };

    await Promise.all([
      (async () => {
        try {
          const cfg = await withTimeout(getBitmagnetDb(), 12000);
          if (cfg.enabled && cfg.dsn) setEntryStatus('bitmagnet', '已启用', 'ok');
          else if (cfg.dsn) setEntryStatus('bitmagnet', '未启用', 'warn');
          else setEntryStatus('bitmagnet', '未配置', 'warn');
        } catch (e) {
          const f = failStatus(e);
          setEntryStatus('bitmagnet', f.text, f.tone);
        }
      })(),
      (async () => {
        try {
          const p = await withTimeout(getP115(), 12000);
          setEntryStatus('p115', p.configured ? '已就绪' : '未配置', p.configured ? 'ok' : 'warn');
        } catch (e) {
          const f = failStatus(e);
          setEntryStatus('p115', f.text, f.tone);
        }
      })(),
      (async () => {
        try {
          const n = await withTimeout(getNetwork(), 12000);
          const proxyOn = Boolean(n.configured);
          const flareOn = Boolean(n.flareSolverrConfigured);
          setEntryStatus(
            'network',
            proxyOn && flareOn
              ? '代理 · Flare'
              : proxyOn
                ? '代理已启用'
                : flareOn
                  ? 'Flare 已启用'
                  : '未启用',
            proxyOn || flareOn ? 'ok' : 'warn',
          );
        } catch (e) {
          const f = failStatus(e);
          setEntryStatus('network', f.text, f.tone);
        }
      })(),
      (async () => {
        try {
          const c = await withTimeout(getCloudSaverSettings(), 12000);
          if (c.enabled && c.username && c.hasPassword) {
            setEntryStatus('cloudsaver', '已配置', 'ok');
          } else if (c.username || c.hasPassword || c.baseUrl) {
            setEntryStatus('cloudsaver', '未完整', 'warn');
          } else {
            setEntryStatus('cloudsaver', '未配置', 'warn');
          }
        } catch (e) {
          const f = failStatus(e);
          setEntryStatus('cloudsaver', f.text, f.tone);
        }
      })(),
      (async () => {
        try {
          const [llm, embed] = await withTimeout(Promise.all([getAiLlm(), getAiEmbed()]), 12000);
          const text = aiModelsHubStatus(llm, embed);
          setEntryStatus('ai', text, text === '未配置' ? 'warn' : 'ok');
        } catch (e) {
          const f = failStatus(e);
          setEntryStatus('ai', f.text, f.tone);
        }
      })(),
      (async () => {
        try {
          const data = await withTimeout(getAdminPlugins(), 15000);
          const widgets = data.feeds.flatMap((feed) => feed.widgets || []);
          const rows = [...data.plugins, ...widgets];
          for (const kind of PLUGIN_KINDS) {
            const st = pluginCategoryStatus(rows, kind);
            setEntryStatus(kind, st.text, st.tone);
          }
        } catch (e) {
          const f = failStatus(e);
          for (const kind of PLUGIN_KINDS) setEntryStatus(kind, f.text, f.tone);
        }
      })(),
      (async () => {
        try {
          const data = await withTimeout(getStremioCatalog(), 15000);
          const s = data.stats;
          setEntryStatus(
            'stremio',
            s.addons ? `${s.enabled}/${s.addons} addon` : '未添加',
            s.addons ? (s.enabled ? 'ok' : 'warn') : 'mute',
          );
        } catch (e) {
          const f = failStatus(e);
          setEntryStatus('stremio', f.text, f.tone);
        }
      })(),
    ]);
  }, [isAdmin, setEntryStatus, status]);

  useEffect(() => {
    if (panel !== 'hub') return;
    // 登录态本地即可更新，不必等全量接口
    setEntryStatus(
      'users',
      status === 'authenticated' ? (isAdmin ? '管理员' : '已登录') : '未登录',
      status === 'authenticated' ? 'ok' : 'warn',
    );
    setEntryStatus('forum', '色花堂', 'ok');
    setEntryStatus(
      'appearance',
      getThemeMode() === 'system' ? '系统' : getThemeMode() === 'light' ? '浅色' : '深色',
      'mute',
    );
    // 有未过期缓存则跳过全量刷新（子页 onStatus 已即时改单项）
    if (isSettingsHubMetaFresh()) return;
    void refreshHub();
  }, [panel, refreshHub, setEntryStatus, status, isAdmin]);

  // 再次点「更多」：回到 Hub（iOS 习惯）；切走不强制清栈
  useEffect(() => {
    if (!tabCtx || tabCtx.activeTab !== '/settings') return;
    if (tabCtx.tabReselect > 0) setPanel('hub');
  }, [tabCtx?.tabReselect]);

  async function onLogout() {
    await logout();
    setPanel('hub');
  }

  return (
    <div className="settings-screen-root">
      <div {...hubCover}>
        <div className="settings-hub__top">
          <h1 className="settings-hub__title">更多</h1>
        </div>
        <div className="settings-hub__scroll">
          {SECTIONS.map((section) => (
            <section key={section.id} className="settings-hub__section">
              <h2 className="settings-group-label">{section.label}</h2>
              <ul className="settings-group">
                {section.items.map((item) => {
                  const Icon = item.Icon;
                  const st = hubStatus(item.id, meta) || { text: '…', tone: 'mute' as Tone };
                  return (
                    <li key={item.id}>
                      <button
                        type="button"
                        className="settings-nav"
                        onClick={() => setPanel(item.id)}
                      >
                        <span
                          className={`settings-nav__icon settings-nav__icon--${item.accent}`}
                          aria-hidden
                        >
                          <Icon size={17} strokeWidth={2.2} />
                        </span>
                        <span className="settings-nav__main">
                          <span className="settings-nav__title">{item.title}</span>
                          <span className="settings-nav__desc">{item.desc}</span>
                        </span>
                        <span className="settings-nav__trail">
                          <span
                            className={cn(
                              'settings-nav__status',
                              st.tone === 'ok' && 'settings-nav__status--ok',
                              st.tone === 'warn' && 'settings-nav__status--warn',
                              st.tone === 'mute' && 'settings-nav__status--mute',
                            )}
                          >
                            {st.text}
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
                })}
              </ul>
            </section>
          ))}
        </div>
      </div>

      {panel === 'users' ? (
        <UserManagePanel onBack={() => setPanel('hub')} onLogout={() => void onLogout()} />
      ) : null}
      {panel === 'bitmagnet' ? (
        <BitmagnetDbPanel
          onBack={() => setPanel('hub')}
          onStatus={(text, tone) => setEntryStatus('bitmagnet', text, tone)}
        />
      ) : null}
      {panel === 'p115' ? (
        <P115Panel
          onBack={() => setPanel('hub')}
          onStatus={(text, tone) => setEntryStatus('p115', text, tone)}
        />
      ) : null}
      {panel === 'network' ? (
        <NetworkPanel
          onBack={() => setPanel('hub')}
          onStatus={(text, tone) => setEntryStatus('network', text, tone)}
        />
      ) : null}
      {panel === 'cloudsaver' ? (
        <CloudSaverPanel
          onBack={() => setPanel('hub')}
          onStatus={(text, tone) => setEntryStatus('cloudsaver', text, tone)}
        />
      ) : null}
      {panel === 'forum' ? (
        <ForumManagePanel
          onBack={() => setPanel('hub')}
          onStatus={(text, tone) => setEntryStatus('forum', text, tone)}
        />
      ) : null}
      {panel.startsWith('plugin:') ? (
        <PluginCategoryPanel
          category={panel.slice('plugin:'.length)}
          onBack={() => setPanel('hub')}
          onStatus={(text, tone) =>
            setEntryStatus(panel.slice('plugin:'.length) as SettingsHubEntryId, text, tone)
          }
        />
      ) : null}
      {panel === 'stremio' ? (
        <StremioPanel
          onBack={() => setPanel('hub')}
          onStatus={(text, tone) => setEntryStatus('stremio', text, tone)}
        />
      ) : null}
      {panel === 'ai' ? (
        <AiModelsPanel
          onBack={() => setPanel('hub')}
          onStatus={(text, tone) => setEntryStatus('ai', text, tone)}
        />
      ) : null}
      {panel === 'appearance' ? (
        <AppearancePanel
          onBack={() => setPanel('hub')}
          onStatus={(text, tone) => setEntryStatus('appearance', text, tone)}
        />
      ) : null}
    </div>
  );
}
