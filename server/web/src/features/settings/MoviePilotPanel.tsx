'use client';

import { useEffect, useState } from 'react';
import { ExternalLink } from 'lucide-react';
import {
  getMoviePilotSettings,
  putMoviePilotSettings,
  testMoviePilot,
} from '@/lib/api';
import { Switch } from '@/components/ui/switch';
import { useAuth } from '@/providers/AuthProvider';
import { cn } from '@/lib/utils';
import { testResultText, usePanelAction } from '@/hooks/usePanelAction';
import { ConnectionPanelShell } from './connection/ConnectionPanelShell';

export function MoviePilotPanel({ onBack }: { onBack: () => void }) {
  const { isAdmin } = useAuth();
  const [enabled, setEnabled] = useState(true);
  const [baseUrl, setBaseUrl] = useState('');
  const [apiKey, setApiKey] = useState('');
  const [hasApiKey, setHasApiKey] = useState(false);
  const [timeoutSec, setTimeoutSec] = useState('15');
  const [loading, setLoading] = useState(true);
  const { msg, setMsg, busy, run } = usePanelAction();
  // 后端只允许管理员改配置；普通用户只能看状态
  const locked = loading || busy || !isAdmin;

  useEffect(() => {
    let alive = true;
    void (async () => {
      try {
        const d = await getMoviePilotSettings();
        if (!alive) return;
        setEnabled(d.enabled !== false);
        setBaseUrl(d.baseUrl || '');
        setHasApiKey(Boolean(d.hasApiKey));
        setTimeoutSec(String(d.timeoutSec ?? 15));
      } catch (e) {
        if (alive) setMsg(e instanceof Error ? e.message : '读取失败');
      } finally {
        if (alive) setLoading(false);
      }
    })();
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const base = baseUrl.trim().replace(/\/+$/, '');
  const linkBase = /^https?:\/\//i.test(base) ? base : '';
  const settingPage = linkBase ? `${linkBase}/setting` : '';
  const exampleUrl = linkBase ? `${linkBase}/api/v1/user/?apikey={token}` : '';
  const configured = enabled && hasApiKey;

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
      const r = await testMoviePilot({ baseUrl: base, apiKey, timeoutSec: seconds });
      setMsg(testResultText(r, '连接成功', '连接失败'));
    });
  }

  async function onSave() {
    if (!base) {
      setMsg('请填写服务地址');
      return;
    }
    if (!apiKey.trim() && !hasApiKey) {
      setMsg('请填写 API 令牌');
      return;
    }
    const seconds = parseTimeout();
    if (seconds === null) {
      setMsg('超时需在 5–120 秒之间');
      return;
    }
    await run('保存失败', async () => {
      const next = await putMoviePilotSettings({
        enabled,
        baseUrl: base,
        apiKey,
        timeoutSec: seconds,
      });
      setEnabled(next.enabled !== false);
      setBaseUrl(next.baseUrl || base);
      setHasApiKey(Boolean(next.hasApiKey));
      setApiKey('');
      setTimeoutSec(String(next.timeoutSec ?? 15));
      setMsg('已保存');
    });
  }

  return (
    <ConnectionPanelShell
      title="MoviePilot"
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
                <img src="/brand/moviepilot.svg" alt="" width={26} height={26} decoding="async" />
              </span>
              <span className="settings-nav__main">
                <span className="settings-nav__title">启用 MoviePilot</span>
                <span className="settings-nav__desc">媒体订阅 · apikey 鉴权</span>
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
                placeholder="https://moviepilot.example.com"
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
          </div>
        </section>

        <p className="settings-group-label">API 令牌</p>
        <section className="app-section">
          <div className="app-section-body">
            <label className="app-field">
              <span className="app-label">令牌</span>
              <input
                type="password"
                className="allow-select"
                placeholder={hasApiKey ? '已保存，留空不改' : 'apikey'}
                value={apiKey}
                onChange={(e) => setApiKey(e.target.value)}
                autoCapitalize="off"
                autoCorrect="off"
                autoComplete="off"
                spellCheck={false}
                disabled={locked}
              />
            </label>
            {settingPage ? (
              <a
                className="settings-kv settings-kv--link allow-select"
                href={settingPage}
                target="_blank"
                rel="noreferrer"
              >
                <span className="settings-kv__key">令牌管理</span>
                <span className="settings-kv__val">
                  <span className="settings-kv__url">{settingPage}</span>
                  <ExternalLink size={13} strokeWidth={2.2} />
                </span>
              </a>
            ) : (
              <div className="settings-kv">
                <span className="settings-kv__key">令牌管理</span>
                <span className="settings-kv__val">填写 http(s) 地址后显示</span>
              </div>
            )}
          </div>
        </section>

        <p className="settings-group-label">如何接入</p>
        <section className="app-section">
          <div className="app-section-body">
            <div className="app-field app-field--stack">
              <span className="app-label">接口示例</span>
              <code className="allow-select">
                {exampleUrl || '填写 http(s) 地址后显示'}
              </code>
            </div>
            <div className="app-field app-field--stack">
              <span className="app-label">请求参数</span>
              <code className="allow-select">apikey={'<令牌>'}</code>
            </div>
          </div>
        </section>
      </div>
    </ConnectionPanelShell>
  );
}
