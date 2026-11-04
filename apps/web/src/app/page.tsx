'use client';

import { useEffect } from 'react';
import { AppShell, TabProvider, TabPane } from '@/shell';
import { HomeScreen } from '@/features/home/HomeScreen';
import { MediaScreen } from '@/features/media/MediaScreen';
import { SettingsScreen } from '@/features/settings/SettingsScreen';
import { registerServiceWorker } from '@/lib/pwa';
import { AuthGate } from '@/providers/AuthGate';
import { AppFrame } from '@/components/layout/AppFrame';

export default function HomePage() {
  useEffect(() => {
    registerServiceWorker();
  }, []);

  return (
    <AuthGate>
      <AppFrame>
        <TabProvider>
          <AppShell>
            <TabPane tab="/">
              <HomeScreen />
            </TabPane>
            <TabPane tab="/media">
              <MediaScreen />
            </TabPane>
            <TabPane tab="/settings">
              <SettingsScreen />
            </TabPane>
          </AppShell>
        </TabProvider>
      </AppFrame>
    </AuthGate>
  );
}
