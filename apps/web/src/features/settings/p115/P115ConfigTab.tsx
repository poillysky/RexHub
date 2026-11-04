'use client';

import { Folder, FolderOpen, KeyRound, QrCode } from 'lucide-react';
import { AppCenterModal } from '@/components/ui/AppCenterModal';
import { cn } from '@/lib/utils';
import { folderDisplayName, SAVE_SOURCES } from './format';
import type { P115PanelState } from './useP115Panel';

export function P115ConfigTab({ p }: { p: P115PanelState }) {
  const {
    locked,
    startQrLogin,
    qrBusy,
    qrOpen,
    qrSession,
    qrStatusLabel,
    qrApp,
    qrApps,
    cancelQrLogin,
    configured,
    authError,
    showCookieEdit,
    setShowCookieEdit,
    hint,
    cookie,
    setCookie,
    targets,
    browseFolders,
    busy,
    showBrowser,
    setShowBrowser,
    browseSource,
    folderPath,
    folders,
    browsing,
    selectFolder,
    onTest,
    onSave,
  } = p;

  return (
    <div className="p115-console__pane">
      <section className="p115-console__block">
        {!configured ? (
          <div className="p115-login-card p115-login-card--hero">
            <span className="p115-login-card__badge" aria-hidden>
              <QrCode size={18} strokeWidth={2.25} />
            </span>
            <div className="p115-login-card__copy">
              <p className="p115-login-card__title">115 网盘未登录</p>
              <p className="p115-login-card__desc">
                {authError
                  ? `登录态已失效：${authError}`
                  : '扫码或粘贴 Cookie 登录后，即可查看空间、目录和转存任务。'}
              </p>
            </div>
            <button
              type="button"
              className="app-btn-primary app-btn-block"
              disabled={locked}
              onClick={() => void startQrLogin()}
            >
              <QrCode size={15} strokeWidth={2.25} aria-hidden />
              {qrBusy ? '扫码中…' : '扫码登录 115'}
            </button>
          </div>
        ) : null}
        <div className="p115-cookie-head">
          <p className="settings-group-label">登录 Cookie</p>
        </div>

        {qrOpen ? (
          <div className="p115-qr">
            <div className="p115-qr__head">
              <span className="p115-qr__head-label">扫码客户端</span>
              <select
                className="p115-qr__select"
                aria-label="扫码客户端"
                value={qrApp}
                disabled={qrBusy}
                onChange={(e) => void startQrLogin(e.target.value)}
              >
                {qrApps.map((a) => (
                  <option key={a.key} value={a.key}>
                    {a.label}
                  </option>
                ))}
              </select>
            </div>
            <div className="p115-qr__frame">
              {qrSession?.qrImage ? (
                // eslint-disable-next-line @next/next/no-img-element
                <img
                  className="p115-qr__img"
                  src={qrSession.qrImage}
                  alt="115 登录二维码"
                />
              ) : (
                <p className="p115-qr__placeholder">
                  {qrBusy ? '生成中…' : '暂无二维码'}
                </p>
              )}
            </div>
            <p className="p115-qr__status">{qrStatusLabel || '等待扫码'}</p>
            <p className="p115-qr__hint">扫码后按所选客户端完成授权，Cookie 会自动保存。</p>
            <div className="p115-qr__actions">
              <button
                type="button"
                className="app-btn-secondary"
                onClick={() => void startQrLogin()}
              >
                刷新二维码
              </button>
              <button
                type="button"
                className="app-btn-secondary"
                onClick={cancelQrLogin}
              >
                取消
              </button>
            </div>
          </div>
        ) : null}

        {configured && !showCookieEdit ? (
          <div className="p115-login-card p115-login-card--compact">
            <div className="p115-login-card__row">
              <span className="settings-nav__icon settings-nav__icon--violet" aria-hidden>
                <KeyRound size={14} strokeWidth={2.25} />
              </span>
              <div className="p115-login-card__info">
                <span className="p115-login-card__title">已登录</span>
                <span className="p115-login-card__desc">{hint || '••••'}</span>
              </div>
              <button
                type="button"
                className="p115-qr-trigger"
                disabled={locked}
                onClick={() => setShowCookieEdit(true)}
              >
                更换
              </button>
            </div>
          </div>
        ) : (
          <>
            <div className="p115-cookie-card">
              <textarea
                className="p115-cookie-card__input allow-select"
                rows={4}
                placeholder="UID=…; CID=…; SEID=…; KID=…"
                value={cookie}
                onChange={(e) => setCookie(e.target.value)}
                autoCapitalize="off"
                autoCorrect="off"
                spellCheck={false}
                disabled={locked}
                aria-label="115 Cookie"
              />
            </div>
            {configured ? (
              <button
                type="button"
                className="settings-text-link"
                disabled={locked}
                onClick={() => {
                  setCookie('');
                  setShowCookieEdit(false);
                  cancelQrLogin();
                }}
              >
                取消更换
              </button>
            ) : null}
          </>
        )}
      </section>

      {configured ? (
        <section className="p115-console__block">
          <p className="settings-group-label">按入口保存目录</p>
          <ul className="settings-group">
            {SAVE_SOURCES.filter(
              (s) =>
                s.key === 'warehouse' || s.key === 'movie' || s.key === 'tv',
            ).map((src) => {
              const t = targets[src.key];
              return (
                <li key={src.key}>
                  <div className="settings-nav">
                    <span className="settings-nav__icon settings-nav__icon--orange" aria-hidden>
                      <FolderOpen size={14} strokeWidth={2.25} />
                    </span>
                    <span className="settings-nav__main">
                      <span className="settings-nav__title">{src.label}</span>
                      <span className="settings-nav__desc allow-select">
                        {folderDisplayName(t)} · CID {t.folderCid || '0'}
                        <span className="p115-target-hint"> · {src.desc}</span>
                      </span>
                    </span>
                    <button
                      type="button"
                      className="settings-inline-action"
                      disabled={locked}
                      onClick={() => void browseFolders(src.key, t.folderCid || '0')}
                    >
                      浏览
                    </button>
                  </div>
                </li>
              );
            })}
          </ul>
          <p className="settings-group-label" style={{ marginTop: 16 }}>
            片商分区
          </p>
          <ul className="settings-group">
            {SAVE_SOURCES.filter(
              (s) =>
                s.key !== 'warehouse' && s.key !== 'movie' && s.key !== 'tv',
            ).map((src) => {
              const t = targets[src.key];
              return (
                <li key={src.key}>
                  <div className="settings-nav">
                    <span className="settings-nav__icon settings-nav__icon--orange" aria-hidden>
                      <FolderOpen size={14} strokeWidth={2.25} />
                    </span>
                    <span className="settings-nav__main">
                      <span className="settings-nav__title">{src.label}</span>
                      <span className="settings-nav__desc allow-select">
                        {folderDisplayName(t)} · CID {t.folderCid || '0'}
                        <span className="p115-target-hint"> · {src.desc}</span>
                      </span>
                    </span>
                    <button
                      type="button"
                      className="settings-inline-action"
                      disabled={locked}
                      onClick={() => void browseFolders(src.key, t.folderCid || '0')}
                    >
                      浏览
                    </button>
                  </div>
                </li>
              );
            })}
          </ul>
        </section>
      ) : null}

      <AppCenterModal
        open={showBrowser}
        title={`选择${SAVE_SOURCES.find((s) => s.key === browseSource)?.label || ''}目录`}
        onClose={() => setShowBrowser(false)}
        cardClassName="p115-browser-modal"
        footer={
          <button
            type="button"
            className="app-btn-primary"
            style={{ flex: 1 }}
            onClick={() => {
              const cur = folderPath[folderPath.length - 1];
              if (cur) {
                selectFolder(cur);
                return;
              }
              selectFolder({ cid: '0', name: '根目录' });
            }}
          >
            {folderPath.length > 0 ? '选用当前路径' : '选用根目录'}
          </button>
        }
      >
        <div className="p115-browser p115-browser--modal">
          <nav className="p115-browser__path" aria-label="目录路径">
            {folderPath.length === 0 ? (
              <span className="p115-browser__crumb">
                <span className="p115-browser__link is-current">根目录</span>
              </span>
            ) : (
              folderPath.map((p, idx) => (
                <span key={`${p.cid}-${idx}`} className="p115-browser__crumb">
                  {idx > 0 ? <span className="p115-browser__sep">/</span> : null}
                  <button
                    type="button"
                    className={cn(
                      'p115-browser__link',
                      idx === folderPath.length - 1 && 'is-current',
                    )}
                    onClick={() => void browseFolders(browseSource, p.cid)}
                  >
                    {p.name}
                  </button>
                </span>
              ))
            )}
            <button
              type="button"
              className="p115-browser__refresh"
              disabled={browsing || locked}
              onClick={() => {
                const cur = folderPath[folderPath.length - 1];
                void browseFolders(browseSource, cur?.cid || '0');
              }}
            >
              刷新
            </button>
          </nav>
          <div className="p115-browser__list">
            {browsing ? (
              <p className="p115-browser__empty">加载中…</p>
            ) : folders.length === 0 ? (
              <p className="p115-browser__empty">此层无子文件夹，可选用当前路径</p>
            ) : (
              folders.map((f) => {
                const selectedCid = targets[browseSource].folderCid;
                const selected = f.cid === selectedCid;
                return (
                  <div
                    key={f.cid}
                    className={cn('p115-browser__row', selected && 'is-selected')}
                  >
                    <span className="p115-browser__fold" aria-hidden>
                      <Folder size={16} strokeWidth={2} />
                    </span>
                    <button
                      type="button"
                      className="p115-browser__name"
                      onClick={() => void browseFolders(browseSource, f.cid)}
                    >
                      {f.name}
                    </button>
                    <button
                      type="button"
                      className={cn('p115-browser__pick', selected && 'is-on')}
                      onClick={() => selectFolder(f)}
                    >
                      {selected ? '已选' : '选用'}
                    </button>
                  </div>
                );
              })
            )}
          </div>
        </div>
      </AppCenterModal>

      <div className="app-actions">
        <button
          type="button"
          className="app-btn-secondary"
          disabled={locked}
          onClick={() => void onTest()}
        >
          测试
        </button>
        <button
          type="button"
          className="app-btn-primary"
          style={{ flex: 1 }}
          disabled={locked}
          onClick={() => void onSave()}
        >
          保存
        </button>
      </div>
    </div>
  );
}
