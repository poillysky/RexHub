'use client';

import { Package, RefreshCw, Trash2 } from 'lucide-react';
import { AppCenterModal } from '@/components/ui/AppCenterModal';
import type { PluginFrameworkRepository } from '@/lib/api';

export type RepoForm = { url: string; name: string; index_path: string; branch: string };
export type RepoModalTab = 'add' | 'list';

export function RepoModal({
  open,
  onClose,
  tab,
  onTabChange,
  form,
  onFormChange,
  repositories,
  busy,
  onSave,
  onRefresh,
  onRemove,
}: {
  open: boolean;
  onClose: () => void;
  tab: RepoModalTab;
  onTabChange: (next: RepoModalTab) => void;
  form: RepoForm;
  onFormChange: (next: RepoForm) => void;
  repositories: PluginFrameworkRepository[];
  busy: boolean;
  onSave: () => void;
  onRefresh: (repo: PluginFrameworkRepository) => void;
  onRemove: (repo: PluginFrameworkRepository) => void;
}) {
  return (
    <AppCenterModal
      open={open}
      title="插件仓库"
      onClose={onClose}
      cardClassName="plugin-fw-repo-modal"
      footer={
        <button
          type="button"
          className="app-btn-primary plugin-fw-modal__done"
          onClick={onClose}
        >
          完成
        </button>
      }
    >
      <div className="plugin-fw-modal__summary">
        <span className="plugin-fw-modal__summary-icon" aria-hidden>
          <Package size={18} strokeWidth={2.2} />
        </span>
        <div className="plugin-fw-modal__summary-main">
          <span className="plugin-fw-modal__eyebrow">GitHub 插件仓库</span>
        </div>
        <span className="plugin-fw-modal__count">{repositories.length}</span>
      </div>

      <div className="plugin-fw-modal__tabs" role="tablist" aria-label="插件仓库管理">
        <button
          type="button"
          role="tab"
          aria-selected={tab === 'add'}
          className={`plugin-fw-modal__tab${tab === 'add' ? ' is-on' : ''}`}
          onClick={() => onTabChange('add')}
        >
          添加仓库
        </button>
        <button
          type="button"
          role="tab"
          aria-selected={tab === 'list'}
          className={`plugin-fw-modal__tab${tab === 'list' ? ' is-on' : ''}`}
          onClick={() => onTabChange('list')}
        >
          已添加
          <span className="plugin-fw-modal__tab-count">{repositories.length}</span>
        </button>
      </div>

      {tab === 'add' ? (
        <div className="plugin-fw-modal__form">
          <label className="plugin-fw-modal__field">
            <span className="plugin-fw-modal__label">仓库地址</span>
            <input
              className="allow-select"
              placeholder="owner/repo 或 GitHub 地址"
              value={form.url}
              onChange={(e) => onFormChange({ ...form, url: e.target.value })}
              autoCapitalize="off"
              spellCheck={false}
            />
          </label>
          <div className="plugin-fw-modal__form-row">
            <label className="plugin-fw-modal__field">
              <span className="plugin-fw-modal__label">显示名称</span>
              <input
                className="allow-select"
                placeholder="可选"
                value={form.name}
                onChange={(e) => onFormChange({ ...form, name: e.target.value })}
              />
            </label>
            <label className="plugin-fw-modal__field">
              <span className="plugin-fw-modal__label">分支</span>
              <input
                className="allow-select"
                placeholder="main / master"
                value={form.branch}
                onChange={(e) => onFormChange({ ...form, branch: e.target.value })}
                autoCapitalize="off"
                spellCheck={false}
              />
            </label>
          </div>
          <label className="plugin-fw-modal__field">
            <span className="plugin-fw-modal__label">索引文件</span>
            <input
              className="allow-select"
              placeholder="repository.json / registry.json"
              value={form.index_path}
              onChange={(e) => onFormChange({ ...form, index_path: e.target.value })}
              autoCapitalize="off"
              spellCheck={false}
            />
          </label>
          <button
            type="button"
            className="app-btn-primary plugin-fw-modal__save"
            disabled={busy || !form.url.trim()}
            onClick={onSave}
          >
            保存仓库
          </button>
        </div>
      ) : repositories.length ? (
        <ul className="plugin-fw-modal__list">
          {repositories.map((repo) => (
            <li key={repo.id} className="plugin-fw-modal__repo">
              <span className="plugin-fw-modal__repo-icon" aria-hidden>
                <Package size={15} strokeWidth={2.2} />
              </span>
              <div className="plugin-fw-modal__repo-main">
                <div className="plugin-fw-modal__repo-name">{repo.name || repo.id}</div>
                <div className="plugin-fw-modal__repo-url allow-select">{repo.url}</div>
                <div className="plugin-fw-modal__repo-chips">
                  <span className="plugin-fw-modal__chip">
                    {repo.index_path || 'repository.json'}
                  </span>
                  {repo.branch ? <span className="plugin-fw-modal__chip">{repo.branch}</span> : null}
                </div>
              </div>
              <div className="plugin-fw-modal__repo-actions">
                <button
                  type="button"
                  className="plugin-fw-modal__icon-btn"
                  aria-label="刷新仓库"
                  title="刷新仓库"
                  disabled={busy}
                  onClick={() => onRefresh(repo)}
                >
                  <RefreshCw size={14} strokeWidth={2.3} />
                </button>
                <button
                  type="button"
                  className="plugin-fw-modal__icon-btn plugin-fw-modal__icon-btn--danger"
                  aria-label="删除仓库"
                  title="删除仓库"
                  disabled={busy}
                  onClick={() => onRemove(repo)}
                >
                  <Trash2 size={14} strokeWidth={2.3} />
                </button>
              </div>
            </li>
          ))}
        </ul>
      ) : (
        <div className="plugin-fw-modal__empty">
          <span className="plugin-fw-modal__empty-icon" aria-hidden>
            <Package size={20} strokeWidth={2.1} />
          </span>
          <p>还没有插件仓库</p>
          <span>添加一个包含 repository.json 的 GitHub 仓库，即可浏览与安装插件。</span>
        </div>
      )}
    </AppCenterModal>
  );
}
