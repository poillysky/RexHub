'use client';

/**
 * Postgres 库设置面板基座（色花资源库 / Bitmagnet 两个孪生面板的唯一实现）。
 *
 * 两者原先逐字符重复约 330 行（DSN 解析、加载探测、测试/保存流程、
 * 备份区、整段 JSX）；差异全部收敛在 `PostgresDbSpec` 里。
 */

import { useEffect, useRef, useState } from 'react';
import type { ReactNode } from 'react';
import { Database } from 'lucide-react';
import { useAuth } from '@/providers/AuthProvider';
import { Switch } from '@/components/ui/switch';
import { AppPush } from '@/components/ui/AppPush';
import { AppFootnote, AppMsg } from '@/components/ui/AppMsg';
import { cn } from '@/lib/utils';
import { DbDataBackupSection } from './DbDataBackupSection';
import { usePanelAction } from '@/hooks/usePanelAction';
import type {
  DbBackupProgress,
  ResourceDbBackupExportResult,
  ResourceDbBackupItem,
} from '@/lib/api';
import type { ResourceDbConfig } from '@/types/resource';

type DsnDefaults = { port: string; database: string };

type DsnParts = {
  host: string;
  port: string;
  user: string;
  database: string;
};

function parsePostgresDsn(
  dsn: string,
  defaults: DsnDefaults,
): {
  ok: boolean;
  host: string;
  port: string;
  user: string;
  database: string;
  password: string;
  hasPassword: boolean;
  query: string;
} {
  const fallback = {
    host: '',
    port: defaults.port,
    user: 'postgres',
    password: '',
    database: defaults.database,
    hasPassword: false,
    query: '',
  };
  const raw = dsn.trim();
  if (!raw) return { ...fallback, ok: true };
  try {
    const u = new URL(raw);
    const db = decodeURIComponent(
      (u.pathname.replace(/^\//, '').split('/')[0] || defaults.database).trim(),
    );
    return {
      ok: true,
      host: u.hostname || '',
      port: u.port || defaults.port,
      user: decodeURIComponent(u.username || 'postgres'),
      password: decodeURIComponent(u.password || ''),
      database: db || defaults.database,
      hasPassword: Boolean(u.password),
      // 查询参数（sslmode 等）不展示在表单里，但保存时必须原样带回
      query: u.search || '',
    };
  } catch {
    // 解析失败不能静默回退默认值：管理员一保存就会把原配置覆盖掉
    return { ...fallback, ok: false };
  }
}

function buildPostgresDsn(
  parts: DsnParts & { password: string },
  defaults: DsnDefaults,
  query = '',
): string {
  const user = encodeURIComponent(parts.user.trim() || 'postgres');
  const pass = encodeURIComponent(parts.password || '');
  const host = parts.host.trim() || '127.0.0.1';
  const port = parts.port.trim() || defaults.port;
  const database = encodeURIComponent(
    (parts.database.trim() || defaults.database).replace(/^\/+/, ''),
  );
  const search = query ? (query.startsWith('?') ? query : `?${query}`) : '';
  return `postgresql://${user}:${pass}@${host}:${port}/${database}${search}`;
}

export type PostgresDbSpec = {
  /** 面板标题 */
  title: string;
  /** 品牌图标；与设置首页入口保持一致，缺省时用通用数据库图标 */
  logo?: string;
  fallbackPort: string;
  fallbackDatabase: string;
  /** 备份目录提示（DbDataBackupSection） */
  dirHint: string;
  /** 非管理员视角的脚注说明 */
  footnote: string;
  get: () => Promise<ResourceDbConfig>;
  put: (body: {
    enabled: boolean;
    dsn: string;
    note: string;
  }) => Promise<ResourceDbConfig>;
  test: (dsn: string) => Promise<{ ok: boolean; message: string }>;
  listBackups: () => Promise<ResourceDbBackupItem[]>;
  exportBackup: () => Promise<ResourceDbBackupExportResult>;
  getProgress: () => Promise<DbBackupProgress>;
  uploadImportBackup: (file: File) => Promise<{
    filename: string;
    bytes: number;
    elapsedMs: number;
    tables: Array<{ name: string; rows: number }>;
  }>;
};

export function PostgresDbPanel({
  spec,
  onBack,
  title,
  extraRows,
}: {
  spec: PostgresDbSpec;
  onBack: () => void;
  /** 覆盖面板标题（如色花堂服务主页复用本面板） */
  title?: string;
  /** 追加在「启用查询」行下方的入口行 */
  extraRows?: ReactNode;
}) {
  const defaults: DsnDefaults = {
    port: spec.fallbackPort,
    database: spec.fallbackDatabase,
  };
  const { isAdmin } = useAuth();
  const savedPassword = useRef('');
  /** 原 DSN 的查询参数（sslmode 等），保存时原样带回 */
  const dsnQuery = useRef('');
  /** 加载期间用户已开始编辑：迟到的响应不能覆盖新输入 */
  const edited = useRef(false);
  /** 卸载后不再 setState（测试/保存是异步的，用户可能中途返回） */
  const mounted = useRef(true);
  /** 连接探测序号：迟到的旧请求不能覆盖更新的测试结果 */
  const testSeq = useRef(0);
  const [enabled, setEnabled] = useState(false);
  const [host, setHost] = useState('');
  const [port, setPort] = useState(spec.fallbackPort);
  const [user, setUser] = useState('postgres');
  const [password, setPassword] = useState('');
  const [passwordTouched, setPasswordTouched] = useState(false);
  const [database, setDatabase] = useState(spec.fallbackDatabase);
  const [note, setNote] = useState('');
  const [hasPassword, setHasPassword] = useState(false);
  const [connected, setConnected] = useState<boolean | null>(false);
  const [serverConfigured, setServerConfigured] = useState(false);
  const [parseError, setParseError] = useState('');
  const [backupBusy, setBackupBusy] = useState(false);
  const [pending, setPending] = useState<'test' | 'save' | null>(null);
  const { msg, setMsg, busy, run } = usePanelAction();

  useEffect(() => {
    mounted.current = true;
    let cancelled = false;
    void (async () => {
      try {
        const cfg = await spec.get();
        // 用户已经改过表单，丢弃这次过期响应
        if (cancelled || edited.current) return;
        const parsed = parsePostgresDsn(cfg.dsn || '', defaults);
        setEnabled(Boolean(cfg.enabled));
        setServerConfigured(Boolean(cfg.configured));
        setNote(cfg.note || '');
        if (!parsed.ok) {
          setParseError('已保存的连接串无法解析，请重新填写连接信息后保存');
          setConnected(false);
          return;
        }
        setParseError('');
        setHost(parsed.host);
        setPort(parsed.port);
        setUser(parsed.user);
        setDatabase(parsed.database);
        setHasPassword(parsed.hasPassword);
        savedPassword.current = parsed.password;
        dsnQuery.current = parsed.query;
        // 非管理员拿不到 DSN（后端已脱敏），也无权调用测试
        if (!isAdmin) {
          setConnected(null);
          return;
        }
        if (cfg.enabled && cfg.dsn) {
          setConnected(null);
          const seq = ++testSeq.current;
          try {
            const r = await spec.test(cfg.dsn);
            if (cancelled || seq !== testSeq.current) return;
            setConnected(r.ok);
          } catch {
            if (cancelled || seq !== testSeq.current) return;
            setConnected(false);
          }
        } else {
          setConnected(false);
        }
      } catch (e) {
        if (cancelled) return;
        setMsg(e instanceof Error ? e.message : '读取失败');
      }
    })();
    return () => {
      cancelled = true;
      mounted.current = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  function resolvePassword() {
    // 用户动过密码框就以输入为准（删空 = 清除已存密码）；不动则沿用已存密码。
    // 不 trim：密码首尾空格可能是有效字符。
    if (passwordTouched) return password;
    return hasPassword ? savedPassword.current : '';
  }

  function resolveDsn() {
    return buildPostgresDsn(
      {
        host,
        port,
        user,
        database,
        password: resolvePassword(),
      },
      defaults,
      dsnQuery.current,
    );
  }

  async function onTest() {
    if (!isAdmin) {
      setMsg('仅管理员可测试');
      return;
    }
    if (!host.trim()) {
      setMsg('请填写主机');
      return;
    }
    setPending('test');
    const seq = ++testSeq.current;
    try {
      await run(
        '测试失败',
        async () => {
          const r = await spec.test(resolveDsn());
          if (!mounted.current || seq !== testSeq.current) return;
          setConnected(r.ok);
          setMsg(r.ok ? '连接成功' : `失败：${r.message}`);
        },
        () => setConnected(false),
      );
    } finally {
      setPending(null);
    }
  }

  async function onSave() {
    if (!isAdmin) {
      setMsg('仅管理员可修改');
      return;
    }
    if (parseError) {
      setMsg(parseError);
      return;
    }
    if (!host.trim()) {
      setMsg('请填写主机');
      return;
    }
    setPending('save');
    try {
      await run('保存失败', async () => {
        const dsn = resolveDsn();
        await spec.put({ enabled, dsn, note });
        if (!mounted.current) return;
        const savedPwd = resolvePassword();
        savedPassword.current = savedPwd;
        setHasPassword(Boolean(savedPwd));
        setPassword('');
        setPasswordTouched(false);
        setMsg('已保存');
        if (enabled && dsn) {
          const seq = ++testSeq.current;
          try {
            const r = await spec.test(dsn);
            if (!mounted.current || seq !== testSeq.current) return;
            setConnected(r.ok);
            if (!r.ok) setMsg(`已保存，但连接失败：${r.message}`);
          } catch {
            if (!mounted.current || seq !== testSeq.current) return;
            setConnected(null);
          }
        } else {
          setConnected(false);
        }
      });
    } finally {
      setPending(null);
    }
  }

  function fillDefaults() {
    edited.current = true;
    setParseError('');
    setHost('127.0.0.1');
    setPort(spec.fallbackPort);
    setUser('postgres');
    setDatabase(spec.fallbackDatabase);
    // 默认值对应本机连接，原 DSN 的 sslmode 等参数一并丢弃
    dsnQuery.current = '';
    setMsg('已填入默认值');
  }

  const statusText = !isAdmin
    ? serverConfigured
      ? '已配置'
      : '未配置'
    : connected === null
      ? '检测中'
      : connected
        ? '已连接'
        : enabled
          ? '连接失败'
          : host.trim()
            ? '未启用'
            : '未配置';
  const statusTone = !isAdmin
    ? serverConfigured
      ? 'ok'
      : 'warn'
    : connected === true
      ? 'ok'
      : connected === null
        ? 'mute'
        : 'warn';

  const locked = !isAdmin || busy || backupBusy;

  return (
    <AppPush title={title ?? spec.title} onBack={onBack}>
      <div className="svc-panel">
      <ul className="settings-group">
        <li>
          <div className="settings-kv">
            <span className="settings-kv__key">状态</span>
            <span
              className={cn(
                'settings-nav__status',
                statusTone === 'ok' && 'settings-nav__status--ok',
                statusTone === 'warn' && 'settings-nav__status--warn',
              )}
            >
              {statusText}
            </span>
          </div>
        </li>
        <li>
          <div className="settings-nav">
            <span
              className={cn(
                'settings-nav__icon',
                spec.logo ? 'settings-nav__icon--brand' : 'settings-nav__icon--teal',
              )}
              aria-hidden
            >
              {spec.logo ? (
                <img src={spec.logo} alt="" width={26} height={26} decoding="async" />
              ) : (
                <Database size={14} strokeWidth={2.25} />
              )}
            </span>
            <span className="settings-nav__main">
              <span className="settings-nav__title">启用查询</span>
              <span className="settings-nav__desc">{spec.title} · 资源检索</span>
            </span>
            <Switch
              checked={enabled}
              onCheckedChange={(v) => {
                edited.current = true;
                setEnabled(v);
              }}
              disabled={locked}
            />
          </div>
        </li>
        {extraRows}
      </ul>

      <p className="settings-group-label">连接信息</p>
      <section className="app-section">
        <div className="app-section-body">
          <label className="app-field">
            <span className="app-label">主机</span>
            <input
              className="allow-select"
              placeholder="192.168.x.x"
              value={host}
              onChange={(e) => {
                edited.current = true;
                setParseError('');
                setHost(e.target.value);
              }}
              disabled={locked}
              autoCapitalize="off"
              autoCorrect="off"
              autoComplete="off"
              spellCheck={false}
            />
          </label>
          <label className="app-field">
            <span className="app-label">端口</span>
            <input
              className="allow-select"
              placeholder={spec.fallbackPort}
              value={port}
              onChange={(e) => {
                edited.current = true;
                setParseError('');
                setPort(e.target.value);
              }}
              disabled={locked}
              inputMode="numeric"
              autoComplete="off"
            />
          </label>
          <label className="app-field">
            <span className="app-label">库名</span>
            <input
              className="allow-select"
              placeholder={spec.fallbackDatabase}
              value={database}
              onChange={(e) => {
                edited.current = true;
                setParseError('');
                setDatabase(e.target.value);
              }}
              disabled={locked}
              autoCapitalize="off"
              autoComplete="off"
              spellCheck={false}
            />
          </label>
        </div>
      </section>

      {parseError ? (
        <AppMsg onDismiss={() => setParseError('')}>{parseError}</AppMsg>
      ) : null}

      <p className="settings-group-label">登录凭据</p>
      <section className="app-section">
        <div className="app-section-body">
          <label className="app-field">
            <span className="app-label">用户</span>
            <input
              className="allow-select"
              placeholder="postgres"
              value={user}
              onChange={(e) => {
                edited.current = true;
                setParseError('');
                setUser(e.target.value);
              }}
              disabled={locked}
              autoCapitalize="off"
              autoComplete="username"
            />
          </label>
          <label className="app-field">
            <span className="app-label">密码</span>
            <input
              className="allow-select"
              type="password"
              placeholder={hasPassword ? '已保存，留空不改' : '可留空'}
              value={password}
              onChange={(e) => {
                edited.current = true;
                setPasswordTouched(true);
                setPassword(e.target.value);
              }}
              disabled={locked}
              autoComplete="new-password"
            />
          </label>
        </div>
      </section>

      {isAdmin ? (
        <>
          <DbDataBackupSection
            dirHint={spec.dirHint}
            disabled={busy}
            listBackups={spec.listBackups}
            exportBackup={spec.exportBackup}
            getProgress={spec.getProgress}
            uploadImportBackup={spec.uploadImportBackup}
            onMessage={setMsg}
            onBusyChange={setBackupBusy}
          />

          <div className="app-actions">
            <button
              type="button"
              className="app-btn-secondary"
              disabled={locked}
              onClick={fillDefaults}
            >
              默认值
            </button>
            <button
              type="button"
              className="app-btn-secondary"
              disabled={locked}
              onClick={() => void onTest()}
            >
              {pending === 'test' ? '测试中…' : '测试'}
            </button>
            <button
              type="button"
              className="app-btn-primary"
              style={{ flex: 1 }}
              disabled={locked || Boolean(parseError)}
              onClick={() => void onSave()}
            >
              {pending === 'save' ? '保存中…' : '保存'}
            </button>
          </div>
          <AppMsg allowSelect onDismiss={() => setMsg('')}>
            {msg}
          </AppMsg>
        </>
      ) : (
        <AppFootnote>{spec.footnote}</AppFootnote>
      )}
      </div>
    </AppPush>
  );
}
