'use client';

import { FolderOpen, RefreshCw, ShieldCheck } from 'lucide-react';
import type { CSSProperties } from 'react';
import { cn } from '@/lib/utils';
import { folderDisplayName, SAVE_SOURCES } from './format';
import { P115LoginCard } from './P115LoginCard';
import type { P115PanelState } from './useP115Panel';

function SourceRow({
  label,
  name,
  cid,
  onChange,
}: {
  label: string;
  name: string;
  cid: string;
  onChange: () => void;
}) {
  return (
    <li>
      <button type="button" className="settings-nav" onClick={onChange}>
        <span className="settings-nav__icon settings-nav__icon--orange" aria-hidden>
          <FolderOpen size={14} strokeWidth={2.25} />
        </span>
        <span className="settings-nav__main">
          <span className="settings-nav__title">{label}</span>
          <span className="settings-nav__desc allow-select">
            {name} · CID {cid || '0'}
          </span>
        </span>
        <span className="settings-inline-action">更改</span>
      </button>
    </li>
  );
}

export function P115Overview({ p }: { p: P115PanelState }) {
  const {
    quotaLoading,
    locked,
    refreshStatus,
    quotaUsed,
    quotaUsedRatio,
    quota,
    quotaTotal,
    quotaError,
    spaceRatio,
    spaceUsedText,
    spaceTotalText,
    hint,
    targets,
    account,
    configured,
    browseFolders,
  } = p;

  const vipLabel = account?.vip_forever
    ? '永久会员'
    : account?.vip_active
      ? account.vip_expire
        ? `会员至 ${account.vip_expire}`
        : '会员'
      : '普通用户';

  return (
    <div className="p115-console__pane">
      {!configured ? <P115LoginCard p={p} /> : null}
      {!configured ? null : (
        <>
      <section className="p115-account" aria-label="115 账号">
        <span
          className={cn(
            'p115-account__avatar',
            account?.vip_active && 'p115-account__avatar--vip',
            !account?.avatar && 'p115-account__avatar--fallback',
          )}
          aria-hidden
        >
          {account?.avatar ? (
            // 115 CDN 头像
            // eslint-disable-next-line @next/next/no-img-element
            <img src={account.avatar} alt="" referrerPolicy="no-referrer" />
          ) : (
            (account?.username || '1').slice(0, 1).toUpperCase()
          )}
        </span>
        <div className="p115-account__main">
          <div className="p115-account__name">{account?.username || hint || '115 账号'}</div>
          <div className="p115-account__meta">
            <span className={cn('p115-chip', account?.vip_active ? 'p115-chip--vip' : null)}>
              {vipLabel}
            </span>
            <span className="p115-chip p115-chip--ok">
              <ShieldCheck size={11} strokeWidth={2.5} aria-hidden />
              已登录
            </span>
          </div>
        </div>
        <button
          type="button"
          className="p115-account__refresh"
          disabled={quotaLoading || locked}
          onClick={() => void refreshStatus()}
          aria-label="刷新 115 状态"
        >
          <RefreshCw
            size={14}
            strokeWidth={2.25}
            className={cn(quotaLoading && 'p115-spin')}
            aria-hidden
          />
        </button>
      </section>

      <div className="p115-stats__grid">
        <div className="p115-stat">
          <div className="p115-stat__top">
            <span className="p115-stat__label">网盘空间</span>
            <span
              className="p115-stat__pct p115-stat__pct--heat"
              style={{ '--fill': spaceRatio ?? 0 } as CSSProperties}
            >
              {spaceRatio != null ? `${Math.round(spaceRatio * 100)}%` : ''}
            </span>
          </div>
          <div className="p115-stat__value allow-select">
            {spaceUsedText ? (
              <>
                <strong
                  className="p115-stat__used"
                  style={{ '--fill': spaceRatio ?? 0 } as CSSProperties}
                >
                  {spaceUsedText}
                </strong>
                <span className="p115-stat__den"> 已用</span>
              </>
            ) : (
              <span className="p115-stat__muted">
                {quotaLoading ? '读取中…' : '暂无数据'}
              </span>
            )}
          </div>
          {spaceRatio != null ? (
            <div
              className="p115-quota-bar p115-quota-bar--heat"
              style={{ '--fill': spaceRatio } as CSSProperties}
              role="meter"
              aria-valuemin={0}
              aria-valuemax={100}
              aria-valuenow={Math.round(spaceRatio * 100)}
              aria-label="网盘已用空间"
            >
              <span style={{ width: `${Math.round(spaceRatio * 100)}%` }} />
            </div>
          ) : (
            <div className="p115-quota-bar p115-quota-bar--empty" aria-hidden>
              <span style={{ width: '0%' }} />
            </div>
          )}
          <p className="p115-stat__hint allow-select">
            {spaceUsedText && spaceTotalText
              ? `已用 ${spaceUsedText} · 共 ${spaceTotalText}`
              : '容量占用'}
          </p>
        </div>

        <div className="p115-stat">
          <div className="p115-stat__top">
            <span className="p115-stat__label">云转存</span>
            <span
              className="p115-stat__pct p115-stat__pct--heat"
              style={{ '--fill': quotaUsedRatio ?? 0 } as CSSProperties}
            >
              {quotaUsedRatio != null ? `${Math.round(quotaUsedRatio * 100)}%` : ''}
            </span>
          </div>
          <div className="p115-stat__value allow-select">
            {quotaLoading && quotaUsed == null ? (
              <span className="p115-stat__muted">读取中…</span>
            ) : quotaUsed != null ? (
              <>
                <strong
                  className="p115-stat__used"
                  style={{ '--fill': quotaUsedRatio ?? 0 } as CSSProperties}
                >
                  {quotaUsed}
                </strong>
                {quotaTotal != null ? (
                  <span className="p115-stat__den"> / {quotaTotal}</span>
                ) : null}
              </>
            ) : (
              <span className="p115-stat__muted">{quotaError || '暂无数据'}</span>
            )}
          </div>
          {quotaUsedRatio != null ? (
            <div
              className="p115-quota-bar p115-quota-bar--heat"
              style={{ '--fill': quotaUsedRatio } as CSSProperties}
              role="meter"
              aria-valuemin={0}
              aria-valuemax={quotaTotal ?? 0}
              aria-valuenow={quotaUsed ?? 0}
              aria-label="云转存已用任务额度"
            >
              <span style={{ width: `${Math.round(quotaUsedRatio * 100)}%` }} />
            </div>
          ) : (
            <div className="p115-quota-bar p115-quota-bar--empty" aria-hidden>
              <span style={{ width: '0%' }} />
            </div>
          )}
          <p className="p115-stat__hint allow-select">
            {quota != null ? `已用任务额度 · 剩余 ${quota}` : '已用任务额度'}
          </p>
        </div>
      </div>

      <p className="settings-group-label">转存目录</p>
      <ul className="settings-group">
        {SAVE_SOURCES.map((src) => (
          <SourceRow
            key={src.key}
            label={src.label}
            name={folderDisplayName(targets[src.key])}
            cid={targets[src.key].folderCid}
            onChange={() => void browseFolders(src.key, targets[src.key].folderCid || '0')}
          />
        ))}
      </ul>
        </>
      )}
    </div>
  );
}
