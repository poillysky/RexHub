'use client';

import { Folder } from 'lucide-react';
import { AppCenterModal } from '@/components/ui/AppCenterModal';
import { cn } from '@/lib/utils';
import { SAVE_SOURCES } from './format';
import type { P115PanelState } from './useP115Panel';

/** 115 目录浏览弹窗：三类转存目录与解压目录共用 */
export function P115FolderBrowser({ p }: { p: P115PanelState }) {
  const {
    showBrowser,
    setShowBrowser,
    browseSource,
    folderPath,
    folders,
    browsing,
    browseFolders,
    selectFolder,
    targets,
    extractConfig,
    locked,
    settingsLocked,
  } = p;

  const isExtract = browseSource === 'extract';
  const title = isExtract
    ? '选择解压目录'
    : `选择${SAVE_SOURCES.find((s) => s.key === browseSource)?.label || ''}目录`;
  const selectedCid = isExtract
    ? extractConfig.folderCid
    : targets[browseSource].folderCid;

  return (
    <AppCenterModal
      open={showBrowser}
      title={title}
      onClose={() => setShowBrowser(false)}
      cardClassName="p115-browser-modal"
      footer={
        <button
          type="button"
          className="app-btn-primary"
          style={{ flex: 1 }}
          disabled={settingsLocked}
          onClick={() => {
            const cur = folderPath[folderPath.length - 1];
            if (cur) {
              selectFolder(cur);
              return;
            }
            selectFolder({ cid: '0', name: '' });
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
            folderPath.map((item, idx) => (
              <span key={`${item.cid}-${idx}`} className="p115-browser__crumb">
                {idx > 0 ? <span className="p115-browser__sep">/</span> : null}
                <button
                  type="button"
                  className={cn(
                    'p115-browser__link',
                    idx === folderPath.length - 1 && 'is-current',
                  )}
                  onClick={() => void browseFolders(browseSource, item.cid)}
                >
                  {item.name}
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
              const selected = f.cid === selectedCid;
              return (
                <div key={f.cid} className={cn('p115-browser__row', selected && 'is-selected')}>
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
                    disabled={settingsLocked}
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
  );
}
