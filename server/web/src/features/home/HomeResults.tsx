'use client';

import { useLayoutEffect, useRef, type RefObject } from 'react';
import { blurFocusedDescendant } from '@/lib/blurFocus';
import { HomeResultsChrome } from './HomeResultsChrome';
import { HomeResultsBody } from './HomeResultsBody';
import type { HomeScreenState } from './useHomeScreen';

type Props = {
  h: HomeScreenState;
  scrollBodyRef: RefObject<HTMLDivElement | null>;
  sentinelRef: RefObject<HTMLDivElement | null>;
};

export function HomeResults({ h, scrollBodyRef, sentinelRef }: Props) {
  const rootRef = useRef<HTMLDivElement>(null);
  const covered = h.detailHash != null;

  useLayoutEffect(() => {
    if (!covered) return;
    blurFocusedDescendant(rootRef.current);
  }, [covered]);

  return (
    <div
      ref={rootRef}
      className="home-search-screen"
      aria-hidden={covered || undefined}
    >
      <HomeResultsChrome h={h} />
      <HomeResultsBody h={h} scrollBodyRef={scrollBodyRef} sentinelRef={sentinelRef} />
    </div>
  );
}
