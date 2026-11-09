'use client';

import {
  AlertCircle,
  CheckCircle2,
  Clock3,
  FolderOpen,
  KeyRound,
  LoaderCircle,
  Play,
  RefreshCw,
  Square,
  Workflow,
} from 'lucide-react';
import { useState } from 'react';
import { AppCenterModal } from '@/components/ui/AppCenterModal';
import { cn } from '@/lib/utils';
import { folderDisplayName, formatBytes } from './format';
import { P115FlowTab } from './P115FlowTab';
import type { P115PanelState } from './useP115Panel';
import type { P115ExtractItem } from '@/lib/api';

type TaskTone = 'ok' | 'warn' | 'run' | 'wait' | 'mute';

function itemTone(item: P115ExtractItem): TaskTone {
  if (item.state === 'done') return 'ok';
  if (item.state === 'failed') return 'warn';
  if (item.state === 'running') return 'run';
  if (item.state === 'waiting') return 'wait';
  return 'mute';
}

/** 右侧小标签只描述状态：执行中 / 等待复查 / 排队中，避免两个任务都叫「解压中」 */
function stateChip(item: P115ExtractItem): string {
  if (item.state === 'done') return '已完成';
  if (item.state === 'failed') return '失败';
  if (item.state === 'running') return '执行中';
  if (item.state === 'waiting') return '等待复查';
  return '排队中';
}

/** 通道标签：云端 / 本地，两条通道可能同时在跑 */
function laneLabel(item: P115ExtractItem): string {
  return item.lane === 'local' ? '本地' : '云端';
}

/** 明细行：状态 + 具体阶段，等待中的任务明确写清「没有在跑」 */
function stateLine(item: P115ExtractItem): string {
  if (item.state === 'done') return '已完成';
  if (item.state === 'failed') return '已失败';
  const stage = item.stage || '';
  if (item.state === 'running') return stage ? `正在执行 · ${stage}` : '正在执行';
  if (item.state === 'waiting') return stage ? `等待复查 · ${stage}` : '等待复查';
  return stage ? `排队等待 · ${stage}` : '排队等待';
}

export function P115ExtractTab({ p }: { p: P115PanelState }) {
  const {
    settingsLocked,
    extractConfig,
    extractStatus,
    extractPreview,
    extractPreviewBusy,
    refreshExtractPreview,
    extractBusy,
    extractError,
    browseFolders,
    onSaveExtract,
    onStartExtract,
    onStopExtract,
  } = p;

  const [pwdOpen, setPwdOpen] = useState(false);
  const [pwdDraft, setPwdDraft] = useState('');
  const [flowOpen, setFlowOpen] = useState(false);
  const running = Boolean(extractStatus?.running);
  const scanning = Boolean(extractStatus?.scanning);
  const items = extractStatus?.items ?? [];
  const counts = extractStatus?.counts;
  // 队列结果只对当前目录有效；换了目录先展示新目录的扫描清单
  const sameFolder = Boolean(extractStatus) && extractStatus?.folderCid === extractConfig.folderCid;
  const showStatus = sameFolder && items.length > 0;
  const displayItems = showStatus ? items : extractPreview ?? [];
  const previewItems = extractPreview ?? [];
  const previewPending = previewItems.filter((item) => item.state === 'queued').length;
  const previewSkipped = previewItems.filter((item) => item.state === 'failed').length;

  async function savePassword() {
    await onSaveExtract({ password: pwdDraft });
    setPwdOpen(false);
  }

  return (
    <div className="p115-console__pane">
      <section className="p115-console__block">
        <p className="settings-group-label">解压设置</p>
        <ul className="settings-group">
          <li>
            <div className="settings-nav">
              <span className="settings-nav__icon settings-nav__icon--orange" aria-hidden>
                <FolderOpen size={14} strokeWidth={2.25} />
              </span>
              <span className="settings-nav__main">
                <span className="settings-nav__title allow-select">
                  {folderDisplayName(extractConfig)}
                </span>
                <span className="settings-nav__desc allow-select">
                  解压目录 · CID {extractConfig.folderCid || '0'}
                </span>
              </span>
              <button
                type="button"
                className="settings-inline-action"
                disabled={settingsLocked || running}
                onClick={() => void browseFolders('extract', extractConfig.folderCid || '0')}
              >
                浏览
              </button>
            </div>
          </li>
          <li>
            <div className="settings-nav">
              <span className="settings-nav__icon settings-nav__icon--green" aria-hidden>
                <KeyRound size={14} strokeWidth={2.25} />
              </span>
              <span className="settings-nav__main">
                <span className="settings-nav__title">解压密码</span>
                <span className="settings-nav__desc allow-select">
                  {extractConfig.password || '未设置 · 自动尝试常见密码'}
                </span>
              </span>
              <button
                type="button"
                className="settings-inline-action"
                disabled={settingsLocked || running}
                onClick={() => {
                  setPwdDraft(extractConfig.password);
                  setPwdOpen(true);
                }}
              >
                {extractConfig.password ? '修改' : '设置'}
              </button>
            </div>
          </li>
          <li>
            <div className="settings-nav">
              <span className="settings-nav__icon settings-nav__icon--indigo" aria-hidden>
                <Workflow size={14} strokeWidth={2.25} />
              </span>
              <span className="settings-nav__main">
                <span className="settings-nav__title">解压流程</span>
                <span className="settings-nav__desc">云端解压 / 本地兜底完整拓扑</span>
              </span>
              <button
                type="button"
                className="settings-inline-action"
                onClick={() => setFlowOpen(true)}
              >
                查看
              </button>
            </div>
          </li>
        </ul>

        <div className="app-actions">
          <button
            type="button"
            className="app-btn-secondary"
            disabled={settingsLocked || extractBusy || extractPreviewBusy || running}
            onClick={() => void refreshExtractPreview(extractConfig.folderCid)}
          >
            {extractPreviewBusy ? (
              <LoaderCircle size={14} strokeWidth={2.25} className="p115-spin" aria-hidden />
            ) : (
              <RefreshCw size={14} strokeWidth={2.25} aria-hidden />
            )}
            扫描
          </button>
          {running ? (
            <button
              type="button"
              className="app-btn-secondary"
              disabled={settingsLocked || extractBusy}
              onClick={() => void onStopExtract()}
            >
              <Square size={14} strokeWidth={2.25} aria-hidden />
              停止
            </button>
          ) : (
            <button
              type="button"
              className="app-btn-primary"
              style={{ flex: 1 }}
              disabled={settingsLocked || extractBusy}
              onClick={() => void onStartExtract()}
            >
              <Play size={14} strokeWidth={2.25} aria-hidden />
              开始解压
            </button>
          )}
        </div>
        {extractError ? <p className="p115-stat__hint">{extractError}</p> : null}
      </section>

      <section className="p115-console__block">
        <div className="p115-cookie-head">
          <p className="settings-group-label">解压进度</p>
          <span className="p115-task__meta allow-select">
            {sameFolder && counts && counts.total > 0
              ? `共 ${counts.total} · 完成 ${counts.done} · 失败 ${counts.failed} · 等待复查 ${counts.waiting} · 执行/排队 ${counts.queued}`
              : previewPending || previewSkipped
                ? `待解压 ${previewPending}${previewSkipped ? ` · 跳过 ${previewSkipped}` : ''}`
                : extractPreviewBusy
                  ? '扫描中…'
                  : '未扫描'}
          </span>
        </div>

        {scanning || running ? (
          <p className="p115-stat__hint">
            {scanning
              ? '正在扫描目录…'
              : '云端 / 本地两条通道各跑一个任务，其余任务排队或按计划等待复查'}
          </p>
        ) : null}

        {displayItems.length === 0 ? (
          <div className="p115-tasks-empty">
            <span className="p115-tasks-empty__icon" aria-hidden>
              <Clock3 size={22} strokeWidth={1.75} />
            </span>
            <p>
              {extractPreviewBusy
                ? '正在读取目录…'
                : extractPreview
                  ? '目录下没有可解压的压缩包'
                  : '暂无解压任务'}
            </p>
            <span>
              {extractPreview
                ? '只扫描该目录下一层的 zip / rar / 7z，分卷压缩包自动跳过。'
                : '点「扫描」列出该目录的压缩包，确认后点「开始解压」按顺序处理。'}
            </span>
          </div>
        ) : (
          <ul className="p115-tasks" aria-label="解压任务列表">
            {displayItems.map((item, idx) => {
              const tone = itemTone(item);
              const pct = Math.max(0, Math.min(100, Math.round(Number(item.percent) || 0)));
              return (
                <li key={`${item.id}-${idx}`} className={cn('p115-task', `p115-task--${tone}`)}>
                  <span className={cn('p115-task__mark', `is-${tone}`)} aria-hidden>
                    {tone === 'ok' ? (
                      <CheckCircle2 size={15} strokeWidth={2.1} />
                    ) : tone === 'warn' ? (
                      <AlertCircle size={15} strokeWidth={2.1} />
                    ) : tone === 'run' ? (
                      <LoaderCircle size={15} strokeWidth={2.1} className="p115-spin" />
                    ) : (
                      <Clock3 size={15} strokeWidth={2.1} />
                    )}
                  </span>
                  <div className="p115-task__body">
                    <p className="p115-task__name allow-select">{item.name}</p>
                    <p className="p115-task__line allow-select">
                      {stateLine(item)} · {laneLabel(item)} · {formatBytes(item.size)}
                      {item.attempts > 0 ? ` · 第 ${item.attempts} 次等待` : ''}
                    </p>
                    {pct > 0 || item.state === 'running' ? (
                      <div
                        className={cn(
                          'p115-task__bar',
                          `is-${tone}`,
                          pct <= 0 && item.state === 'running' ? 'is-indeterminate' : '',
                        )}
                        role="progressbar"
                        aria-label="解压进度"
                        aria-valuemin={0}
                        aria-valuemax={100}
                        aria-valuenow={pct}
                      >
                        <span style={{ width: `${pct}%` }} />
                      </div>
                    ) : null}
                    {item.message ? (
                      <p className="p115-task__line allow-select">{item.message}</p>
                    ) : null}
                  </div>
                  <span className={cn('p115-task__chip', `is-${tone}`)}>
                    {stateChip(item)}
                  </span>
                </li>
              );
            })}
          </ul>
        )}
      </section>

      <AppCenterModal
        open={pwdOpen}
        title="解压密码"
        onClose={() => setPwdOpen(false)}
        cardClassName="p115-password-modal"
        footer={
          <>
            <button
              type="button"
              className="app-btn-secondary"
              onClick={() => setPwdOpen(false)}
            >
              取消
            </button>
            <button
              type="button"
              className="app-btn-primary"
              style={{ flex: 1 }}
              disabled={settingsLocked || extractBusy}
              onClick={() => void savePassword()}
            >
              确定
            </button>
          </>
        }
      >
        <div className="p115-password-field">
          <input
            type="text"
            placeholder="留空则自动尝试常见密码"
            value={pwdDraft}
            autoCapitalize="off"
            autoCorrect="off"
            spellCheck={false}
            disabled={settingsLocked || running}
            onChange={(e) => setPwdDraft(e.target.value)}
            aria-label="解压密码"
            autoFocus
          />
        </div>
        <p className="p115-stat__hint">
          密码顺序：压缩包名里的【密码:xxx】→ 配置密码（这里填写的）→ 空密码 → 兜底密码（预设：98t.la 系列、sehuatang、98tang、1314、1024）。名字里带密码时以名字为准。
        </p>
      </AppCenterModal>

      <AppCenterModal
        open={flowOpen}
        title="解压流程"
        onClose={() => setFlowOpen(false)}
        cardClassName="p115-flow-modal"
      >
        <P115FlowTab p={p} />
      </AppCenterModal>
    </div>
  );
}
