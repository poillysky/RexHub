'use client';

import { useEffect, useState } from 'react';
import { Clapperboard, ExternalLink } from 'lucide-react';
import {
  getMorePlaySettings,
  getMorePlaySites,
  putMorePlaySettings,
  testMorePlay,
  type MorePlaySite,
} from '@/lib/api';
import { Switch } from '@/components/ui/switch';
import { cn } from '@/lib/utils';
import { usePanelAction } from '@/hooks/usePanelAction';
import { ConnectionPanelShell } from './connection/ConnectionPanelShell';

const FALLBACK_BASE = 'http://192.168.2.38:2233';

export function MoreplayPanel({ onBack }: { onBack: () => void }) {
  const [enabled, setEnabled] = useState(true);
  const [baseUrl, setBaseUrl] = useState(FALLBACK_BASE);
  const [timeoutSec, setTimeoutSec] = useState('15');
  const [searchSite, setSearchSite] = useState('nodejs_wogg');
  const [sites, setSites] = useState<MorePlaySite[]>([]);
  const [loading, setLoading] = useState(true);
  const { msg, setMsg, busy, run } = usePanelAction();

  useEffect(() => {
    void (async () => {
      try {
        const d = await getMorePlaySettings();
        setEnabled(d.enabled !== false);
        setBaseUrl(d.baseUrl || FALLBACK_BASE);
        setTimeoutSec(String(d.timeoutSec ?? 15));
        if (d.searchSite) setSearchSite(d.searchSite);
      } catch (e) {
        setMsg(e instanceof Error ? e.message : '读取失败');
      } finally {
        setLoading(false);
      }
      try {
        setSites(await getMorePlaySites());
      } catch {
        // 站点列表读取失败时沿用已保存的站点 ID
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const base = (baseUrl.trim() || FALLBACK_BASE).replace(/\/+$/, '');
  const siteConfigUrl = `${base}/bridge/cat-source-settings/primary/website`;
  const t4Url = `${base}/bridge/t4`;

  async function onTest() {
    await run('测试失败', async () => {
      await putMorePlaySettings({
        enabled,
        baseUrl: base,
        timeoutSec: Number(timeoutSec) || 15,
        searchSite,
      });
      setBaseUrl(base);
      const r = await testMorePlay();
      setMsg(
        r.ok
          ? `连接成功${r.siteCount ? ` · ${r.siteCount} 个站源` : ''}`
          : r.message || '连接失败',
      );
    });
  }

  async function onSave() {
    await run('保存失败', async () => {
      const next = await putMorePlaySettings({
        enabled,
        baseUrl: base,
        timeoutSec: Number(timeoutSec) || 15,
        searchSite,
      });
      setEnabled(next.enabled !== false);
      setBaseUrl(next.baseUrl || base);
      setTimeoutSec(String(next.timeoutSec ?? 15));
      if (next.searchSite) setSearchSite(next.searchSite);
      setMsg('已保存');
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
    >
      <div className="svc-panel">
        <ul className="settings-group">
          <li>
            <div className="settings-kv">
              <span className="settings-kv__key">状态</span>
              <span
                className={cn(
                  'settings-nav__status',
                  enabled ? 'settings-nav__status--ok' : 'settings-nav__status--warn',
                )}
              >
                {enabled ? '已启用' : '已停用'}
              </span>
            </div>
          </li>
          <li>
            <div className="settings-nav">
              <span className="settings-nav__icon settings-nav__icon--blue" aria-hidden>
                <Clapperboard size={14} strokeWidth={2.25} />
              </span>
              <span className="settings-nav__main">
                <span className="settings-nav__title">启用 MorePlay</span>
                <span className="settings-nav__desc">猫源聚合 · 影视在线播放</span>
              </span>
              <Switch
                checked={enabled}
                disabled={busy || loading}
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
                placeholder={FALLBACK_BASE}
                value={baseUrl}
                onChange={(e) => setBaseUrl(e.target.value)}
                autoCapitalize="off"
                autoCorrect="off"
                autoComplete="off"
                spellCheck={false}
                disabled={busy || loading}
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
                disabled={busy || loading}
              />
            </label>
            <label className="app-field">
              <span className="app-label">搜索站源</span>
              <select
                className="allow-select"
                value={searchSite}
                onChange={(e) => setSearchSite(e.target.value)}
                disabled={busy || loading || sites.length === 0}
              >
                {sites.length === 0 ? (
                  <option value={searchSite}>{searchSite}</option>
                ) : (
                  sites.map((site) => (
                    <option key={site.id} value={site.id}>
                      {site.name}
                    </option>
                  ))
                )}
              </select>
            </label>
          </div>
        </section>

        <p className="settings-group-label">服务入口</p>
        <section className="app-section">
          <div className="app-section-body">
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
          </div>
        </section>
        <p className="app-hint">
          播放依赖猫源「网盘播放代理模式」为优化模式，否则网盘直链会因缺少请求头返回 412。
        </p>
      </div>
    </ConnectionPanelShell>
  );
}
