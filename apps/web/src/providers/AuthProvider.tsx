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
    void refresh();
  }, [refresh]);

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
        // 注册码决定角色：160223 管理员，1024 普通用户
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
