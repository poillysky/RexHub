'use client';

import { useCallback, useEffect, useState } from 'react';
import { ChevronRight, KeyRound, LogOut, Ticket, Trash2, Users } from 'lucide-react';
import { useAuth } from '@/providers/AuthProvider';
import {
  adminCreateUser,
  adminDeleteUser,
  adminResetUserPassword,
  adminRevokeUserSessions,
  adminSetUserRole,
  authChangePassword,
  fetchInviteCodes,
  listUsers,
  rotateInviteCodes,
} from '@/lib/api';
import { copyText } from '@/lib/clipboard';
import type { AuthUser } from '@/types/resource';
import { AppPush } from '@/components/ui/AppPush';
import { AppFootnote, AppMsg } from '@/components/ui/AppMsg';
import { cn } from '@/lib/utils';

type Sub =
  | null
  | 'password'
  | 'users'
  | 'create'
  | 'invites'
  | { kind: 'detail'; user: AuthUser };

/** 后端 bcrypt 只取前 72 字节，超出部分会被忽略 */
const PASSWORD_MAX_BYTES = 72;
const PASSWORD_HINT = '密码为 8–72 字节（中文约 24 个字）';

function passwordError(pwd: string): string | null {
  if (pwd.length < 8) return '密码至少 8 位';
  if (new TextEncoder().encode(pwd).length > PASSWORD_MAX_BYTES) {
    return '密码过长：最多 72 字节（中文约 24 个字）';
  }
  return null;
}

/** 元库时间统一按 UTC 存储，界面按本地时区展示 */
function formatTime(raw?: string): string {
  if (!raw) return '';
  const d = new Date(`${raw.replace(' ', 'T')}Z`);
  if (Number.isNaN(d.getTime())) return raw;
  return d.toLocaleString('zh-CN', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  });
}

export function UserManagePanel({
  onBack,
  onLogout,
}: {
  onBack: () => void;
  onLogout: () => void;
}) {
  const { user, isAdmin } = useAuth();
  const [sub, setSub] = useState<Sub>(null);
  const [panelMsg, setPanelMsg] = useState('');
  const [busy, setBusy] = useState(false);

  const [users, setUsers] = useState<AuthUser[]>([]);
  const [listMsg, setListMsg] = useState('');
  const [listLoading, setListLoading] = useState(false);

  const [currentPwd, setCurrentPwd] = useState('');
  const [nextPwd, setNextPwd] = useState('');
  const [confirmPwd, setConfirmPwd] = useState('');
  const [pwdMsg, setPwdMsg] = useState('');

  const [newName, setNewName] = useState('');
  const [newPwd, setNewPwd] = useState('');
  const [newAdmin, setNewAdmin] = useState(false);
  const [createMsg, setCreateMsg] = useState('');

  const [resetPwd, setResetPwd] = useState('');
  const [detailMsg, setDetailMsg] = useState('');
  const [deleteConfirm, setDeleteConfirm] = useState('');

  const [invites, setInvites] = useState<{ admin: string; user: string } | null>(null);
  const [inviteMsg, setInviteMsg] = useState('');

  const initial = (user?.username || '?').slice(0, 1).toUpperCase();
  const selfId = user?.id;

  const refreshUsers = useCallback(async () => {
    if (!isAdmin) return;
    setListLoading(true);
    setListMsg('');
    try {
      setUsers(await listUsers());
    } catch (e) {
      setListMsg(e instanceof Error ? e.message : '加载失败');
    } finally {
      setListLoading(false);
    }
  }, [isAdmin]);

  useEffect(() => {
    if (sub === 'users') void refreshUsers();
  }, [sub, refreshUsers]);

  useEffect(() => {
    if (sub !== 'invites' || !isAdmin) return;
    setInviteMsg('');
    fetchInviteCodes()
      .then(setInvites)
      .catch((e) => setInviteMsg(e instanceof Error ? e.message : '加载失败'));
  }, [sub, isAdmin]);

  async function onRotateInvites() {
    if (!window.confirm('轮换后旧邀请码立即失效，确定继续？')) return;
    setBusy(true);
    setInviteMsg('');
    try {
      setInvites(await rotateInviteCodes());
      setInviteMsg('已轮换，旧邀请码已失效');
    } catch (e) {
      setInviteMsg(e instanceof Error ? e.message : '轮换失败');
    } finally {
      setBusy(false);
    }
  }

  async function onCopyInvite(kind: 'admin' | 'user') {
    const code = invites?.[kind];
    if (!code) return;
    const ok = await copyText(code);
    setInviteMsg(ok ? `已复制${kind === 'admin' ? '管理员' : '普通用户'}邀请码` : '复制失败，请手动选择文本');
  }

  async function onChangePassword() {
    const err = passwordError(nextPwd);
    setPwdMsg(err ?? '');
    if (err) return;
    if (nextPwd !== confirmPwd) {
      setPwdMsg('两次输入不一致');
      return;
    }
    setBusy(true);
    try {
      await authChangePassword(currentPwd, nextPwd);
      setCurrentPwd('');
      setNextPwd('');
      setConfirmPwd('');
      setPwdMsg('');
      setSub(null);
      setPanelMsg('密码已更新');
    } catch (e) {
      setPwdMsg(e instanceof Error ? e.message : '修改失败');
    } finally {
      setBusy(false);
    }
  }

  async function onCreate() {
    setCreateMsg('');
    if (!newName.trim()) {
      setCreateMsg('请填写用户名');
      return;
    }
    const err = passwordError(newPwd);
    if (err) {
      setCreateMsg(err);
      return;
    }
    setBusy(true);
    try {
      await adminCreateUser(newName.trim(), newPwd, newAdmin);
      const created = newName.trim();
      setNewName('');
      setNewPwd('');
      setNewAdmin(false);
      setSub('users');
      setPanelMsg(`已创建用户「${created}」`);
    } catch (e) {
      setCreateMsg(e instanceof Error ? e.message : '创建失败');
    } finally {
      setBusy(false);
    }
  }

  async function onReset(target: AuthUser) {
    const err = passwordError(resetPwd);
    setDetailMsg(err ?? '');
    if (err) return;
    if (!window.confirm(`重置后「${target.username}」所有会话将被强制下线，确定继续？`)) return;
    setBusy(true);
    try {
      await adminResetUserPassword(target.id, resetPwd);
      setResetPwd('');
      setDeleteConfirm('');
      setSub('users');
      setPanelMsg(`已重置「${target.username}」的密码，其会话已全部下线`);
    } catch (e) {
      setDetailMsg(e instanceof Error ? e.message : '重置失败');
    } finally {
      setBusy(false);
    }
  }

  async function onToggleRole(target: AuthUser) {
    const nextAdmin = !target.is_admin;
    const label = nextAdmin
      ? `将「${target.username}」设为管理员？`
      : `取消「${target.username}」的管理员权限？`;
    if (!window.confirm(label)) return;
    setBusy(true);
    setDetailMsg('');
    try {
      await adminSetUserRole(target.id, nextAdmin);
      setDeleteConfirm('');
      setSub('users');
      setPanelMsg(nextAdmin ? '已设为管理员' : '已取消管理员权限');
    } catch (e) {
      setDetailMsg(e instanceof Error ? e.message : '角色更新失败');
    } finally {
      setBusy(false);
    }
  }

  async function onRevokeSessions(target: AuthUser) {
    if (!window.confirm(`强制「${target.username}」下线？`)) return;
    setBusy(true);
    setDetailMsg('');
    try {
      const revoked = await adminRevokeUserSessions(target.id);
      setDeleteConfirm('');
      setSub('users');
      setPanelMsg(`已下线 ${revoked} 个会话`);
    } catch (e) {
      setDetailMsg(e instanceof Error ? e.message : '下线失败');
    } finally {
      setBusy(false);
    }
  }

  async function onDelete(target: AuthUser) {
    if (deleteConfirm !== target.username) return;
    if (!window.confirm(`确定永久删除用户「${target.username}」？`)) return;
    setBusy(true);
    setDetailMsg('');
    try {
      await adminDeleteUser(target.id);
      setDeleteConfirm('');
      setSub('users');
      setPanelMsg(`已删除用户「${target.username}」`);
    } catch (e) {
      setDetailMsg(e instanceof Error ? e.message : '删除失败');
    } finally {
      setBusy(false);
    }
  }

  function onLogoutClick() {
    if (!window.confirm('确定退出登录？')) return;
    onLogout();
  }

  return (
    <>
      <AppPush title="用户管理" scrollKey="users-hub" onBack={onBack}>
        <div className="user-card">
          <span className="user-card__avatar" aria-hidden>
            {initial}
          </span>
          <div className="user-card__main">
            <div className="user-card__name">{user?.username || '未登录'}</div>
            <div className="user-card__meta">
              <span className={cn('user-card__badge', !isAdmin && 'user-card__badge--mute')}>
                {isAdmin ? '管理员' : '普通用户'}
              </span>
              {user?.created_at ? (
                <span className="user-card__date">加入 {formatTime(user.created_at)}</span>
              ) : null}
            </div>
          </div>
        </div>

        <p className="settings-group-label">账号</p>
        <ul className="settings-group">
          <li>
            <div className="settings-kv">
              <span className="settings-kv__key">用户名</span>
              <span className="settings-kv__val">{user?.username || '—'}</span>
            </div>
          </li>
          <li>
            <div className="settings-kv">
              <span className="settings-kv__key">角色</span>
              <span className="settings-kv__val">{isAdmin ? '管理员' : '普通用户'}</span>
            </div>
          </li>
        </ul>

        {isAdmin ? (
          <>
            <p className="settings-group-label">权限管理</p>
            <ul className="settings-group">
              <li>
                <button type="button" className="settings-nav" onClick={() => setSub('users')}>
                  <span className="settings-nav__icon settings-nav__icon--blue" aria-hidden>
                    <Users size={14} strokeWidth={2.25} />
                  </span>
                  <span className="settings-nav__main">
                    <span className="settings-nav__title">用户管理</span>
                    <span className="settings-nav__desc">
                      查看 · 创建 · 角色 · 重置密码 · 下线 · 删除
                    </span>
                  </span>
                  <ChevronRight className="settings-nav__chev" size={16} strokeWidth={2.25} />
                </button>
              </li>
              <li>
                <button type="button" className="settings-nav" onClick={() => setSub('invites')}>
                  <span className="settings-nav__icon settings-nav__icon--indigo" aria-hidden>
                    <Ticket size={14} strokeWidth={2.25} />
                  </span>
                  <span className="settings-nav__main">
                    <span className="settings-nav__title">邀请码</span>
                    <span className="settings-nav__desc">查看 · 复制 · 轮换 · 决定注册角色</span>
                  </span>
                  <ChevronRight className="settings-nav__chev" size={16} strokeWidth={2.25} />
                </button>
              </li>
            </ul>
          </>
        ) : null}

        <p className="settings-group-label">安全</p>
        <ul className="settings-group">
          <li>
            <button type="button" className="settings-nav" onClick={() => setSub('password')}>
              <span className="settings-nav__icon settings-nav__icon--indigo" aria-hidden>
                <KeyRound size={14} strokeWidth={2.25} />
              </span>
              <span className="settings-nav__main">
                <span className="settings-nav__title">修改密码</span>
                <span className="settings-nav__desc">定期更换更安全</span>
              </span>
              <ChevronRight className="settings-nav__chev" size={16} strokeWidth={2.25} />
            </button>
          </li>
        </ul>

        <ul className="settings-group">
          <li>
            <button
              type="button"
              className="settings-nav settings-nav--danger"
              onClick={onLogoutClick}
            >
              <span className="settings-nav__icon settings-nav__icon--danger" aria-hidden>
                <LogOut size={14} strokeWidth={2.25} />
              </span>
              <span className="settings-nav__main">
                <span className="settings-nav__title">退出登录</span>
              </span>
            </button>
          </li>
        </ul>
        <AppMsg onDismiss={() => setPanelMsg('')}>{panelMsg}</AppMsg>
      </AppPush>

      {sub === 'password' ? (
        <AppPush
          title="修改密码"
          scrollKey="users-password"
          onBack={() => setSub(null)}
        >
          <section className="app-section">
            <div className="app-section-body">
              <label className="app-field">
                <span className="app-label">当前</span>
                <input
                  type="password"
                  autoComplete="current-password"
                  placeholder="当前密码"
                  value={currentPwd}
                  onChange={(e) => setCurrentPwd(e.target.value)}
                />
              </label>
              <label className="app-field">
                <span className="app-label">新密码</span>
                <input
                  type="password"
                  autoComplete="new-password"
                  placeholder="至少 8 位"
                  maxLength={128}
                  value={nextPwd}
                  onChange={(e) => setNextPwd(e.target.value)}
                />
              </label>
              <label className="app-field">
                <span className="app-label">确认</span>
                <input
                  type="password"
                  autoComplete="new-password"
                  placeholder="再输入一次"
                  maxLength={128}
                  value={confirmPwd}
                  onChange={(e) => setConfirmPwd(e.target.value)}
                />
              </label>
            </div>
          </section>
          <AppFootnote>{PASSWORD_HINT}</AppFootnote>
          <div className="app-actions">
            <button
              type="button"
              className="app-btn-primary app-btn-block"
              disabled={busy}
              onClick={() => void onChangePassword()}
            >
              更新密码
            </button>
          </div>
          {pwdMsg ? <AppMsg onDismiss={() => setPwdMsg('')}>{pwdMsg}</AppMsg> : null}
        </AppPush>
      ) : null}

      {sub === 'invites' ? (
        <AppPush
          title="邀请码"
          scrollKey="users-invites"
          onBack={() => setSub(null)}
        >
          <p className="settings-group-label">当前有效邀请码</p>
          <ul className="settings-group">
            <li>
              <div className="settings-kv">
                <span className="settings-kv__key">管理员注册</span>
                <span className="settings-kv__val">{invites?.admin || '—'}</span>
              </div>
            </li>
            <li>
              <div className="settings-kv">
                <span className="settings-kv__key">普通用户注册</span>
                <span className="settings-kv__val">{invites?.user || '—'}</span>
              </div>
            </li>
          </ul>
          <div className="app-actions">
            <button
              type="button"
              className="app-btn-secondary"
              disabled={!invites?.admin}
              onClick={() => void onCopyInvite('admin')}
            >
              复制管理员码
            </button>
            <button
              type="button"
              className="app-btn-secondary"
              disabled={!invites?.user}
              onClick={() => void onCopyInvite('user')}
            >
              复制普通用户码
            </button>
          </div>
          <AppFootnote>邀请码只存元库；轮换后旧码立即失效，已注册账号不受影响。</AppFootnote>
          <div className="app-actions">
            <button
              type="button"
              className="app-btn-primary app-btn-block"
              disabled={busy}
              onClick={() => void onRotateInvites()}
            >
              轮换邀请码
            </button>
          </div>
          <AppMsg onDismiss={() => setInviteMsg('')}>{inviteMsg}</AppMsg>
        </AppPush>
      ) : null}

      {sub === 'users' ? (
        <AppPush
          title="用户管理"
          scrollKey="users-list"
          onBack={() => setSub(null)}
          right={
            <button
              type="button"
              className="settings-push-action"
              onClick={() => setSub('create')}
            >
              创建
            </button>
          }
        >
          {listLoading ? (
            <p className="app-loading">加载中…</p>
          ) : listMsg ? (
            <div className="app-error">{listMsg}</div>
          ) : users.length === 0 ? (
            <p className="app-empty">暂无用户</p>
          ) : (
            <>
              <p className="settings-group-label">
                全部账号 · {users.length} 个（管理员 {users.filter((u) => u.is_admin).length}）
              </p>
              <ul className="settings-group">
                {users.map((u) => (
                  <li key={u.id}>
                    <button
                      type="button"
                      className="settings-nav"
                      onClick={() => {
                        setDetailMsg('');
                        setResetPwd('');
                        setDeleteConfirm('');
                        setSub({ kind: 'detail', user: u });
                      }}
                    >
                      <span className="settings-nav__avatar" aria-hidden>
                        {u.username.slice(0, 1).toUpperCase()}
                      </span>
                      <span className="settings-nav__main">
                        <span className="settings-nav__title">{u.username}</span>
                        <span className="settings-nav__desc">
                          {u.is_admin ? '管理员' : '普通用户'}
                          {u.created_at ? ` · ${formatTime(u.created_at)}` : ''}
                          {u.sessions ? ` · 在线 ${u.sessions}` : ' · 离线'}
                        </span>
                      </span>
                      <ChevronRight className="settings-nav__chev" size={16} strokeWidth={2.25} />
                    </button>
                  </li>
                ))}
              </ul>
            </>
          )}
        </AppPush>
      ) : null}

      {sub === 'create' ? (
        <AppPush
          title="创建用户"
          scrollKey="users-create"
          onBack={() => setSub('users')}
        >
          <section className="app-section">
            <div className="app-section-body">
              <label className="app-field">
                <span className="app-label">用户名</span>
                <input
                  autoComplete="off"
                  placeholder="3–32 位字母、数字或下划线"
                  maxLength={32}
                  value={newName}
                  onChange={(e) => setNewName(e.target.value)}
                />
              </label>
              <label className="app-field">
                <span className="app-label">密码</span>
                <input
                  type="password"
                  autoComplete="new-password"
                  placeholder="至少 8 位"
                  maxLength={128}
                  value={newPwd}
                  onChange={(e) => setNewPwd(e.target.value)}
                />
              </label>
              <div className="app-field user-create-role">
                <span className="app-label">角色</span>
                <div className="app-seg" role="tablist" aria-label="新用户角色">
                  {[
                    { value: false, label: '普通用户' },
                    { value: true, label: '管理员' },
                  ].map((opt) => (
                    <button
                      key={opt.label}
                      type="button"
                      role="tab"
                      aria-selected={newAdmin === opt.value}
                      className={cn('app-seg__btn', newAdmin === opt.value && 'app-seg__btn--active')}
                      onClick={() => setNewAdmin(opt.value)}
                    >
                      {opt.label}
                    </button>
                  ))}
                </div>
              </div>
            </div>
          </section>
          <AppFootnote>{PASSWORD_HINT}</AppFootnote>
          <div className="app-actions">
            <button
              type="button"
              className="app-btn-primary app-btn-block"
              disabled={busy}
              onClick={() => void onCreate()}
            >
              创建
            </button>
          </div>
          {createMsg ? <AppMsg onDismiss={() => setCreateMsg('')}>{createMsg}</AppMsg> : null}
        </AppPush>
      ) : null}

      {sub && typeof sub === 'object' && sub.kind === 'detail' ? (
        <AppPush
          title={sub.user.username}
          scrollKey={`users-detail-${sub.user.id}`}
          onBack={() => setSub('users')}
        >
          <ul className="settings-group">
            <li>
              <div className="settings-kv">
                <span className="settings-kv__key">角色</span>
                <span className="settings-kv__val">
                  {sub.user.is_admin ? '管理员' : '普通用户'}
                </span>
              </div>
            </li>
            {sub.user.created_at ? (
              <li>
                <div className="settings-kv">
                  <span className="settings-kv__key">创建</span>
                  <span className="settings-kv__val">{formatTime(sub.user.created_at)}</span>
                </div>
              </li>
            ) : null}
            <li>
              <div className="settings-kv">
                <span className="settings-kv__key">用户 ID</span>
                <span className="settings-kv__val">{sub.user.id}</span>
              </div>
            </li>
            <li>
              <div className="settings-kv">
                <span className="settings-kv__key">在线会话</span>
                <span className="settings-kv__val">
                  {sub.user.sessions ? `${sub.user.sessions} 个` : '无'}
                </span>
              </div>
            </li>
          </ul>

          {selfId === sub.user.id ? (
            <div className="app-actions">
              <button
                type="button"
                className="app-btn-secondary app-btn-block"
                onClick={() => setSub('password')}
              >
                修改自己的密码
              </button>
            </div>
          ) : (
            <>
              <p className="settings-group-label">重置密码</p>
              <section className="app-section">
                <div className="app-section-body">
                  <label className="app-field">
                    <span className="app-label">新密码</span>
                    <input
                      type="password"
                      autoComplete="new-password"
                      placeholder="至少 8 位"
                      maxLength={128}
                      value={resetPwd}
                      onChange={(e) => setResetPwd(e.target.value)}
                    />
                  </label>
                </div>
              </section>
              <AppFootnote>{PASSWORD_HINT}</AppFootnote>
              <div className="app-actions">
                <button
                  type="button"
                  className="app-btn-primary app-btn-block"
                  disabled={busy}
                  onClick={() => void onReset(sub.user)}
                >
                  重置密码
                </button>
              </div>

              <p className="settings-group-label settings-group-label--spaced">权限与会话</p>
              <ul className="settings-group">
                <li>
                  <button
                    type="button"
                    className="settings-nav"
                    disabled={busy}
                    onClick={() => void onToggleRole(sub.user)}
                  >
                    <span className="settings-nav__main">
                      <span className="settings-nav__title">
                        {sub.user.is_admin ? '取消管理员权限' : '设为管理员'}
                      </span>
                    </span>
                    <ChevronRight className="settings-nav__chev" size={16} strokeWidth={2.25} />
                  </button>
                </li>
                <li>
                  <button
                    type="button"
                    className="settings-nav"
                    disabled={busy || !sub.user.sessions}
                    onClick={() => void onRevokeSessions(sub.user)}
                  >
                    <span className="settings-nav__main">
                      <span className="settings-nav__title">下线所有会话</span>
                    </span>
                    <ChevronRight className="settings-nav__chev" size={16} strokeWidth={2.25} />
                  </button>
                </li>
              </ul>

              <p className="settings-group-label settings-group-label--spaced">危险操作</p>
              <section className="app-section">
                <div className="app-section-body">
                  <label className="app-field">
                    <span className="app-label">输入用户名确认</span>
                    <input
                      autoComplete="off"
                      placeholder={sub.user.username}
                      value={deleteConfirm}
                      onChange={(e) => setDeleteConfirm(e.target.value)}
                    />
                  </label>
                </div>
              </section>
              <ul className="settings-group">
                <li>
                  <button
                    type="button"
                    className="settings-nav settings-nav--danger"
                    disabled={busy || deleteConfirm !== sub.user.username}
                    onClick={() => void onDelete(sub.user)}
                  >
                    <span className="settings-nav__icon settings-nav__icon--danger" aria-hidden>
                      <Trash2 size={14} strokeWidth={2.25} />
                    </span>
                    <span className="settings-nav__main">
                      <span className="settings-nav__title">删除用户</span>
                    </span>
                  </button>
                </li>
              </ul>
            </>
          )}
          <AppMsg onDismiss={() => setDetailMsg('')}>{detailMsg}</AppMsg>
        </AppPush>
      ) : null}
    </>
  );
}
