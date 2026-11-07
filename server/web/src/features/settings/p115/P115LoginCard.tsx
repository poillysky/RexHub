'use client';

import { KeyRound, QrCode } from 'lucide-react';
import { useRef } from 'react';
import type { P115PanelState } from './useP115Panel';

/** 115 登录卡片：扫码 / Cookie 登录，未登录时展示在概览页顶部 */
export function P115LoginCard({ p }: { p: P115PanelState }) {
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
    onTest,
    onSave,
  } = p;
  /** 点「取消更换」时失焦不应触发自动保存 */
  const skipBlurSave = useRef(false);

  return (
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
              <img className="p115-qr__img" src={qrSession.qrImage} alt="115 登录二维码" />
            ) : (
              <p className="p115-qr__placeholder">{qrBusy ? '生成中…' : '暂无二维码'}</p>
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
            <button type="button" className="app-btn-secondary" onClick={cancelQrLogin}>
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
              onBlur={() => {
                if (skipBlurSave.current) {
                  skipBlurSave.current = false;
                  return;
                }
                if (!locked && cookie.trim()) void onSave();
              }}
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
              onMouseDown={() => {
                skipBlurSave.current = true;
              }}
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

      {!showCookieEdit && configured ? null : (
        <div className="app-actions">
          <button
            type="button"
            className="app-btn-secondary"
            disabled={locked}
            onClick={() => void onTest()}
          >
            测试
          </button>
        </div>
      )}
    </section>
  );
}
