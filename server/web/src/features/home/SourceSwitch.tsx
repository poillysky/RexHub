'use client';

import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
} from 'react';
import { createPortal } from 'react-dom';
import { Check, ChevronDown } from 'lucide-react';

export type SearchScope = 'movie' | 'maker';

const OPTIONS: { id: SearchScope; label: string }[] = [
  { id: 'movie', label: '影视' },
  { id: 'maker', label: '片商' },
];

/** 嵌在搜索框左侧的搜索范围下拉 */
export function SourceSwitch({
  value,
  onChange,
}: {
  value: SearchScope;
  onChange: (v: SearchScope) => void;
}) {
  const [open, setOpen] = useState(false);
  const [menuBox, setMenuBox] = useState<CSSProperties | null>(null);
  const rootRef = useRef<HTMLDivElement | null>(null);
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const current = OPTIONS.find((o) => o.id === value) ?? OPTIONS[0];

  const placeMenu = () => {
    const el = triggerRef.current;
    if (!el) return;
    const r = el.getBoundingClientRect();
    const width = Math.min(140, Math.max(88, Math.round(r.width)));
    setMenuBox({
      position: 'fixed',
      top: r.bottom + 5,
      left: Math.max(8, Math.min(r.left, window.innerWidth - width - 8)),
      width,
      zIndex: 1100,
    });
  };

  useLayoutEffect(() => {
    if (!open) {
      setMenuBox(null);
      return;
    }
    placeMenu();
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setOpen(false);
    };
    const onPointer = (e: PointerEvent) => {
      const t = e.target as Node;
      const menuEl = document.getElementById('home-source-portal-menu');
      if (rootRef.current?.contains(t) || menuEl?.contains(t)) return;
      setOpen(false);
    };
    const onReflow = () => placeMenu();
    window.addEventListener('keydown', onKey);
    window.addEventListener('scroll', onReflow, true);
    window.addEventListener('resize', onReflow);
    const t = window.setTimeout(() => {
      window.addEventListener('pointerdown', onPointer, true);
    }, 0);
    return () => {
      window.clearTimeout(t);
      window.removeEventListener('keydown', onKey);
      window.removeEventListener('scroll', onReflow, true);
      window.removeEventListener('resize', onReflow);
      window.removeEventListener('pointerdown', onPointer, true);
    };
  }, [open]);

  const portal =
    typeof document !== 'undefined' && open && menuBox
      ? createPortal(
          <div
            id="home-source-portal-menu"
            className="home-search__source-menu"
            style={menuBox}
            role="listbox"
            aria-label="搜索范围"
          >
            {OPTIONS.map((o) => {
              const selected = o.id === value;
              return (
                <button
                  key={o.id}
                  type="button"
                  role="option"
                  aria-selected={selected}
                  className={`home-search__source-opt${selected ? ' is-selected' : ''}`}
                  onClick={() => {
                    onChange(o.id);
                    setOpen(false);
                  }}
                >
                  <span>{o.label}</span>
                  {selected ? (
                    <Check size={14} strokeWidth={2.4} aria-hidden />
                  ) : null}
                </button>
              );
            })}
          </div>,
          document.body,
        )
      : null;

  return (
    <div className="home-search__source" ref={rootRef}>
      <button
        type="button"
        ref={triggerRef}
        className="home-search__source-trigger"
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-label={`搜索范围：${current.label}`}
        onClick={() => setOpen((v) => !v)}
      >
        <span>{current.label}</span>
        <ChevronDown size={13} strokeWidth={2.25} aria-hidden />
      </button>
      {portal}
    </div>
  );
}

