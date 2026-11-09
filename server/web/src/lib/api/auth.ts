/**
 * 登录注册与用户管理
 *
 * 由 lib/api.ts 拆分而来；对外统一从 `@/lib/api` 导入，请不要直接引用本文件。
 */
import { apiFetch, parseError } from './client';
import type { Envelope } from './client';
import type { AuthUser } from '@/types/resource';

export async function authMe(): Promise<AuthUser | null> {
  const res = await apiFetch('/auth/me');
  if (res.status === 401) return null;
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<AuthUser>).data;
}

export async function authLogin(username: string, password: string): Promise<AuthUser> {
  const res = await apiFetch('/auth/login', {
    method: 'POST',
    body: JSON.stringify({ username, password }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<AuthUser>).data;
}

export async function authRegister(
  username: string,
  password: string,
  inviteCode: string,
): Promise<AuthUser> {
  const res = await apiFetch('/auth/register', {
    method: 'POST',
    body: JSON.stringify({ username, password, invite_code: inviteCode }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<AuthUser>).data;
}

export async function authLogout(): Promise<void> {
  await apiFetch('/auth/logout', { method: 'POST' });
}

export async function authChangePassword(
  currentPassword: string,
  newPassword: string,
): Promise<void> {
  const res = await apiFetch('/auth/password', {
    method: 'POST',
    body: JSON.stringify({
      current_password: currentPassword,
      new_password: newPassword,
    }),
  });
  if (!res.ok) throw new Error(await parseError(res));
}

export async function listUsers(): Promise<AuthUser[]> {
  const res = await apiFetch('/auth/users');
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<AuthUser[]>).data;
}

export async function adminCreateUser(
  username: string,
  password: string,
  isAdmin: boolean,
): Promise<AuthUser> {
  const res = await apiFetch('/auth/users', {
    method: 'POST',
    body: JSON.stringify({
      username,
      password,
      is_admin: isAdmin,
    }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<AuthUser>).data;
}

export async function adminSetUserRole(
  userId: number,
  isAdmin: boolean,
): Promise<AuthUser> {
  const res = await apiFetch(`/auth/users/${userId}/role`, {
    method: 'PUT',
    body: JSON.stringify({ is_admin: isAdmin }),
  });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<AuthUser>).data;
}

/** 强制下线：返回被吊销的会话数 */
export async function adminRevokeUserSessions(userId: number): Promise<number> {
  const res = await apiFetch(`/auth/users/${userId}/sessions/revoke`, {
    method: 'POST',
  });
  if (!res.ok) throw new Error(await parseError(res));
  const data = ((await res.json()) as Envelope<{ revoked: number }>).data;
  return data?.revoked ?? 0;
}

export async function adminDeleteUser(userId: number): Promise<void> {
  const res = await apiFetch(`/auth/users/${userId}`, { method: 'DELETE' });
  if (!res.ok) throw new Error(await parseError(res));
}

export async function adminResetUserPassword(
  userId: number,
  newPassword: string,
): Promise<void> {
  const res = await apiFetch(`/auth/users/${userId}/password`, {
    method: 'POST',
    body: JSON.stringify({ new_password: newPassword }),
  });
  if (!res.ok) throw new Error(await parseError(res));
}

export interface InviteCodes {
  admin: string;
  user: string;
}

export async function fetchInviteCodes(): Promise<InviteCodes> {
  const res = await apiFetch('/auth/invites');
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<InviteCodes>).data;
}

export async function rotateInviteCodes(): Promise<InviteCodes> {
  const res = await apiFetch('/auth/invites/rotate', { method: 'POST' });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<InviteCodes>).data;
}

