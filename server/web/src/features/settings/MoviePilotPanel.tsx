'use client';

import { useEffect, useState } from 'react';
import { ExternalLink, Film } from 'lucide-react';
import {
  getMoviePilotSettings,
  putMoviePilotSettings,
  testMoviePilot,
} from '@/lib/api';
import { Switch } from '@/components/ui/switch';
import { cn } from '@/lib/utils';
import { testResultText, usePanelAction } from '@/hooks/usePanelAction';
import { ConnectionPanelShell } from './connection/ConnectionPanelShell';

export function MoviePilotPanel({ onBack }: { onBack: () => void }) {
  const [enabled, setEnabled] = useState(true);
  const [baseUrl, setBaseUrl] = useState('');
  const [apiKey, setApiKey] = useState('');
  const [hasApiKey, setHasApiKey] = useState(false);
  const [timeoutSec, setTimeoutSec] = useState('15');
  const [loading, setLoading] = useState(true);
  const { msg, setMsg, busy, run } = usePanelAction();

  useEffect(() => {
    void (async () => {
      try {
        const d = await getMoviePilotSettings();
        setEnabled(d.enabled !== false);
        setBaseUrl(d.baseUrl || '');
        setHasApiKey(Boolean(d.hasApiKey));
        setTimeoutSec(String(d.timeoutSec ?? 15));
      } catch (e) {
        setMsg(e instanceof Error ? e.message : '读取失败');
      } finally {
        setLoading(false);
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const base = baseUrl.trim().replace(/\/+$/, '');
  const exampleUrl = `${base}/api/v1/user/?apikey={token}`;

  async function onTest() {
    if (!base) {
      setMsg('请填写服务地址');
      return;
    }
    await run('测试失败', async () => {
      await putMoviePilotSettings({
        enabled,
        baseUrl: base,
        apiKey,
        timeoutSec: Number(timeoutSec) || 15,
      });
      if (apiKey.trim()) {
        setHasApiKey(true);
        setApiKey('');
      }
      const r = await testMoviePilot();
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
    await run('保存失败', async () => {
      const next = await putMoviePilotSettings({
        enabled,
        baseUrl: base,
        apiKey,
        timeoutSec: Number(timeoutSec) || 15,
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
    >
      <div className="svc-panel">
        <ul className="settings-group">
          <li>
            <div className="settings-kv">
              <span className="settings-kv__key">状态</span>
              <span
                className={cn(
                  'settings-nav__status',
                  enabled && hasApiKey
                    ? 'settings-nav__status--ok'
                    : 'settings-nav__status--warn',
                )}
              >
                {enabled && hasApiKey ? '已配置' : '未完整'}
              </span>
            </div>
          </li>
          <li>
            <div className="settings-nav">
              <span className="settings-nav__icon settings-nav__icon--blue" aria-hidden>
                <Film size={14} strokeWidth={2.25} />
              </span>
              <span className="settings-nav__main">
                <span className="settings-nav__title">启用 MoviePilot</span>
                <span className="settings-nav__desc">媒体订阅 · apikey 鉴权</span>
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
                placeholder="https://moviepilot.example.com"
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
                disabled={busy || loading}
              />
            </label>
            <a
              className="settings-kv settings-kv--link allow-select"
              href={`${base}/setting`}
              target="_blank"
              rel="noreferrer"
            >
              <span className="settings-kv__key">令牌管理</span>
              <span className="settings-kv__val">
                <span className="settings-kv__url">{`${base}/setting`}</span>
                <ExternalLink size={13} strokeWidth={2.2} />
              </span>
            </a>
          </div>
        </section>

        <p className="settings-group-label">如何接入</p>
        <section className="app-section">
          <div className="app-section-body">
            <div className="app-field app-field--stack">
              <span className="app-label">接口示例</span>
              <code className="allow-select">{exampleUrl}</code>
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
