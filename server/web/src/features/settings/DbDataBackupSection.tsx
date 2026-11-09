'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import { AppFootnote } from '@/components/ui/AppMsg';
import { cn } from '@/lib/utils';
import type { DbBackupProgress, ResourceDbBackupItem } from '@/lib/api';

function formatBytes(n: number): string {
  if (!Number.isFinite(n) || n < 0) return '—';
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 * 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MB`;
  return `${(n / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

export function DbDataBackupSection({
  dirHint,
  disabled,
  listBackups,
  exportBackup,
  getProgress,
  uploadImportBackup,
  onMessage,
  onBusyChange,
}: {
  dirHint: string;
  disabled?: boolean;
  listBackups: () => Promise<ResourceDbBackupItem[]>;
  exportBackup: () => Promise<{
    filename: string;
    bytes: number;
    elapsedMs: number;
  }>;
  getProgress: () => Promise<DbBackupProgress>;
  uploadImportBackup: (file: File) => Promise<{
    filename: string;
    bytes?: number;
    elapsedMs: number;
    tables: Array<{ name: string; rows: number }>;
  }>;
  onMessage: (text: string) => void;
  onBusyChange?: (busy: boolean) => void;
}) {
  const fileRef = useRef<HTMLInputElement>(null);
  /** busy 是 state，同一帧连点会重复提交；用 ref 做同步重入保护 */
  const running = useRef(false);
  const [busy, setBusy] = useState(false);
  const [pending, setPending] = useState<'export' | 'import' | null>(null);
  const [progress, setProgress] = useState<DbBackupProgress | null>(null);
  const [backups, setBackups] = useState<ResourceDbBackupItem[]>([]);
  const mounted = useRef(true);

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  function setBusyBoth(next: boolean) {
    setBusy(next);
    onBusyChange?.(next);
  }

  const refresh = useCallback(async () => {
    try {
      setBackups(await listBackups());
    } catch {
      /* ignore list errors */
    }
  }, [listBackups]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  /**
   * 导出/导入是同步请求，进度只能在请求进行中轮询。
   * 主流程结束（无论成败）立即停止，避免定时器泄漏。
   */
  async function withProgress<T>(
    action: 'export' | 'import',
    task: () => Promise<T>,
  ): Promise<T> {
    const stop = { done: false };
    setProgress(null);
    void (async () => {
      while (!stop.done) {
        try {
          const p = await getProgress();
          if (stop.done || !mounted.current) return;
          if (p.running && p.action === action) setProgress(p);
        } catch {
          /* 进度接口失败不影响导出/导入本身 */
        }
        await new Promise((r) => setTimeout(r, 500));
      }
    })();
    try {
      return await task();
    } finally {
      stop.done = true;
      if (mounted.current) setProgress(null);
    }
  }

  async function onExport() {
    if (running.current) return;
    running.current = true;
    setPending('export');
    setBusyBoth(true);
    onMessage(`正在导出资源数据到 ${dirHint}…`);
    try {
      const r = await withProgress('export', exportBackup);
      await refresh();
      const sec = (r.elapsedMs / 1000).toFixed(1);
      onMessage(`已导出 ${r.filename}（${formatBytes(r.bytes)}，${sec}s）`);
    } catch (e) {
      onMessage(e instanceof Error ? e.message : '导出失败');
    } finally {
      setPending(null);
      setBusyBoth(false);
      running.current = false;
    }
  }

  async function onPickFile(file: File | null) {
    if (!file) return;
    if (!/\.zip$/i.test(file.name)) {
      onMessage('请选择 .zip 备份文件');
      return;
    }
    if (running.current) {
      if (fileRef.current) fileRef.current.value = '';
      return;
    }
    if (
      !window.confirm(
        `将上传并导入 ${file.name}，覆盖当前资源表数据（不可撤销）。确认继续？`,
      )
    ) {
      if (fileRef.current) fileRef.current.value = '';
      return;
    }
    running.current = true;
    setPending('import');
    setBusyBoth(true);
    onMessage(`正在上传并导入 ${file.name}…`);
    try {
      const r = await withProgress('import', () => uploadImportBackup(file));
      await refresh();
      const sec = (r.elapsedMs / 1000).toFixed(1);
      onMessage(`已导入 ${r.filename}（${r.tables.length} 张表，${sec}s）`);
    } catch (e) {
      onMessage(e instanceof Error ? e.message : '导入失败');
    } finally {
      setPending(null);
      setBusyBoth(false);
      running.current = false;
      if (fileRef.current) fileRef.current.value = '';
    }
  }

  const locked = Boolean(disabled) || busy;

  return (
    <>
      <p className="settings-group-label">资源数据备份</p>
      <div className="app-actions">
        <button
          type="button"
          className="app-btn-secondary"
          disabled={locked}
          onClick={() => void onExport()}
        >
          {pending === 'export' ? '导出中…' : '导出 zip'}
        </button>
        <button
          type="button"
          className="app-btn-secondary"
          disabled={locked}
          onClick={() => fileRef.current?.click()}
        >
          {pending === 'import' ? '导入中…' : '导入 zip'}
        </button>
        <input
          ref={fileRef}
          type="file"
          accept=".zip,application/zip"
          hidden
          onChange={(e) => void onPickFile(e.target.files?.[0] || null)}
        />
        <button
          type="button"
          className="app-btn-secondary"
          disabled={locked}
          onClick={() => void refresh()}
        >
          刷新列表
        </button>
      </div>
      {pending ? (
        <div className="settings-backup-progress" aria-live="polite">
          <div
            className={cn(
              'settings-backup-progress__bar',
              (!progress || progress.percent <= 0) && 'is-indeterminate',
            )}
            role="progressbar"
            aria-label={pending === 'export' ? '导出进度' : '导入进度'}
            aria-valuenow={
              progress && progress.percent > 0 ? progress.percent : undefined
            }
            aria-valuemin={0}
            aria-valuemax={100}
          >
            <span
              style={
                progress && progress.percent > 0
                  ? { width: `${progress.percent}%` }
                  : undefined
              }
            />
          </div>
          <p className="settings-backup-progress__text">
            {pending === 'export' ? '导出' : '导入'}
            {progress?.message ? ` · ${progress.message}` : '中'}
            {progress && progress.percent > 0 ? ` ${progress.percent}%` : ''}
          </p>
        </div>
      ) : null}
      {backups.length > 0 ? (
        <ul className="settings-group" style={{ marginTop: 8 }}>
          {backups.map((b) => (
            <li key={b.filename}>
              <div className="settings-kv" style={{ alignItems: 'flex-start' }}>
                <div style={{ minWidth: 0, flex: 1 }}>
                  <div className="allow-select" style={{ wordBreak: 'break-all' }}>
                    {b.filename}
                  </div>
                  <div className="settings-nav__status" style={{ marginTop: 2 }}>
                    {formatBytes(b.bytes)} · {b.mtime.replace('T', ' ').replace('Z', ' UTC')}
                  </div>
                </div>
              </div>
            </li>
          ))}
        </ul>
      ) : (
        <AppFootnote>尚无备份。导出或导入后会出现在 {dirHint}。</AppFootnote>
      )}
    </>
  );
}
