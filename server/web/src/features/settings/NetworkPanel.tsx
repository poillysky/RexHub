'use client';

import { useEffect, useState } from 'react';
import {
  getNetwork,
  putNetwork,
  testFlareSolverr,
  testNetwork,
  type NetworkConfig,
} from '@/lib/api';
import { Switch } from '@/components/ui/switch';
import { AppPush } from '@/components/ui/AppPush';
import { AppMsg } from '@/components/ui/AppMsg';
import { cn } from '@/lib/utils';
import { testResultText, usePanelAction } from '@/hooks/usePanelAction';

function toProxyHostPort(raw: string): string {
  const s = raw.trim();
  if (!s) return '';
  try {
    const u = new URL(s.includes('://') ? s : `http://${s}`);
    return u.host || u.hostname;
  } catch {
    return s.replace(/^https?:\/\//i, '').replace(/\/$/, '');
  }
}

export function NetworkPanel({ onBack }: { onBack: () => void }) {
  const [proxyAddr, setProxyAddr] = useState('');
  const [enabled, setEnabled] = useState(false);
  const [flareAddr, setFlareAddr] = useState('127.0.0.1:8191');
  const [flareEnabled, setFlareEnabled] = useState(false);
  const [ghApi, setGhApi] = useState('https://api.github.com');
  const [ghToken, setGhToken] = useState('');
  const [ghTokenSet, setGhTokenSet] = useState(false);
  const [ghTokenHint, setGhTokenHint] = useState('');
  const [ghMirror, setGhMirror] = useState('');
  const [ghPresets, setGhPresets] = useState<{ url: string; label: string }[]>([]);
  const [loading, setLoading] = useState(true);
  const { msg, setMsg, busy, withBusy, run } = usePanelAction();

  function applyPublic(d: NetworkConfig) {
    setProxyAddr(toProxyHostPort(d.proxyUrl || ''));
    setEnabled(Boolean(d.proxyEnabled));
    setFlareAddr(toProxyHostPort(d.flareSolverrUrl || '') || '127.0.0.1:8191');
    setFlareEnabled(Boolean(d.flareSolverrEnabled));
  }

  function applyGithub(d: NetworkConfig) {
    setGhApi(d.githubApiUrl || 'https://api.github.com');
    setGhToken('');
    setGhTokenSet(Boolean(d.githubTokenSet));
    setGhTokenHint(d.githubTokenHint || '');
    setGhMirror(d.githubMirror || '');
    setGhPresets(d.githubMirrorPresets || []);
  }

  useEffect(() => {
    void (async () => {
      setLoading(true);
      try {
        const d = await getNetwork();
        applyPublic(d);
        applyGithub(d);
      } catch (e) {
        setMsg(e instanceof Error ? e.message : '读取失败');
      } finally {
        setLoading(false);
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  function proxyValue() {
    return proxyAddr.trim();
  }

  function flareValue() {
    return flareAddr.trim() || '127.0.0.1:8191';
  }

  async function persist(partial: {
    proxyEnabled?: boolean;
    proxyUrl?: string;
    flareSolverrEnabled?: boolean;
    flareSolverrUrl?: string;
  }) {
    return withBusy(async () => {
      const next = await putNetwork({
        proxyUrl: partial.proxyUrl ?? proxyValue(),
        proxyEnabled: partial.proxyEnabled ?? enabled,
        flareSolverrUrl: partial.flareSolverrUrl ?? flareValue(),
        flareSolverrEnabled: partial.flareSolverrEnabled ?? flareEnabled,
      });
      applyPublic(next);
      return next;
    });
  }

  async function onToggle(next: boolean) {
    if (next && !proxyValue()) {
      setMsg('请先填写主机和端口');
      return;
    }
    await run('保存失败', async () => {
      const saved = await persist({ proxyEnabled: next });
      setMsg(saved.configured ? '已启用代理' : '已关闭代理');
    });
  }

  async function onToggleFlare(next: boolean) {
    if (next && !flareValue()) {
      setMsg('请先填写 FlareSolverr 主机和端口');
      return;
    }
    await run('保存失败', async () => {
      const saved = await persist({
        flareSolverrEnabled: next,
        flareSolverrUrl: flareValue(),
      });
      setMsg(saved.flareSolverrConfigured ? '已启用过盾' : '已关闭过盾');
    });
  }

  async function onTest() {
    await run('代理测试失败', async () => {
      const r = await testNetwork({ proxyUrl: proxyValue() });
      setMsg(testResultText(r, '代理正常', '代理失败'));
    });
  }

  async function onTestFlare() {
    await run('FlareSolverr 测试失败', async () => {
      const r = await testFlareSolverr({ flareSolverrUrl: flareValue() });
      setMsg(testResultText(r, 'FlareSolverr 正常', 'FlareSolverr 失败'));
    });
  }

  async function onSave() {
    await run('保存失败', async () => {
      const url = proxyValue();
      const flare = flareValue();
      const saved = await persist({
        proxyUrl: url,
        proxyEnabled: Boolean(url) && enabled,
        flareSolverrUrl: flare,
        flareSolverrEnabled: Boolean(flare) && flareEnabled,
      });
      const bits: string[] = [];
      if (saved.configured) bits.push('代理已启用');
      else if (url) bits.push('代理已保存未启用');
      if (saved.flareSolverrConfigured) bits.push('过盾已启用');
      else if (flare) bits.push('过盾已保存未启用');
      setMsg(bits.length ? bits.join(' · ') : '已清空');
    });
  }

  async function onSaveGithub() {
    await run('保存失败', async () => {
      const next = await putNetwork({
        proxyUrl: proxyValue(),
        proxyEnabled: Boolean(proxyValue()) && enabled,
        flareSolverrUrl: flareValue(),
        flareSolverrEnabled: Boolean(flareValue()) && flareEnabled,
        githubApiUrl: ghApi.trim() || 'https://api.github.com',
        githubToken: ghToken.trim(),
        githubMirror: ghMirror,
      });
      applyPublic(next);
      applyGithub(next);
      setMsg('GitHub 配置已保存');
    });
  }

  const active = enabled && Boolean(proxyValue());
  const flareActive = flareEnabled && Boolean(flareValue());
  const locked = busy || loading;

  return (
    <AppPush title="网络代理" onBack={onBack}>
      <div className="network-panel">
        <ul className="settings-group">
          <li>
            <div className="settings-kv">
              <span className="settings-kv__key">状态</span>
              <span
                className={cn(
                  'settings-nav__status',
                  active || flareActive
                    ? 'settings-nav__status--ok'
                    : 'settings-nav__status--warn',
                )}
              >
                {loading
                  ? '…'
                  : active && flareActive
                    ? '代理 · Flare'
                    : active
                      ? '代理已启用'
                      : flareActive
                        ? 'Flare 已启用'
                        : '未启用'}
              </span>
            </div>
          </li>
        </ul>

        <p className="settings-group-label">HTTP 代理</p>
        <ul className="settings-group">
          <li>
            <div className="settings-kv">
              <span className="settings-kv__key">启用代理</span>
              <Switch
                checked={enabled}
                onCheckedChange={(v) => void onToggle(Boolean(v))}
                disabled={locked}
              />
            </div>
          </li>
          <li>
            <div className="settings-kv">
              <span className="settings-kv__key">地址</span>
              <input
                type="text"
                className="settings-kv__input allow-select"
                placeholder="127.0.0.1:7890"
                value={proxyAddr}
                onChange={(e) => setProxyAddr(e.target.value.trim())}
                autoCapitalize="off"
                autoCorrect="off"
                autoComplete="off"
                spellCheck={false}
                disabled={locked}
              />
            </div>
          </li>
        </ul>
        <div className="app-actions">
          <button
            type="button"
            className="app-btn-secondary"
            disabled={locked}
            onClick={() => void onTest()}
          >
            测试代理
          </button>
        </div>

        <p className="settings-group-label settings-group-label--spaced">
          FlareSolverr
        </p>
        <ul className="settings-group">
          <li>
            <div className="settings-kv">
              <span className="settings-kv__key">启用过盾</span>
              <Switch
                checked={flareEnabled}
                onCheckedChange={(v) => void onToggleFlare(Boolean(v))}
                disabled={locked}
              />
            </div>
          </li>
          <li>
            <div className="settings-kv">
              <span className="settings-kv__key">地址</span>
              <input
                type="text"
                className="settings-kv__input allow-select"
                placeholder="127.0.0.1:8191"
                value={flareAddr}
                onChange={(e) => setFlareAddr(e.target.value.trim())}
                autoCapitalize="off"
                autoCorrect="off"
                autoComplete="off"
                spellCheck={false}
                disabled={locked}
              />
            </div>
          </li>
        </ul>
        <div className="app-actions">
          <button
            type="button"
            className="app-btn-secondary"
            disabled={locked}
            onClick={() => void onTestFlare()}
          >
            测试 Flare
          </button>
          <button
            type="button"
            className="app-btn-primary"
            disabled={locked}
            onClick={() => void onSave()}
          >
            保存
          </button>
        </div>

        <p className="settings-group-label settings-group-label--spaced network-proxy-label">
          <span>GitHub API</span>
          <a
            className="settings-text-link"
            href="https://github.com/settings/tokens"
            target="_blank"
            rel="noreferrer noopener"
          >
            获取 Token
          </a>
        </p>
        <section className="app-section network-proxy-card">
          <div className="app-section-body">
            <label className="app-field">
              <span className="app-label">API 地址</span>
              <input
                type="text"
                className="allow-select"
                placeholder="https://api.github.com"
                value={ghApi}
                onChange={(e) => setGhApi(e.target.value.trim())}
                autoCapitalize="off"
                autoCorrect="off"
                autoComplete="off"
                spellCheck={false}
                disabled={locked}
              />
            </label>
            <label className="app-field">
              <span className="app-label">Token</span>
              <input
                type="password"
                className="allow-select"
                placeholder={
                  ghTokenSet
                    ? `已配置 ${ghTokenHint}，留空不修改`
                    : '可选，留空即匿名访问'
                }
                value={ghToken}
                onChange={(e) => setGhToken(e.target.value)}
                autoCapitalize="off"
                autoCorrect="off"
                autoComplete="off"
                spellCheck={false}
                disabled={locked}
              />
            </label>
          </div>
        </section>

        <p className="settings-group-label settings-group-label--spaced">
          GitHub 加速镜像
        </p>
        <section className="app-section network-proxy-card">
          <div className="app-section-body">
            <label className="app-field">
              <span className="app-label">镜像</span>
              <select
                className="allow-select"
                value={ghMirror}
                onChange={(e) => setGhMirror(e.target.value)}
                disabled={locked}
              >
                {(ghPresets.length
                  ? ghPresets
                  : [{ url: '', label: '不使用镜像（直连 GitHub）' }]
                ).map((p) => (
                  <option key={p.url} value={p.url}>
                    {p.label}
                  </option>
                ))}
              </select>
            </label>
          </div>
        </section>
        <div className="app-actions">
          <button
            type="button"
            className="app-btn-primary"
            disabled={locked}
            onClick={() => void onSaveGithub()}
          >
            保存 GitHub 配置
          </button>
        </div>

        <AppMsg allowSelect onDismiss={() => setMsg('')}>
          {msg}
        </AppMsg>
      </div>
    </AppPush>
  );
}
