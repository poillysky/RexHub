'use client';

import { useEffect, useState } from 'react';
import { ExternalLink } from 'lucide-react';
import {
  getMorePlaySettings,
  getMorePlaySites,
  putMorePlaySettings,
  testMorePlay,
  type MorePlaySite,
} from '@/lib/api';
import { Switch } from '@/components/ui/switch';
import { useAuth } from '@/providers/AuthProvider';
import { cn } from '@/lib/utils';
import { testResultText, usePanelAction } from '@/hooks/usePanelAction';
import { ConnectionPanelShell } from './connection/ConnectionPanelShell';

export function MoreplayPanel({ onBack }: { onBack: () => void }) {
  const { isAdmin } = useAuth();
  const [enabled, setEnabled] = useState(true);
  const [baseUrl, setBaseUrl] = useState('');
  const [timeoutSec, setTimeoutSec] = useState('15');
  const [searchSites, setSearchSites] = useState<string[]>([]);
  const [sites, setSites] = useState<MorePlaySite[]>([]);
  const [loading, setLoading] = useState(true);
  const { msg, setMsg, busy, run } = usePanelAction();
  // 后端只允许管理员改配置；普通用户只能看状态
  const locked = loading || busy || !isAdmin;

  useEffect(() => {
    let alive = true;
    void (async () => {
      try {
        const d = await getMorePlaySettings();
        if (!alive) return;
        setEnabled(d.enabled !== false);
        setBaseUrl(d.baseUrl || '');
        setTimeoutSec(String(d.timeoutSec ?? 15));
        const saved = d.searchSites?.length ? d.searchSites : [d.searchSite || ''];
        setSearchSites(saved.filter(Boolean).slice(0, 3));
      } catch (e) {
        if (alive) setMsg(e instanceof Error ? e.message : '读取失败');
      } finally {
        if (alive) setLoading(false);
      }
      try {
        const loaded = await getMorePlaySites();
        if (!alive) return;
        setSites(loaded);
        if (loaded.length) {
          setSearchSites((current) =>
            current.some(Boolean) ? current : [loaded[0].id],
          );
        }
      } catch {
        // 站点列表读取失败时沿用已保存的站点 ID
      }
    })();
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const base = baseUrl.trim().replace(/\/+$/, '');
  const linkBase = /^https?:\/\//i.test(base) ? base : '';
  const siteConfigUrl = linkBase
    ? `${linkBase}/bridge/cat-source-settings/primary/website`
    : '';
  const t4Url = linkBase ? `${linkBase}/bridge/t4` : '';
  const configured = enabled && Boolean(linkBase);

  function parseTimeout(): number | null {
    const n = Number(timeoutSec);
    return Number.isFinite(n) && n >= 5 && n <= 120 ? n : null;
  }

  async function onTest() {
    if (!base) {
      setMsg('请填写服务地址');
      return;
    }
    const seconds = parseTimeout();
    if (seconds === null) {
      setMsg('超时需在 5–120 秒之间');
      return;
    }
    await run('测试失败', async () => {
      const r = await testMorePlay({ baseUrl: base, timeoutSec: seconds });
      setMsg(
        testResultText(
          r,
          `连接成功${r.siteCount ? ` · ${r.siteCount} 个站源` : ''}`,
          '连接失败',
        ),
      );
    });
  }

  async function onSave() {
    if (!base) {
      setMsg('请填写服务地址');
      return;
    }
    const seconds = parseTimeout();
    if (seconds === null) {
      setMsg('超时需在 5–120 秒之间');
      return;
    }
    await run('保存失败', async () => {
      const next = await putMorePlaySettings({
        enabled,
        baseUrl: base,
        timeoutSec: seconds,
        searchSites: searchSites.filter(Boolean),
      });
      setEnabled(next.enabled !== false);
      setBaseUrl(next.baseUrl || base);
      setTimeoutSec(String(next.timeoutSec ?? 15));
      setSearchSites(next.searchSites?.length ? next.searchSites : []);
      setMsg('已保存');
    });
  }

  // 站点列表读取失败时，用已保存的 ID 垫上，避免下拉框变空
  const siteOptions = sites.length
    ? sites
    : searchSites.filter(Boolean).map((id) => ({ id, name: id }));

  function setSiteAt(index: number, value: string) {
    setSearchSites((prev) => {
      const next = [...prev];
      while (next.length < 3) next.push('');
      next[index] = value;
      return next;
    });
  }

  return (
    <ConnectionPanelShell
      title="MorePlay"
      onBack={onBack}
      msg={msg}
      onDismissMsg={() => setMsg('')}
      loading={loading}
      busy={busy}
      onTest={() => void onTest()}
      onSave={() => void onSave()}
      testLabel="测试连接"
      testDisabled={!isAdmin}
      saveDisabled={!isAdmin}
    >
      <div className="svc-panel">
        <ul className="settings-group">
          <li>
            <div className="settings-kv">
              <span className="settings-kv__key">状态</span>
              <span
                className={cn(
                  'settings-nav__status',
                  configured ? 'settings-nav__status--ok' : 'settings-nav__status--warn',
                )}
              >
                {configured ? '已配置' : enabled ? '未完整' : '已停用'}
              </span>
            </div>
          </li>
          <li>
            <div className="settings-nav">
              <span className="settings-nav__icon settings-nav__icon--brand" aria-hidden>
                <img src="/brand/moreplay.png" alt="" width={26} height={26} decoding="async" />
              </span>
              <span className="settings-nav__main">
                <span className="settings-nav__title">启用 MorePlay</span>
                <span className="settings-nav__desc">猫源聚合 · 影视在线播放</span>
              </span>
              <Switch
                checked={enabled}
                disabled={locked}
                onCheckedChange={setEnabled}
              />
            </div>
          </li>
        </ul>

        <p className="settings-group-label">连接信息</p>
        <section className="app-section">
          <div className="app-section-body">
            <label className="app-field">
              <span className="app-label">地址</span>
              <input
                className="allow-select"
                placeholder="http://moreplay.example.com:2233"
                value={baseUrl}
                onChange={(e) => setBaseUrl(e.target.value)}
                autoCapitalize="off"
                autoCorrect="off"
                autoComplete="off"
                spellCheck={false}
                disabled={locked}
              />
            </label>
            <label className="app-field">
              <span className="app-label">超时（秒）</span>
              <input
                className="allow-select"
                inputMode="numeric"
                placeholder="15"
                value={timeoutSec}
                onChange={(e) => setTimeoutSec(e.target.value)}
                disabled={locked}
              />
            </label>
            {[0, 1, 2].map((index) => (
              <label className="app-field" key={index}>
                <span className="app-label">
                  {index === 0 ? '搜索站源' : `备选 ${index}`}
                </span>
                <select
                  className="allow-select"
                  value={searchSites[index] || ''}
                  onChange={(e) => setSiteAt(index, e.target.value)}
                  disabled={locked || siteOptions.length === 0}
                >
                  <option value="">{index === 0 ? '未指定' : '不指定'}</option>
                  {searchSites[index] &&
                  !siteOptions.some((site) => site.id === searchSites[index]) ? (
                    <option value={searchSites[index]}>{searchSites[index]}</option>
                  ) : null}
                  {siteOptions
                    .filter(
                      (site) =>
                        !searchSites.some(
                          (id, slot) => slot !== index && id === site.id,
                        ),
                    )
                    .map((site) => (
                      <option key={site.id} value={site.id}>
                        {site.name}
                      </option>
                    ))}
                </select>
              </label>
            ))}
          </div>
        </section>

        <p className="settings-group-label">服务入口</p>
        <section className="app-section">
          <div className="app-section-body">
            {siteConfigUrl ? (
              <a
                className="settings-kv settings-kv--link allow-select"
                href={siteConfigUrl}
                target="_blank"
                rel="noreferrer"
              >
                <span className="settings-kv__key">猫源与网盘配置</span>
                <span className="settings-kv__val">
                  <span className="settings-kv__url">{siteConfigUrl}</span>
                  <ExternalLink size={13} strokeWidth={2.2} />
                </span>
              </a>
            ) : (
              <div className="settings-kv">
                <span className="settings-kv__key">猫源与网盘配置</span>
                <span className="settings-kv__val">填写 http(s) 地址后显示</span>
              </div>
            )}
            {t4Url ? (
              <a
                className="settings-kv settings-kv--link allow-select"
                href={t4Url}
                target="_blank"
                rel="noreferrer"
              >
                <span className="settings-kv__key">T4 播放接口</span>
                <span className="settings-kv__val">
                  <span className="settings-kv__url">{t4Url}</span>
                  <ExternalLink size={13} strokeWidth={2.2} />
                </span>
              </a>
            ) : (
              <div className="settings-kv">
                <span className="settings-kv__key">T4 播放接口</span>
                <span className="settings-kv__val">填写 http(s) 地址后显示</span>
              </div>
            )}
          </div>
        </section>
        <p className="app-hint">
          播放依赖猫源「网盘播放代理模式」为优化模式，否则网盘直链会因缺少请求头返回 412。
        </p>
      </div>
    </ConnectionPanelShell>
  );
}
