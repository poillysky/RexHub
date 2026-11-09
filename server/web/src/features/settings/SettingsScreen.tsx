'use client';

import { startTransition, useEffect, useState, type ComponentType } from 'react';
import {
  ChevronRight,
  Clapperboard,
  Cloud,
  Database,
  Film,
  HardDrive,
  MessagesSquare,
  Package,
  Blocks,
  Search,
  Sparkles,
  Palette,
  UserRound,
  Wifi,
  type LucideProps,
} from 'lucide-react';
import { useAuth } from '@/providers/AuthProvider';
import { useTabNavigation } from '@/shell';
import { useStackCover } from '@/hooks/useStackCover';
import { UserManagePanel } from './UserManagePanel';
import { BitmagnetDbPanel } from './BitmagnetDbPanel';
import { P115Panel } from './P115Panel';
import { ForumManagePanel } from './ForumManagePanel';
import { AiModelsPanel } from './AiModelsPanel';
import { NetworkPanel } from './NetworkPanel';
import { CloudSaverPanel } from './CloudSaverPanel';
import { AvdbPanel } from './AvdbPanel';
import { MoviePilotPanel } from './MoviePilotPanel';
import { MoreplayPanel } from './MoreplayPanel';
import { AppearancePanel } from './AppearancePanel';
import { PluginCenterPanel } from './PluginCenterPanel';
import { StremioPanel } from './plugins/StremioPanel';

type Panel =
  | 'hub'
  | 'users'
  | 'appearance'
  | 'p115'
  | 'bitmagnet'
  | 'cloudsaver'
  | 'forum'
  | 'avdb'
  | 'moviepilot'
  | 'moreplay'
  | 'plugin-center'
  | 'stremio'
  | 'network'
  | 'ai';
type Accent = 'blue' | 'orange' | 'teal' | 'indigo' | 'green' | 'pink';

type Entry = {
  id: Exclude<Panel, 'hub'>;
  title: string;
  desc: string;
  /** 服务类型标签：影视 / 片商 */
  tags?: string[];
  Icon: ComponentType<LucideProps>;
  accent: Accent;
  logo?: string;
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
        desc: '账号、密码与权限',
        Icon: UserRound,
        accent: 'blue',
        logo: '/brand/users.svg',
      },
      {
        id: 'appearance',
        title: '外观',
        desc: '浅色 / 深色 / 跟随系统',
        Icon: Palette,
        accent: 'indigo',
        logo: '/brand/appearance.svg',
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
        logo: '/brand/115.png',
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
        tags: ['影视', '片商'],
        Icon: HardDrive,
        accent: 'teal',
        logo: '/brand/bitmagnet.png',
      },
      {
        id: 'cloudsaver',
        title: 'CloudSaver',
        desc: '账号登录与资源搜索',
        tags: ['影视'],
        Icon: Search,
        accent: 'green',
        logo: '/brand/cloudsaver.png',
      },
      {
        id: 'forum',
        title: '色花堂',
        desc: '链接信息 · 论坛板块',
        tags: ['片商'],
        Icon: MessagesSquare,
        accent: 'blue',
        logo: '/brand/sehuatang.png',
      },
      {
        id: 'avdb',
        title: 'AVDB',
        desc: 'API 令牌 · 资源接口',
        tags: ['片商'],
        Icon: Database,
        accent: 'pink',
        logo: '/brand/avdb.svg',
      },
      {
        id: 'moviepilot',
        title: 'MoviePilot',
        desc: 'API 令牌 · 媒体订阅',
        tags: ['影视'],
        Icon: Film,
        accent: 'blue',
        logo: '/brand/moviepilot.svg',
      },
      {
        id: 'moreplay',
        title: 'MorePlay',
        desc: '猫源聚合 · 在线播放',
        tags: ['影视'],
        Icon: Clapperboard,
        accent: 'blue',
        logo: '/brand/moreplay.png',
      },
    ],
  },
  {
    id: 'plugin',
    label: '插件',
    items: [
      {
        id: 'plugin-center',
        title: '插件中心',
        desc: '市场 · 安装 · 更新 · 配置',
        Icon: Blocks,
        accent: 'blue',
        logo: '/brand/plugin-center.svg',
      },
      {
        id: 'stremio',
        title: 'Stremio 插件库',
        desc: '订阅仓库与 addon 详情',
        Icon: Package,
        accent: 'green',
        logo: '/brand/stremio.svg',
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
        logo: '/brand/network.svg',
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
        desc: '聊天模型与 Agent',
        Icon: Sparkles,
        accent: 'green',
        logo: '/brand/ai.svg',
      },
    ],
  },
];

export function SettingsScreen() {
  const { logout, isAdmin } = useAuth();
  const tabCtx = useTabNavigation();
  const activeTab = tabCtx?.activeTab;
  const tabReselect = tabCtx?.tabReselect ?? 0;
  const [panel, setPanel] = useState<Panel>('hub');
  const hubCover = useStackCover(panel !== 'hub', 'settings-hub', 'settings-hub');
  // AI 设置接口仅管理员可用，普通用户不展示入口，避免点进去全是 403
  const sections = isAdmin ? SECTIONS : SECTIONS.filter((s) => s.id !== 'ai');

  // 再次点「更多」：回到 Hub（iOS 习惯）；切走不强制清栈
  useEffect(() => {
    if (activeTab !== '/settings' || tabReselect === 0) return;
    startTransition(() => setPanel('hub'));
  }, [activeTab, tabReselect]);

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
          {sections.map((section) => (
            <section key={section.id} className="settings-hub__section">
              <h2 className="settings-group-label">{section.label}</h2>
              <ul className="settings-group">
                {section.items.map((item) => {
                  const Icon = item.Icon;
                  return (
                    <li key={item.id}>
                      <button
                        type="button"
                        className="settings-nav"
                        onClick={() => setPanel(item.id)}
                      >
                        <span
                          className={
                            item.logo
                              ? 'settings-nav__icon settings-nav__icon--brand'
                              : `settings-nav__icon settings-nav__icon--${item.accent}`
                          }
                          aria-hidden
                        >
                          {item.logo ? (
                            <img src={item.logo} alt="" width={26} height={26} decoding="async" />
                          ) : (
                            <Icon size={17} strokeWidth={2.2} />
                          )}
                        </span>
                        <span className="settings-nav__main">
                          <span className="settings-nav__head">
                            <span className="settings-nav__title">{item.title}</span>
                            {item.tags?.map((tag) => (
                              <span key={tag} className="settings-nav__tag">
                                {tag}
                              </span>
                            ))}
                          </span>
                          <span className="settings-nav__desc">{item.desc}</span>
                        </span>
                        <span className="settings-nav__trail">
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
        <BitmagnetDbPanel onBack={() => setPanel('hub')} />
      ) : null}
      {panel === 'p115' ? (
        <P115Panel onBack={() => setPanel('hub')} />
      ) : null}
      {panel === 'network' ? (
        <NetworkPanel onBack={() => setPanel('hub')} />
      ) : null}
      {panel === 'cloudsaver' ? (
        <CloudSaverPanel onBack={() => setPanel('hub')} />
      ) : null}
      {panel === 'forum' ? (
        <ForumManagePanel onBack={() => setPanel('hub')} />
      ) : null}
      {panel === 'avdb' ? (
        <AvdbPanel onBack={() => setPanel('hub')} />
      ) : null}
      {panel === 'moviepilot' ? (
        <MoviePilotPanel onBack={() => setPanel('hub')} />
      ) : null}
      {panel === 'moreplay' ? (
        <MoreplayPanel onBack={() => setPanel('hub')} />
      ) : null}
      {panel === 'plugin-center' ? (
        <PluginCenterPanel onBack={() => setPanel('hub')} />
      ) : null}
      {panel === 'stremio' ? (
        <StremioPanel onBack={() => setPanel('hub')} />
      ) : null}
      {panel === 'ai' && isAdmin ? (
        <AiModelsPanel onBack={() => setPanel('hub')} />
      ) : null}
      {panel === 'appearance' ? (
        <AppearancePanel onBack={() => setPanel('hub')} />
      ) : null}
    </div>
  );
}
