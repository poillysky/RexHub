'use client';

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from 'react';
import {
  authLogin,
  authLogout,
  authMe,
  authRegister,
} from '@/lib/api';
import type { AuthUser } from '@/types/resource';

type Status = 'loading' | 'anonymous' | 'authenticated';

type AuthContextValue = {
  status: Status;
  user: AuthUser | null;
  /** 管理员：通过管理员注册码注册的账号 */
  isAdmin: boolean;
  login: (u: string, p: string) => Promise<void>;
  register: (u: string, p: string, inviteCode: string) => Promise<void>;
  logout: () => Promise<void>;
  refresh: () => Promise<void>;
};

const AuthCtx = createContext<AuthContextValue | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [status, setStatus] = useState<Status>('loading');
  const [user, setUser] = useState<AuthUser | null>(null);

  const refresh = useCallback(async () => {
    try {
      const me = await authMe();
      setUser(me);
      setStatus(me ? 'authenticated' : 'anonymous');
    } catch {
      setUser(null);
      setStatus('anonymous');
    }
  }, []);

  useEffect(() => {
    let alive = true;
    const apply = (me: AuthUser | null) => {
      if (!alive) return;
      setUser(me);
      setStatus(me ? 'authenticated' : 'anonymous');
    };
    // 挂载后异步拉一次会话；setState 在回调里，避免同步渲染级联
    authMe().then(apply, () => apply(null));
    return () => {
      alive = false;
    };
  }, []);

  // 任意请求返回 401（会话过期 / 被踢）时立刻回到未登录态
  useEffect(() => {
    const onUnauthorized = () => {
      setUser(null);
      setStatus('anonymous');
    };
    window.addEventListener('rexhub:unauthorized', onUnauthorized);
    return () => {
      window.removeEventListener('rexhub:unauthorized', onUnauthorized);
    };
  }, []);

  const isAdmin = Boolean(user?.is_admin);

  const value = useMemo<AuthContextValue>(
    () => ({
      status,
      user,
      isAdmin,
      refresh,
      async login(u, p) {
        const me = await authLogin(u, p);
        setUser(me);
        setStatus('authenticated');
      },
      async register(u, p, inviteCode) {
        // 邀请码存元库，由后端决定注册角色（管理员 / 普通用户）
        const me = await authRegister(u, p, inviteCode);
        setUser(me);
        setStatus('authenticated');
      },
      async logout() {
        await authLogout();
        setUser(null);
        setStatus('anonymous');
      },
    }),
    [status, user, isAdmin, refresh],
  );

  return <AuthCtx.Provider value={value}>{children}</AuthCtx.Provider>;
}

export function useAuth() {
  const ctx = useContext(AuthCtx);
  if (!ctx) throw new Error('useAuth must be used within AuthProvider');
  return ctx;
}
