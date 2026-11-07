'use client';

import { useMemo, useRef, useState, type ReactNode } from 'react';
import {
  ArrowUp,
  ArrowUpDown,
  BadgeCheck,
  Captions,
  ChevronDown,
  Clock,
  Gift,
  Globe,
  Layers,
  Loader2,
  Monitor,
  Server,
  Tv,
  Users,
  Video,
  type LucideIcon,
} from 'lucide-react';
import {
  fetchMpDownloadStatus,
  submitMpDownload,
  type MediaItem,
  type MpTorrentItem,
} from '@/lib/api';
import { AppMsg, type AppMsgTone } from '@/components/ui/AppMsg';
import { AppCenterModal } from '@/components/ui/AppCenterModal';
import { useMpSearch } from './useMediaQueries';

function formatSize(bytes: number | null): string {
  if (!bytes || bytes <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value >= 100 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`;
}

/** PT 站结果里中文名往往匹配不到，优先用原名搜索 */
function defaultKeyword(item: MediaItem): string {
  return (item.originalTitle || item.title || '').trim();
}

type SortBy = 'seeders' | 'size' | 'date';

function torrentSites(t: { site: string; sites?: string[] }): string[] {
  return t.sites?.length ? t.sites : t.site ? [t.site] : [];
}

const SORT_LABEL: Record<SortBy, string> = {
  seeders: '做种优先',
  size: '体积最大',
  date: '最新发布',
};

/* —— 资源名解析：筛选维度与卡片标签共用同一套推断 —— */

function resolutionOf(text: string): string {
  return (
    text
      .match(/\b(2160p|1080p|1080i|720p|576p|480p)\b/i)?.[1]
      .toLowerCase() || (/\b(4k|uhd)\b/i.test(text) ? '2160p' : '')
  );
}

function sourceOf(text: string): string {
  if (/uhd\s*(blu-?ray|remux)/i.test(text)) return 'UHD BluRay';
  if (/blu-?ray\s*remux|remux/i.test(text)) return 'REMUX';
  if (/blu-?ray/i.test(text)) return 'BluRay';
  if (/web-?dl/i.test(text)) return 'WEB-DL';
  if (/web-?rip/i.test(text)) return 'WEBRip';
  if (/hdtv/i.test(text)) return 'HDTV';
  if (/bdrip/i.test(text)) return 'BDRip';
  if (/dvdrip/i.test(text)) return 'DVDRip';
  return '';
}

function codecOf(text: string): string {
  if (/hevc|h\.?265|x265/i.test(text)) return 'HEVC';
  if (/avc|h\.?264|x264/i.test(text)) return 'AVC';
  if (/\bav1\b/i.test(text)) return 'AV1';
  return '';
}

function audioOf(text: string): string {
  if (/atmos/i.test(text)) return 'Atmos';
  if (/dts[- ]?hd/i.test(text)) return 'DTS-HD';
  if (/truehd/i.test(text)) return 'TrueHD';
  if (/\bdts\b/i.test(text)) return 'DTS';
  if (/flac/i.test(text)) return 'FLAC';
  if (/aac/i.test(text)) return 'AAC';
  if (/ac-?3|eac3|ddp/i.test(text)) return 'AC3';
  return '';
}

function groupOf(text: string): string {
  return text.match(/[-\s]([A-Za-z][A-Za-z0-9._@-]{2,24})\s*$/)?.[1] || '';
}

/** 下载器状态 → 中文提示 */
function downloadStateText(state: string | null | undefined): string {
  const text = (state || '').toLowerCase();
  if (/error|fail|失败/.test(text)) return '下载任务异常';
  if (/finish|complete|完成/.test(text)) return '下载已完成';
  if (/seed|做种/.test(text)) return '已下载完成，正在做种';
  if (/pause|暂停/.test(text)) return '任务已暂停';
  if (/stop|停止/.test(text)) return '任务已停止';
  return '已开始下载';
}

type FacetKey =
  | 'site'
  | 'season'
  | 'web'
  | 'sub'
  | 'promo'
  | 'codec'
  | 'edition'
  | 'res'
  | 'team';

/**
 * 与 MoviePilot 资源筛选条一一对应（维度、顺序、取值来源都相同）：
 * 站点 / 季集 / 源 / 字幕 / 促销状态 / 视频编码 / 质量 / 分辨率 / 制作组
 */
const FACETS: Array<{ key: FacetKey; label: string; icon: LucideIcon }> = [
  { key: 'site', label: '站点', icon: Server },
  { key: 'season', label: '季集', icon: Tv },
  { key: 'web', label: '源', icon: Globe },
  { key: 'sub', label: '字幕', icon: Captions },
  { key: 'promo', label: '促销状态', icon: Gift },
  { key: 'codec', label: '视频编码', icon: Video },
  { key: 'edition', label: '质量', icon: BadgeCheck },
  { key: 'res', label: '分辨率', icon: Monitor },
  { key: 'team', label: '制作组', icon: Users },
];

const EMPTY_FILTERS: Record<FacetKey, string[]> = {
  site: [],
  season: [],
  web: [],
  sub: [],
  promo: [],
  codec: [],
  edition: [],
  res: [],
  team: [],
};

/** MP 只把这两个标签订为字幕维度 */
const SUBTITLE_LABELS = new Set(['中字', '特效']);

/** 一条资源在某个维度上的取值，直接取 MP meta_info（与 MP 筛选规则一致） */
function facetValues(t: MpTorrentItem, key: FacetKey): string[] {
  switch (key) {
    case 'site':
      return torrentSites(t);
    case 'season':
      return t.seasonEpisode ? [t.seasonEpisode] : [];
    case 'web':
      return t.webSource ? [t.webSource] : [];
    case 'sub':
      return (t.labels || []).filter((label) => SUBTITLE_LABELS.has(label));
    case 'promo':
      return t.volumeFactor ? [t.volumeFactor] : [];
    case 'codec':
      return t.videoCode ? [t.videoCode] : [];
    case 'edition':
      return t.edition ? [t.edition] : [];
    case 'res':
      return t.resolution ? [t.resolution] : [];
    case 'team':
      return t.releaseGroup ? [t.releaseGroup] : [];
    default:
      return [];
  }
}

/** MP 的季集排序：按季、集降序 */
function seasonOptionRank(a: string, b: string): number {
  const parse = (str: string) => {
    const s = str.match(/S(\d+)(?:-S(\d+))?/);
    const e = str.match(/E(\d+)(?:-E(\d+))?/);
    return {
      s1: s?.[1] ? Number(s[1]) : 0,
      s2: s?.[2] ? Number(s[2]) : 0,
      e1: e?.[1] ? Number(e[1]) : 0,
      e2: e?.[2] ? Number(e[2]) : 0,
    };
  };
  const x = parse(a);
  const y = parse(b);
  return y.s1 - x.s1 || y.s2 - x.s2 || y.e1 - x.e1 || y.e2 - x.e2;
}


const RELEASE_CUT =
  /(?:^|[\s._\-[(])((?:19|20)\d{2}|2160p|1080p|1080i|720p|576p|480p|4k|uhd|blu-?ray|remux|web-?dl|web-?rip|hdtv|hdrip|bdrip|dvdrip|hevc|h\.?26[45]|x26[45]|avc)\b/i;

/** 把资源名拆成「片名 + 完整文件名」，对齐 MP 卡片的标题 / 副标题结构 */
function splitName(name: string): { title: string; rest: string } {
  const m = name.match(RELEASE_CUT);
  const cut =
    m && typeof m.index === 'number' && m.index > 1
      ? name.slice(0, m.index)
      : name;
  const head = cut
    .split(/\s*[|｜]\s*|\s+\/\s+/)[0]
    .replace(/[._]/g, ' ')
    .replace(/[\s\-–—()[\]】]+$/, '')
    .replace(/\s{2,}/g, ' ')
    .trim();
  if (head.length < 2 || head === name.trim()) return { title: name, rest: '' };
  return { title: head, rest: name };
}

type PillTone = 'source' | 'res' | 'codec' | 'audio' | 'group';

/** 从文件名里提取发行标签，做成 MP 那种彩色小胶囊 */
function releaseTags(name: string): Array<{ label: string; tone: PillTone }> {
  const text = name || '';
  const out: Array<{ label: string; tone: PillTone }> = [];
  const add = (label: string, tone: PillTone) => {
    if (label && out.length < 4) out.push({ label, tone });
  };

  add(sourceOf(text), 'source');
  add(resolutionOf(text), 'res');
  add(codecOf(text), 'codec');
  add(groupOf(text), 'group');
  add(audioOf(text), 'audio');

  return out;
}

function Chip({
  active,
  onClick,
  children,
}: {
  active: boolean;
  onClick: () => void;
  children: ReactNode;
}) {
  return (
    <button
      type="button"
      className={
        active ? 'media-explore__chip is-active' : 'media-explore__chip'
      }
      aria-pressed={active}
      onClick={onClick}
    >
      {children}
    </button>
  );
}

/** 搜索方式由详情页弹窗选择后传入，页面内不再切换 */
export function MediaPtSearchBody({
  item,
  mode = 'title',
}: {
  item: MediaItem;
  mode?: 'title' | 'imdbid';
}) {
  const keyword = defaultKeyword(item);
  // IMDb 编号由 MoviePilot 按条目解析，本地没有 imdbId 也能走这条链路
  const area: 'title' | 'imdbid' = mode === 'imdbid' ? 'imdbid' : 'title';
  const [filters, setFilters] = useState<Record<FacetKey, string[]>>(() => ({
    ...EMPTY_FILTERS,
  }));
  const [sort, setSort] = useState<SortBy>('seeders');
  const [panel, setPanel] = useState<FacetKey | null>(null);
  const [confirmItem, setConfirmItem] = useState<MpTorrentItem | null>(null);
  const [dlMsg, setDlMsg] = useState<{
    text: string;
    tone: AppMsgTone;
  } | null>(null);
  const dlBusy = useRef(false);
  const result = useMpSearch({
    keyword,
    page: 1,
    source: item.source,
    id: item.id,
    mediaType: item.mediaType,
    area,
  });

  const items = result.data?.items || [];

  // 各筛选维度的候选值与命中数（跨站点合并后一条资源可能挂在多个站点）
  const facetOptions = useMemo(() => {
    const out = {} as Record<FacetKey, Array<[string, number]>>;
    for (const { key } of FACETS) {
      const map = new Map<string, number>();
      for (const t of items) {
        for (const value of facetValues(t, key)) {
          map.set(value, (map.get(value) || 0) + 1);
        }
      }
      out[key] =
        key === 'season'
          ? Array.from(map.entries()).sort((a, b) => seasonOptionRank(a[0], b[0]))
          : Array.from(map.entries()).sort((a, b) => b[1] - a[1]);
    }
    return out;
  }, [items]);

  const visible = useMemo(() => {
    const list = items.filter((t) => {
      for (const { key } of FACETS) {
        const want = filters[key];
        // 与 MP 一致：任一所选值命中即通过
        if (
          want.length > 0 &&
          !facetValues(t, key).some((value) => want.includes(value))
        ) {
          return false;
        }
      }
      return true;
    });
    if (sort === 'seeders') list.sort((a, b) => b.seeders - a.seeders);
    else if (sort === 'size') list.sort((a, b) => (b.size || 0) - (a.size || 0));
    else
      list.sort((a, b) =>
        String(b.pubdate || '').localeCompare(String(a.pubdate || '')),
      );
    return list;
  }, [items, filters, sort]);

  // IMDb 模式由条目 id 驱动，不需要关键词；标题模式必须有关键词
  const searched = area === 'imdbid' ? Boolean(item.id) : Boolean(keyword);
  const loading = searched && (result.isPending || result.isPlaceholderData);
  const err = result.isError
    ? result.error instanceof Error
      ? result.error.message
      : '搜索失败'
    : '';

  function toggleFilter(key: FacetKey, value: string) {
    setFilters((prev) => {
      const cur = prev[key];
      return {
        ...prev,
        [key]: cur.includes(value)
          ? cur.filter((v) => v !== value)
          : [...cur, value],
      };
    });
  }

  function clearFilter(key: FacetKey) {
    setFilters((prev) => ({ ...prev, [key]: [] }));
  }

  /** 提交后轮询下载器：先 1s 一次，之后 2s 一次，最多约 1 分钟 */
  async function waitForDownload(downloadId: string, title: string) {
    for (let i = 0; i < 30; i += 1) {
      await new Promise((resolve) => setTimeout(resolve, i < 5 ? 1000 : 2000));
      try {
        const status = await fetchMpDownloadStatus({ downloadId, title });
        if (status.found) return status;
      } catch {
        // 单次轮询失败不打断，继续等下载器响应
      }
    }
    return null;
  }

  async function submitDownload(t: MpTorrentItem) {
    if (dlBusy.current) return;
    const key = (t.downloadKey || '').trim();
    if (!key) {
      setDlMsg({ text: '资源信息已过期，请重新搜索后再提交', tone: 'warn' });
      return;
    }
    dlBusy.current = true;
    setDlMsg(null);
    try {
      const task = await submitMpDownload({
        key,
        source: item.source,
        mediaId: item.id,
        mediaType: item.mediaType,
        title: item.title,
        originalTitle: item.originalTitle,
        year: item.year,
        posterUrl: item.posterUrl,
      });
      const status = await waitForDownload(task.downloadId, t.title);
      if (status) {
        setDlMsg({
          text: `${downloadStateText(status.state)}：${t.title}`,
          tone: /error|fail|失败/i.test(status.state || '') ? 'err' : 'ok',
        });
      } else {
        setDlMsg({
          text: `已提交下载，正在等待下载器响应：${t.title}`,
          tone: 'info',
        });
      }
    } catch (e) {
      setDlMsg({
        text: e instanceof Error ? e.message : '提交下载失败',
        tone: 'err',
      });
    } finally {
      dlBusy.current = false;
    }
  }

  return (
    <div className="media-search media-pt">
      {loading ? (
        <div className="media-pt__loading" role="status">
          <Loader2
            className="media-pt__spinner"
            size={22}
            strokeWidth={2.2}
            aria-hidden
          />
          <span>正在搜索 PT 站点…</span>
          <span className="media-pt__loading-hint">
            MoviePilot 会并发请求全部已启用站点，通常需要几秒
          </span>
        </div>
      ) : null}

      {!loading && err ? (
        <p className="media-empty allow-select">{err}</p>
      ) : null}

      {!loading && !err && searched && items.length === 0 ? (
        <p className="media-empty">没有找到资源</p>
      ) : null}

      {!loading && !err && items.length > 0 ? (
        <>
          <div className="media-pt__panel">
            <div className="media-pt__panel-head">
              <span className="media-pt__count">
                <Layers size={13} strokeWidth={2.1} aria-hidden />
                {visible.length === items.length
                  ? `${items.length} 个资源`
                  : `${visible.length} / ${items.length} 个资源`}
              </span>
              <label className="media-pt__sort">
                <ArrowUpDown size={13} strokeWidth={2.1} aria-hidden />
                <span>{SORT_LABEL[sort]}</span>
                <ChevronDown size={13} strokeWidth={2.1} aria-hidden />
                <select
                  className="media-pt__sort-select"
                  value={sort}
                  aria-label="排序方式"
                  onChange={(e) => setSort(e.target.value as SortBy)}
                >
                  {(Object.keys(SORT_LABEL) as SortBy[]).map((key) => (
                    <option key={key} value={key}>
                      {SORT_LABEL[key]}
                    </option>
                  ))}
                </select>
              </label>
            </div>

            <div className="media-pt__grid">
              {FACETS.map(({ key, label, icon: Icon }) => {
                // 与 MP 一致：该维度没有任何候选值时不出现在筛选条
                if (facetOptions[key].length === 0) return null;
                return (
                  <button
                    key={key}
                    type="button"
                    className={[
                      'media-pt__card',
                      filters[key].length ? 'is-active' : '',
                      panel === key ? 'is-open' : '',
                    ]
                      .filter(Boolean)
                      .join(' ')}
                    aria-expanded={panel === key}
                    onClick={() => setPanel((v) => (v === key ? null : key))}
                  >
                    <Icon size={17} strokeWidth={1.9} aria-hidden />
                    <span className="media-pt__card-label">{label}</span>
                  </button>
                );
              })}
            </div>

            <AppCenterModal
              open={Boolean(panel)}
              title={FACETS.find((f) => f.key === panel)?.label || '筛选'}
              onClose={() => setPanel(null)}
              cardClassName="media-pt-filter-modal"
            >
              {panel ? (
                <div className="media-pt__options">
                  <div className="media-pt__chips">
                    <Chip
                      active={filters[panel].length === 0}
                      onClick={() => clearFilter(panel)}
                    >
                      全部{panel === 'site' ? ` ${items.length}` : ''}
                    </Chip>
                    {facetOptions[panel].map(([value, count]) => (
                      <Chip
                        key={value}
                        active={filters[panel].includes(value)}
                        onClick={() => toggleFilter(panel, value)}
                      >
                        {value} {count}
                      </Chip>
                    ))}
                  </div>
                </div>
              ) : null}
              <footer className="media-pt-filter-modal__foot">
                <button
                  type="button"
                  className="media-pt-filter-modal__done"
                  onClick={() => setPanel(null)}
                >
                  完成
                </button>
              </footer>
            </AppCenterModal>
          </div>

          {visible.length === 0 ? (
            <p className="media-empty">当前筛选条件下没有资源</p>
          ) : (
            <div className="media-pt__list">
              {visible.map((t, i) => {
                const { title, rest } = splitName(t.title);
                const pills = releaseTags(t.title);
                return (
                  <div
                    key={`${t.site}-${t.title}-${i}`}
                    className="media-pt__row"
                    role="button"
                    tabIndex={0}
                    onClick={() => {
                      if (!dlBusy.current) setConfirmItem(t);
                    }}
                    onKeyDown={(e) => {
                      if (dlBusy.current) return;
                      if (e.key === 'Enter' || e.key === ' ') {
                        e.preventDefault();
                        setConfirmItem(t);
                      }
                    }}
                  >
                    <div className="media-pt__row-main">
                    <span className="media-pt__row-head">
                      <a
                        className="media-pt__title allow-select"
                        href={t.pageUrl || undefined}
                        target="_blank"
                        rel="noreferrer"
                        onClick={(e) => e.stopPropagation()}
                      >
                        {title}
                      </a>
                      <span className="media-pt__badges">
                        {t.volumeFactor ? (
                          <span
                            className={
                              t.volumeFactor.includes('免费')
                                ? 'media-pt__tag is-free'
                                : 'media-pt__tag is-promo'
                            }
                          >
                            {t.volumeFactor}
                          </span>
                        ) : null}
                        {t.hitAndRun ? (
                          <span className="media-pt__tag is-hr">H&amp;R</span>
                        ) : null}
                      </span>
                    </span>

                    <span className="media-pt__row-meta">
                      <span className="media-pt__sites">
                        {torrentSites(t).map((name) => (
                          <span className="media-pt__site" key={name}>
                            {name}
                          </span>
                        ))}
                      </span>
                      <span className="media-pt__seed">
                        <ArrowUp size={12} strokeWidth={2.4} aria-hidden />
                        {t.seeders}
                      </span>
                    </span>

                    {rest ? (
                      <span className="media-pt__name allow-select">
                        {rest}
                      </span>
                    ) : null}

                    {t.description ? (
                      <span className="media-pt__desc allow-select">
                        {t.description}
                      </span>
                    ) : null}

                    {t.dateElapsed || t.pubdate || t.category ? (
                      <span className="media-pt__row-sub">
                        {t.dateElapsed || t.pubdate ? (
                          <span className="media-pt__date">
                            <Clock size={12} strokeWidth={2} aria-hidden />
                            {t.dateElapsed || t.pubdate}
                          </span>
                        ) : null}
                        {t.category ? (
                          <span className="media-pt__cat">{t.category}</span>
                        ) : null}
                      </span>
                    ) : null}

                    {pills.length || t.size ? (
                      <span className="media-pt__row-foot">
                        <span className="media-pt__tags">
                          {pills.map((p) => (
                            <span
                              className={`media-pt__pill is-${p.tone}`}
                              key={`${p.tone}-${p.label}`}
                            >
                              {p.label}
                            </span>
                          ))}
                        </span>
                        {t.size ? (
                          <span className="media-pt__size">
                            {formatSize(t.size)}
                          </span>
                        ) : null}
                      </span>
                    ) : null}
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </>
      ) : null}

      <AppCenterModal
        open={Boolean(confirmItem)}
        title="确认下载"
        onClose={() => setConfirmItem(null)}
        cardClassName="media-pt-confirm-modal"
      >
        {confirmItem ? (
          <div className="media-pt-confirm">
            <p className="media-pt-confirm__name allow-select">
              {confirmItem.title}
            </p>
            <div className="media-pt-confirm__meta">
              <span>{torrentSites(confirmItem).join(' / ')}</span>
              {confirmItem.size ? <span>{formatSize(confirmItem.size)}</span> : null}
              <span>做种 {confirmItem.seeders ?? 0}</span>
            </div>
            <p className="media-pt-confirm__tip">
              将把该资源提交到 MoviePilot 下载器，确定继续？
            </p>
            <div className="media-pt-confirm__actions">
              <button
                type="button"
                className="media-pt-confirm__btn"
                onClick={() => setConfirmItem(null)}
              >
                取消
              </button>
              <button
                type="button"
                className="media-pt-confirm__btn is-primary"
                onClick={() => {
                  const target = confirmItem;
                  setConfirmItem(null);
                  void submitDownload(target);
                }}
              >
                确认下载
              </button>
            </div>
          </div>
        ) : null}
      </AppCenterModal>

      {dlMsg ? (
        <AppMsg
          tone={dlMsg.tone}
          duration={3600}
          allowSelect
          onDismiss={() => setDlMsg(null)}
        >
          {dlMsg.text}
        </AppMsg>
      ) : null}
    </div>
  );
}
