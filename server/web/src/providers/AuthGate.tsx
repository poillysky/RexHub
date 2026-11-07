'use client';

import { useEffect } from 'react';
import { usePathname, useRouter } from 'next/navigation';
import { AuthScreen } from '@/features/auth/AuthScreen';
import { AppFrame } from '@/components/layout/AppFrame';
import { useAuth } from './AuthProvider';

/**
 * 色花认证模式：未登录始终钉在 `/` 渲染登录页，
 * 避免从 /login 添加到主屏幕导致 PWA scope 异常。
 */
export function AuthGate({ children }: { children: React.ReactNode }) {
  const { status } = useAuth();
  const pathname = usePathname() || '/';
  const router = useRouter();

  useEffect(() => {
    if (status === 'loading') return;

    if (status === 'anonymous' && pathname !== '/') {
      router.replace('/', { scroll: false });
      return;
    }

    if (
      status === 'authenticated' &&
      (pathname === '/login' || pathname.startsWith('/login/'))
    ) {
      router.replace('/', { scroll: false });
    }
  }, [status, pathname, router]);

  if (status === 'loading') {
    return (
      <AppFrame>
        <div className="auth-boot" aria-busy="true" aria-label="加载中" />
      </AppFrame>
    );
  }

  if (status === 'anonymous') {
    if (pathname !== '/') {
      return (
        <AppFrame>
          <div className="auth-boot" aria-busy="true" aria-label="前往登录" />
        </AppFrame>
      );
    }
    return (
      <AppFrame>
        <div className="auth-viewport">
          <AuthScreen />
        </div>
      </AppFrame>
    );
  }

  if (pathname === '/login' || pathname.startsWith('/login/')) {
    return (
      <AppFrame>
        <div className="auth-boot" aria-busy="true" aria-label="进入首页" />
      </AppFrame>
    );
  }

  return <>{children}</>;
}
