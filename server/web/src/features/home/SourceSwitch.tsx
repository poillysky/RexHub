'use client';

import {
  useEffect,
  useRef,
  useState,
  type CSSProperties,
  type KeyboardEvent as ReactKeyboardEvent,
} from 'react';
import { createPortal } from 'react-dom';
import { Check, ChevronDown } from 'lucide-react';

export type SearchScope = 'movie' | 'maker';

const OPTIONS: { id: SearchScope; label: string }[] = [
  { id: 'movie', label: '影视' },
  { id: 'maker', label: '片商' },
];

/** 菜单固定定位在触发器下方；下方空间不足时向上翻转，按视口左右边界收敛 */
function menuBoxFor(el: HTMLButtonElement): CSSProperties {
  const r = el.getBoundingClientRect();
  // 宽度按内容自适应，最窄不低于触发按钮，避免文字被挤到换行
  const minWidth = Math.min(160, Math.max(72, Math.round(r.width)));
  const menuHeight = 68;
  const below = window.innerHeight - r.bottom - 8;
  const top =
    below >= menuHeight
      ? r.bottom + 5
      : Math.max(8, Math.round(r.top - menuHeight - 5));
  return {
    position: 'fixed',
    top,
    left: Math.max(8, Math.min(r.left, window.innerWidth - minWidth - 8)),
    width: 'max-content',
    minWidth,
    // 弹层直挂 body：内联压过 body > * 的整屏高度，否则选项下方会留出大片空白
    height: 'auto',
    minHeight: 0,
    zIndex: 1100,
  };
}

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
  const optionRefs = useRef<Array<HTMLButtonElement | null>>([]);
  const current = OPTIONS.find((o) => o.id === value) ?? OPTIONS[0];

  const placeMenu = () => {
    const el = triggerRef.current;
    if (!el) return;
    const next = menuBoxFor(el);
    // 滚动时位置未变就不重渲染
    setMenuBox((prev) =>
      prev &&
      prev.top === next.top &&
      prev.left === next.left &&
      prev.minWidth === next.minWidth
        ? prev
        : next,
    );
  };

  const toggleOpen = () => {
    if (open) {
      setOpen(false);
      return;
    }
    const el = triggerRef.current;
    if (!el) return;
    setMenuBox(menuBoxFor(el));
    setOpen(true);
  };

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return;
      setOpen(false);
      // 关闭后焦点回到触发器，键盘操作不丢位置
      triggerRef.current?.focus();
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

  // 打开菜单后把焦点移到当前选项，方向键可直接切换
  useEffect(() => {
    if (!open) return;
    const frame = window.requestAnimationFrame(() => {
      const index = Math.max(0, OPTIONS.findIndex((o) => o.id === value));
      optionRefs.current[index]?.focus();
    });
    return () => window.cancelAnimationFrame(frame);
  }, [open, value]);

  function onMenuKeyDown(e: ReactKeyboardEvent<HTMLDivElement>) {
    if (e.key === 'Tab') {
      // 菜单挂在 body 末尾，Tab 出去会跳到无关区域，直接收起并回到触发器
      setOpen(false);
      triggerRef.current?.focus();
      return;
    }
    if (
      e.key !== 'ArrowDown' &&
      e.key !== 'ArrowUp' &&
      e.key !== 'Home' &&
      e.key !== 'End'
    ) {
      return;
    }
    e.preventDefault();
    const list = optionRefs.current.filter(
      (el): el is HTMLButtonElement => Boolean(el),
    );
    if (!list.length) return;
    const last = list.length - 1;
    const currentIndex = list.indexOf(document.activeElement as HTMLButtonElement);
    let next = currentIndex < 0 ? 0 : currentIndex;
    if (e.key === 'ArrowDown') next = currentIndex >= last ? 0 : currentIndex + 1;
    if (e.key === 'ArrowUp') next = currentIndex <= 0 ? last : currentIndex - 1;
    if (e.key === 'Home') next = 0;
    if (e.key === 'End') next = last;
    list[next]?.focus();
  }

  const portal =
    typeof document !== 'undefined' && open && menuBox
      ? createPortal(
          <div
            id="home-source-portal-menu"
            className="home-search__source-menu"
            style={menuBox}
            role="listbox"
            aria-label="搜索范围"
            onKeyDown={onMenuKeyDown}
          >
            {OPTIONS.map((o, index) => {
              const selected = o.id === value;
              return (
                <button
                  key={o.id}
                  type="button"
                  role="option"
                  tabIndex={-1}
                  ref={(el) => {
                    optionRefs.current[index] = el;
                  }}
                  aria-selected={selected}
                  className={`home-search__source-opt${selected ? ' is-selected' : ''}`}
                  onClick={() => {
                    onChange(o.id);
                    setOpen(false);
                    triggerRef.current?.focus();
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
        onClick={toggleOpen}
        onKeyDown={(e) => {
          if (open) return;
          if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
          e.preventDefault();
          toggleOpen();
        }}
      >
        <span>{current.label}</span>
        <ChevronDown size={13} strokeWidth={2.25} aria-hidden />
      </button>
      {portal}
    </div>
  );
}

