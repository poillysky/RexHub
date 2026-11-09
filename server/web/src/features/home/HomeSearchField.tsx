'use client';

import { Languages, Search, X } from 'lucide-react';
import { useEffect, useRef, useState } from 'react';
import { useOverlay } from '@/components/overlay/OverlayContext';
import { fetchTranslate } from '@/lib/api';
import { SourceSwitch, type SearchScope } from './SourceSwitch';

/** 聚焦并全选输入内容，供快捷键与清空复用 */
function focusAndSelect(input: HTMLInputElement | null) {
  if (!input) return;
  input.focus();
  input.select();
}

/** 色花一体式搜索框：hero 居中 / compact 顶栏 + 译英 */
export function HomeSearchField({
  draft,
  size,
  busy,
  source,
  onSourceChange,
  showSource = false,
  onDraftChange,
  onSubmit,
  onClear,
}: {
  draft: string;
  size: 'hero' | 'compact';
  busy?: boolean;
  source?: SearchScope;
  onSourceChange?: (v: SearchScope) => void;
  showSource?: boolean;
  onDraftChange: (v: string) => void;
  onSubmit: () => void;
  onClear: () => void;
}) {
  const { toast } = useOverlay();
  const [translating, setTranslating] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);
  const sourceVisible =
    showSource && source != null && typeof onSourceChange === 'function';

  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      const el = e.target as HTMLElement | null;
      const typing =
        el?.tagName === 'INPUT' ||
        el?.tagName === 'TEXTAREA' ||
        el?.tagName === 'SELECT' ||
        el?.isContentEditable === true;
      if (typing) return;
      const isShortcut =
        ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') || e.key === '/';
      if (!isShortcut) return;
      // 弹窗打开时不抢焦点，避免焦点落到被遮挡的搜索框
      if (document.querySelector('[aria-modal="true"], .app-modal-overlay')) return;
      const input = inputRef.current;
      if (!input || input.offsetParent === null) return;
      e.preventDefault();
      focusAndSelect(input);
    }
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, []);

  async function handleTranslate() {
    const text = draft.trim();
    if (!text) {
      toast('请输入要翻译的文字', 'info');
      return;
    }
    if (text.length < 2) {
      toast('请输入至少 2 个字符', 'info');
      return;
    }
    setTranslating(true);
    try {
      const data = await fetchTranslate(text);
      onDraftChange(String(data.text || text));
      if (data.alreadyEnglish) {
        toast('内容已是英文', 'info');
      } else if (data.engine === 'tmdb') {
        toast('已匹配 TMDB 英文片名，请点击搜索', 'success');
      } else {
        toast('已翻译为英文，请点击搜索', 'success');
      }
    } catch (e) {
      toast(e instanceof Error ? e.message : '翻译失败，请稍后重试', 'error');
    } finally {
      setTranslating(false);
    }
  }

  // 空输入点搜索时把焦点交还输入框，避免按钮点了没反应
  function handleSubmit() {
    if (!draft.trim()) {
      focusAndSelect(inputRef.current);
      return;
    }
    onSubmit();
  }

  return (
    <div
      role="search"
      className={
        size === 'hero'
          ? 'home-search__field home-search__field--hero'
          : 'home-search__field'
      }
    >
      <div
        className={[
          'home-search__control',
          size === 'hero' ? 'home-search__control--hero' : 'home-search__control--compact',
          sourceVisible ? 'home-search__control--with-source' : '',
        ]
          .filter(Boolean)
          .join(' ')}
      >
        {sourceVisible ? (
          <>
            <SourceSwitch value={source} onChange={onSourceChange} />
            <span className="home-search__split" aria-hidden />
          </>
        ) : null}
        <label className="home-search__label">
          <span className="sr-only">搜索</span>
          <input
            ref={inputRef}
            className="home-search__input"
            type="search"
            enterKeyHint="search"
            autoComplete="off"
            autoCorrect="off"
            spellCheck={false}
            placeholder="搜索片名、番号或关键词"
            value={draft}
            onChange={(e) => onDraftChange(e.target.value)}
            onKeyDown={(e) => {
              if (e.key !== 'Enter') return;
              // 输入法确认候选词时按 Enter 不应当触发搜索
              if (e.nativeEvent.isComposing || e.keyCode === 229) return;
              e.preventDefault();
              if (!draft.trim()) return;
              (e.target as HTMLInputElement).blur();
              onSubmit();
            }}
          />
        </label>
        <div className="home-search__actions">
          {size === 'hero' && !draft ? (
            <kbd className="home-search__kbd" aria-hidden>
              ⌘K
            </kbd>
          ) : null}
          {draft ? (
            <button
              type="button"
              className="home-search__clear"
              aria-label="清除"
              onClick={() => {
                onClear();
                // 清空后焦点留在输入框，方便直接重新输入
                focusAndSelect(inputRef.current);
              }}
            >
              <X size={16} strokeWidth={2.25} aria-hidden />
            </button>
          ) : null}
          {draft ? (
            <button
              type="button"
              className="home-search__translate"
              title="翻译为英文"
              aria-label="翻译为英文"
              aria-busy={translating || undefined}
              disabled={translating}
              onClick={() => void handleTranslate()}
            >
              {translating ? (
                <span className="home-search__translate-spin" aria-hidden />
              ) : (
                <Languages size={17} strokeWidth={2} aria-hidden />
              )}
            </button>
          ) : null}
          <button
            type="button"
            className="home-search__go"
            aria-label="搜索"
            aria-busy={busy || undefined}
            disabled={busy}
            onClick={handleSubmit}
          >
            {busy ? (
              <span className="home-search__spinner" aria-hidden />
            ) : (
              <Search size={18} strokeWidth={2.25} aria-hidden />
            )}
          </button>
        </div>
      </div>
    </div>
  );
}
