'use client';

import { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import {
  Check,
  ChevronRight,
  ExternalLink,
  LayoutGrid,
  Link2,
  RotateCcw,
  Trash2,
} from 'lucide-react';
import { AppPush } from '@/components/ui/AppPush';
import { AppCenterModal } from '@/components/ui/AppCenterModal';
import { API_BASE, apiFetch, parseError } from '@/lib/api';
import { getThemeMode, setThemeMode, subscribeTheme, type ThemeMode } from '@/lib/theme';

const OPTIONS: { id: ThemeMode; title: string; desc: string }[] = [
  { id: 'system', title: '跟随系统', desc: '随设备的深浅色自动切换' },
  { id: 'light', title: '浅色', desc: '始终使用浅色外观' },
  { id: 'dark', title: '深色', desc: '始终使用深色外观' },
];

/** 列表与入口共用的显示名：优先展示仓库路径，没有路径时退回域名 */
function libraryName(url: string): string {
  try {
    const u = new URL(url);
    const path = u.pathname.replace(/^\/+|\/+$/g, '');
    return path || u.host;
  } catch {
    return url;
  }
}

/** 只对 GitHub 仓库做在线预览，其他站点直接外链打开 */
function githubRepo(url: string): { owner: string; repo: string } | null {
  try {
    const u = new URL(url);
    if (u.hostname !== 'github.com' && u.hostname !== 'www.github.com') return null;
    const [owner, repo] = u.pathname.replace(/^\/+/, '').split('/');
    if (!owner || !repo) return null;
    return { owner, repo: repo.replace(/\.git$/, '') };
  } catch {
    return null;
  }
}

/** JSON 清单型图标库：服务端直接读取 name + url 列表 */
function isJsonLibrary(url: string): boolean {
  try {
    return new URL(url).pathname.toLowerCase().endsWith('.json');
  } catch {
    return false;
  }
}

/** 仅忽略协议/主机大小写与末尾斜杠，路径大小写敏感（GitHub 上是不同仓库） */
function normalizeLibrary(url: string): string {
  try {
    const u = new URL(url);
    return `${u.protocol}//${u.host}${u.pathname.replace(/\/+$/, '')}${u.search}`;
  } catch {
    return url.trim();
  }
}

function sameLibraries(a: string[], b: string[]): boolean {
  return a.length === b.length && a.every((value, index) => value === b[index]);
}

/** 仓库/清单自带的介绍，取不到就不占位 */
function LibraryDescription({ url }: { url: string }) {
  const [text, setText] = useState('');
  useEffect(() => {
    let alive = true;
    apiFetch(`/settings/icon-libraries/info?url=${encodeURIComponent(url)}`)
      .then((res) => (res.ok ? res.json() : null))
      .then((data: { description?: string } | null) => {
        if (alive && data?.description) setText(String(data.description));
      })
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, [url]);
  return text ? <span className="icon-lib-row__desc">{text}</span> : null;
}

type PreviewIcon = { name: string; repo: string; path: string; src?: string };

type PreviewState = {
  loading: boolean;
  error: string | null;
  version: string;
  icons: PreviewIcon[];
};

const PAGE_SIZE = 60;

// 封面响应会被浏览器长期缓存，挑选规则变更时递增，避免继续用旧图标
const COVER_REV = 2;

export function AppearancePanel({ onBack }: { onBack: () => void }) {
  // 服务端快照固定「跟随系统」，hydration 后再切到本地存储的真实值
  const mode = useSyncExternalStore(
    subscribeTheme,
    getThemeMode,
    () => 'system' as ThemeMode,
  );
  const [sub, setSub] = useState<'icons' | null>(null);
  const [libraries, setLibraries] = useState<string[]>([]);
  const [defaults, setDefaults] = useState<string[]>([]);
  const [draft, setDraft] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [preview, setPreview] = useState<string | null>(null);
  const [shown, setShown] = useState(PAGE_SIZE);
  const [previewState, setPreviewState] = useState<PreviewState>({
    loading: false,
    error: null,
    version: 'HEAD',
    icons: [],
  });
  // 每次请求递增，关闭弹窗或重新预览时丢弃过期响应
  const previewRequest = useRef(0);

  async function loadPreview(url: string) {
    const requestId = ++previewRequest.current;
    setShown(PAGE_SIZE);
    setPreviewState({ loading: true, error: null, version: 'HEAD', icons: [] });
    try {
      const res = await apiFetch(`/settings/icon-libraries/preview?url=${encodeURIComponent(url)}`);
      if (!res.ok) throw new Error(await parseError(res));
      const data = (await res.json()) as { total: number; version: string; icons: PreviewIcon[] };
      if (requestId !== previewRequest.current) return;
      setPreviewState({
        loading: false,
        error: data.icons.length ? null : '该仓库里没有可预览的图标文件',
        version: data.version,
        icons: data.icons,
      });
    } catch (e) {
      if (requestId !== previewRequest.current) return;
      setPreviewState({
        loading: false,
        error: (e as Error).message || '预览加载失败',
        version: 'HEAD',
        icons: [],
      });
    }
  }

  function openPreview(url: string) {
    setPreview(url);
    void loadPreview(url);
  }

  function closePreview() {
    previewRequest.current += 1;
    setPreview(null);
  }

  // 图标库配置保存在服务端，所有设备共用一份
  useEffect(() => {
    let alive = true;
    apiFetch('/settings/icon-libraries')
      .then(
        async (res) =>
          res.ok ? ((await res.json()) as { urls: string[]; defaults?: string[] }) : null,
      )
      .then((data) => {
        if (!alive || !data) return;
        setLibraries(data.urls ?? []);
        setDefaults(data.defaults ?? []);
      })
      .catch(() => {
        /* 读取失败时保持空列表，不阻塞外观设置 */
      });
    return () => {
      alive = false;
    };
  }, []);

  async function save(next: string[]) {
    const previous = libraries;
    setLibraries(next);
    setBusy(true);
    setError(null);
    try {
      const res = await apiFetch('/settings/icon-libraries', {
        method: 'PUT',
        body: JSON.stringify({ urls: next }),
      });
      if (!res.ok) {
        setLibraries(previous);
        setError(await parseError(res));
        return;
      }
      const data = (await res.json()) as { urls: string[] };
      setLibraries(data.urls ?? next);
    } catch {
      setLibraries(previous);
      setError('保存失败，请重试');
    } finally {
      setBusy(false);
    }
  }

  function add() {
    const value = draft.trim();
    if (!value || busy) return;
    if (!/^https?:\/\/\S+$/i.test(value)) {
      setError('请输入以 http 或 https 开头的完整链接');
      return;
    }
    const normalized = normalizeLibrary(value);
    if (libraries.some((url) => normalizeLibrary(url) === normalized)) {
      setError('该链接已在列表中');
      return;
    }
    setDraft('');
    void save([...libraries, value]);
  }

  const librarySummary = libraries.length ? `${libraries.length} 个` : '未配置';

  if (sub === 'icons') {
    return (
      <AppPush
        title="图标库"
        onBack={() => setSub(null)}
        scrollMode="top"
        right={
          defaults.length && !sameLibraries(libraries, defaults) ? (
            <button
              type="button"
              className="icon-lib-reset"
              disabled={busy}
              onClick={() => void save(defaults)}
            >
              <RotateCcw size={14} strokeWidth={2.2} aria-hidden />
              恢复推荐
            </button>
          ) : null
        }
      >
        <div className="appearance-panel">
          <div className="icon-lib-add">
            <Link2 size={17} strokeWidth={2} aria-hidden className="icon-lib-add__icon" />
            <input
              className="icon-lib-add__input"
              type="url"
              inputMode="url"
              autoCapitalize="off"
              autoCorrect="off"
              spellCheck={false}
              placeholder="https://github.com/owner/repo"
              value={draft}
              onChange={(e) => {
                setDraft(e.target.value);
                setError(null);
              }}
              onKeyDown={(e) => {
                if (e.key === 'Enter') add();
              }}
            />
            <button
              type="button"
              className="icon-lib-add__btn"
              onClick={add}
              disabled={!draft.trim() || busy}
            >
              添加
            </button>
          </div>

          {libraries.length ? (
            <ul className="settings-group">
              {libraries.map((url) => (
                <li key={url} className="icon-lib-row">
                  <button
                    type="button"
                    className="icon-lib-row__open"
                    onClick={() => openPreview(url)}
                  >
                    <span className="icon-lib-row__mark" aria-hidden>
                      <LayoutGrid size={15} strokeWidth={2.2} />
                      <img
                        className="icon-lib-row__cover"
                        src={`${API_BASE}/settings/icon-libraries/cover?url=${encodeURIComponent(url)}&v=${COVER_REV}`}
                        alt=""
                        loading="lazy"
                        decoding="async"
                        onError={(event) => {
                          const img = event.currentTarget;
                          // 上游偶发超时就重试一次，仍失败才露出兜底图标
                          if (img.dataset.retried) {
                            img.remove();
                            return;
                          }
                          img.dataset.retried = '1';
                          img.src = `${img.src}&retry=1`;
                        }}
                      />
                    </span>
                    <span className="icon-lib-row__main">
                      <span className="icon-lib-row__title">{libraryName(url)}</span>
                      <LibraryDescription url={url} />
                      <span className="icon-lib-row__desc">{url}</span>
                    </span>
                  </button>
                  <button
                    type="button"
                    className="icon-lib-row__del"
                    aria-label={`删除 ${url}`}
                    disabled={busy}
                    onClick={() => {
                      if (!window.confirm(`确定删除 ${libraryName(url)}？该配置所有设备共用。`)) {
                        return;
                      }
                      void save(libraries.filter((u) => u !== url));
                    }}
                  >
                    <Trash2 size={16} strokeWidth={1.9} aria-hidden />
                  </button>
                </li>
              ))}
            </ul>
          ) : (
            <p className="app-hint">列表为空表示不使用在线图标库。</p>
          )}

          {error ? <p className="app-hint icon-lib-error">{error}</p> : null}

          <AppCenterModal
            open={preview !== null}
            title={preview ? libraryName(preview) : '图标库预览'}
            onClose={closePreview}
            cardClassName="icon-lib-preview"
            footer={
              preview ? (
                <a
                  className="app-btn-secondary icon-lib-preview__open"
                  href={preview}
                  target="_blank"
                  rel="noreferrer"
                >
                  <ExternalLink size={15} strokeWidth={2} aria-hidden />
                  在浏览器中打开
                </a>
              ) : null
            }
          >
            {preview && !githubRepo(preview) && !isJsonLibrary(preview) ? (
              <p className="app-hint icon-lib-preview__note">
                仅 GitHub 仓库支持在线预览，其他地址可直接在浏览器打开。
              </p>
            ) : previewState.loading ? (
              <p className="app-hint icon-lib-preview__note">正在读取仓库内容…</p>
            ) : previewState.error ? (
              <>
                <p className="app-hint icon-lib-preview__note">{previewState.error}</p>
                <button
                  type="button"
                  className="icon-lib-preview__more"
                  onClick={() => {
                    if (preview) void loadPreview(preview);
                  }}
                >
                  重试
                </button>
              </>
            ) : (
              <>
                <p className="app-hint icon-lib-preview__note">
                  共 {previewState.icons.length} 个图标，已显示{' '}
                  {Math.min(shown, previewState.icons.length)} 个
                </p>
                <div className="icon-lib-preview__grid">
                  {previewState.icons.slice(0, shown).map((icon) => (
                    <figure key={icon.path} className="icon-lib-preview__cell">
                      <img
                        src={
                          icon.src
                            ? `${API_BASE}${icon.src}`
                            : `${API_BASE}/settings/icon-libraries/thumb?repo=${encodeURIComponent(
                                icon.repo,
                              )}&path=${encodeURIComponent(icon.path)}&ref=${encodeURIComponent(
                                previewState.version,
                              )}`
                        }
                        alt={icon.name}
                        loading="lazy"
                        decoding="async"
                      />
                    </figure>
                  ))}
                </div>
                {shown < previewState.icons.length ? (
                  <button
                    type="button"
                    className="icon-lib-preview__more"
                    onClick={() => setShown((n) => n + PAGE_SIZE)}
                  >
                    加载更多（剩余 {previewState.icons.length - shown}）
                  </button>
                ) : null}
              </>
            )}
          </AppCenterModal>
        </div>
      </AppPush>
    );
  }

  return (
    <AppPush title="外观" onBack={onBack}>
      <div className="appearance-panel">
        <p className="settings-group-label">主题</p>
        <ul className="settings-group" role="radiogroup" aria-label="主题">
          {OPTIONS.map((opt) => (
            <li key={opt.id}>
              <button
                type="button"
                className="settings-nav"
                role="radio"
                aria-checked={mode === opt.id}
                onClick={() => setThemeMode(opt.id)}
              >
                <span className="settings-nav__main">
                  <span className="settings-nav__title">{opt.title}</span>
                  <span className="settings-nav__desc">{opt.desc}</span>
                </span>
                <span className="settings-nav__trail">
                  {mode === opt.id ? (
                    <Check
                      className="appearance-panel__check"
                      size={18}
                      strokeWidth={2.6}
                      aria-hidden
                    />
                  ) : null}
                </span>
              </button>
            </li>
          ))}
        </ul>

        <p className="settings-group-label">图标</p>
        <ul className="settings-group">
          <li>
            <button type="button" className="settings-nav" onClick={() => setSub('icons')}>
              <span className="settings-nav__main">
                <span className="settings-nav__title">图标库</span>
                <span className="settings-nav__desc">在线图标库地址，全设备共用</span>
              </span>
              <span className="settings-nav__trail">
                <span className="settings-nav__status">{librarySummary}</span>
                <ChevronRight size={16} strokeWidth={2.4} aria-hidden className="settings-nav__chev" />
              </span>
            </button>
          </li>
        </ul>
      </div>
    </AppPush>
  );
}
