'use client';

import { useEffect, useState } from 'react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { initTheme } from '@/lib/theme';
import { AuthProvider } from '@/providers/AuthProvider';
import { AppViewport } from '@/components/layout/AppViewport';
import { OverlayProvider } from '@/components/overlay/OverlayContext';

function makeQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        staleTime: 30 * 1000,
        refetchOnWindowFocus: true,
      },
    },
  });
}

let browserQueryClient: QueryClient | undefined;

function getQueryClient() {
  if (typeof window === 'undefined') return makeQueryClient();
  if (!browserQueryClient) browserQueryClient = makeQueryClient();
  return browserQueryClient;
}

export function Providers({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(getQueryClient);

  // 主题：#theme-dark 类名全站生效，跟随系统时随系统切换
  useEffect(() => initTheme(), []);

  return (
    <QueryClientProvider client={queryClient}>
      <AppViewport />
      <AuthProvider>
        <OverlayProvider>{children}</OverlayProvider>
      </AuthProvider>
    </QueryClientProvider>
  );
}
