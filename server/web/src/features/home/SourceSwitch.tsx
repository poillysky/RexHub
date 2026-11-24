'use client';

export type SearchScope = 'movie' | 'maker';

const OPTIONS: { id: SearchScope; label: string }[] = [
  { id: 'movie', label: '影视' },
  { id: 'maker', label: '片商' },
];

/** 嵌在搜索框左侧的搜索范围切换：点一下在影视 / 片商之间来回切 */
export function SourceSwitch({
  value,
  onChange,
}: {
  value: SearchScope;
  onChange: (v: SearchScope) => void;
}) {
  const current = OPTIONS.find((o) => o.id === value) ?? OPTIONS[0];
  const next = OPTIONS.find((o) => o.id !== value) ?? OPTIONS[0];

  return (
    <div className="home-search__source">
      <button
        type="button"
        className="home-search__source-trigger"
        aria-label={`搜索范围：${current.label}，点击切换到${next.label}`}
        title={`切换到${next.label}`}
        onClick={() => onChange(next.id)}
      >
        <span>{current.label}</span>
      </button>
    </div>
  );
}

