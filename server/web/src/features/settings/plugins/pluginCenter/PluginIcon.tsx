'use client';

import { Download, FileText, Package } from 'lucide-react';
import { useState } from 'react';
import { SoftImg } from '@/components/SoftImg';
import { pluginLogo } from './types';
import type { PluginEntry } from '@/lib/api';

export function PluginIcon({ entry, hero = false }: { entry: PluginEntry; hero?: boolean }) {
  const logo = pluginLogo(entry);
  /** 记录失败的 logo 地址；logo 变化后自动重试 */
  const [brokenLogo, setBrokenLogo] = useState('');
  const broken = brokenLogo === logo;
  const base = hero
    ? 'settings-nav__icon stremio-addon-hero__icon'
    : 'settings-nav__icon settings-nav__icon--orange';

  // 有品牌 logo 时用真实图标，去掉底色/阴影，尺寸由容器决定
  if (logo && !broken) {
    return (
      <span className={`${base} plugin-fw-logo`} aria-hidden>
        <SoftImg
          className="plugin-fw-logo__img"
          src={logo}
          loading="lazy"
          onError={() => setBrokenLogo(logo)}
        />
      </span>
    );
  }

  return (
    <span className={base} aria-hidden>
      {hero ? (
        <Package size={24} strokeWidth={2.1} />
      ) : entry.category === 'resource' ? (
        <Download size={17} strokeWidth={2.2} />
      ) : entry.category === 'subtitle' ? (
        <FileText size={17} strokeWidth={2.2} />
      ) : (
        <Package size={17} strokeWidth={2.2} />
      )}
    </span>
  );
}
