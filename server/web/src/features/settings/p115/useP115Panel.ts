'use client';

import { useEffect, useRef, useState } from 'react';
import {
  clearP115Tasks,
  completeP115Qrcode,
  deleteP115Task,
  getP115,
  getP115ExtractConfig,
  getP115ExtractPreview,
  getP115ExtractStatus,
  getP115Status,
  getPan115Snapshot,
  listP115Folders,
  listP115Tasks,
  pollP115Qrcode,
  putP115,
  putP115ExtractConfig,
  startP115Extract,
  startP115Qrcode,
  stopP115Extract,
  validateP115,
  type Pan115Account,
  type P115ClearMode,
  type P115Config,
  type P115ExtractConfig,
  type P115ExtractItem,
  type P115ExtractStatus,
  type P115FolderItem,
  type P115QrStart,
  type P115QrApp,
  type P115SaveSource,
  type P115TargetFolder,
  type P115Task,
} from '@/lib/api';
import {
  getP115PanelCache,
  isP115PanelCacheFresh,
  patchP115PanelCache,
  setP115PanelCache,
  cacheFromP115Config,
} from '../p115PanelCache';
import { usePanelAction } from '@/hooks/usePanelAction';
import { useAuth } from '@/providers/AuthProvider';

import {
  emptyTargets,
  normalizeTargets,
  formatQuota,
  taskFilterOf,
  type Tab,
  type BrowseTarget,
  type TaskFilter,
} from './format';

export type P115PanelState = ReturnType<typeof useP115Panel>;

/** 任务列表最多合并 5 页（500 条），避免异常数据导致无限翻页 */
const MAX_TASK_PAGES = 5;

/** 115 Cookie 失效/未登录：这些错误意味着「已配置但没登录」，应退回登录页 */
export function isP115AuthError(text: string): boolean {
  return /Cookie|未登录|登录已?失效|401|401401|登录态/i.test(text);
}

export function useP115Panel() {
  const { isAdmin } = useAuth();
  const cached = getP115PanelCache();
  const [tab, setTab] = useState<Tab>(() => cached?.tab ?? 'overview');
  const [configured, setConfigured] = useState(() => Boolean(cached?.configured));
  /** Cookie 有效与否：false 时不进入工作台，只显示登录入口 */
  const [checking, setChecking] = useState(false);
  const [authOk, setAuthOk] = useState(() => Boolean(cached?.authOk));
  const [authError, setAuthError] = useState(() => cached?.authError ?? '');
  const [hint, setHint] = useState(() => cached?.hint ?? '');
  const [cookie, setCookie] = useState('');
  const [showCookieEdit, setShowCookieEdit] = useState(() => !cached?.configured);
  const [targets, setTargets] = useState<Record<P115SaveSource, P115TargetFolder>>(
    () => cached?.targets ?? emptyTargets(),
  );
  const [browseSource, setBrowseSource] = useState<BrowseTarget>('search');
  const [quota, setQuota] = useState<number | null>(() => cached?.quota ?? null);
  const [quotaTotal, setQuotaTotal] = useState<number | null>(() => cached?.quotaTotal ?? null);
  const [quotaError, setQuotaError] = useState(() => cached?.quotaError ?? '');
  const [quotaLoading, setQuotaLoading] = useState(false);
  const [spaceUsedText, setSpaceUsedText] = useState(() => cached?.spaceUsedText ?? '');
  const [spaceTotalText, setSpaceTotalText] = useState(() => cached?.spaceTotalText ?? '');
  const [spaceUsed, setSpaceUsed] = useState<number | null>(() => cached?.spaceUsed ?? null);
  const [spaceTotal, setSpaceTotal] = useState<number | null>(() => cached?.spaceTotal ?? null);
  const [showBrowser, setShowBrowser] = useState(false);
  const [browsing, setBrowsing] = useState(false);
  const [folderPath, setFolderPath] = useState<P115FolderItem[]>([]);
  const [folders, setFolders] = useState<P115FolderItem[]>([]);
  const { msg, setMsg, busy, run } = usePanelAction();
  const [tasks, setTasks] = useState<P115Task[]>(() => cached?.tasks ?? []);
  const [tasksLoading, setTasksLoading] = useState(false);
  const [tasksError, setTasksError] = useState(() => cached?.tasksError ?? '');
  const [tasksLoaded, setTasksLoaded] = useState(() => Boolean(cached?.tasksLoaded));
  const [taskFilter, setTaskFilter] = useState<TaskFilter>('run');
  const [clearing, setClearing] = useState<P115ClearMode | null>(null);
  const [deletingHash, setDeletingHash] = useState<string | null>(null);
  const [qrOpen, setQrOpen] = useState(false);
  const [qrBusy, setQrBusy] = useState(false);
  const [qrSession, setQrSession] = useState<P115QrStart | null>(null);
  const [qrStatusLabel, setQrStatusLabel] = useState('');
  /** 扫码端（客户端类型）：与老后端 QR_APPS 一致，默认支付宝小程序 */
  const [qrApp, setQrApp] = useState('alipaymini');
  const [qrApps, setQrApps] = useState<P115QrApp[]>([
    { key: 'alipaymini', label: '115生活 · 支付宝小程序' },
    { key: 'wechatmini', label: '115生活 · 微信小程序' },
    { key: 'web', label: '网页版（Cookie）' },
  ]);
  const qrGenRef = useRef(0);
  /** 并发保护：只接受最后一次请求的响应，旧响应直接丢弃 */
  const statusSeq = useRef(0);
  const tasksSeq = useRef(0);
  /** 115 账号卡片：头像 / 用户名 / VIP（与 iOS App 一致） */
  const [account, setAccount] = useState<Pan115Account | null>(null);
  /** 解压配置与队列状态 */
  const [extractConfig, setExtractConfig] = useState<P115ExtractConfig>({
    folderCid: '0',
    folderName: '',
    password: '',
  });
  const [extractStatus, setExtractStatus] = useState<P115ExtractStatus | null>(null);
  /** 选定目录后预览到的待解压文件；null 表示还没扫过 */
  const [extractPreview, setExtractPreview] = useState<P115ExtractItem[] | null>(null);
  const [extractPreviewBusy, setExtractPreviewBusy] = useState(false);
  const [extractBusy, setExtractBusy] = useState(false);
  const [extractError, setExtractError] = useState('');
  /** 当前目录 CID 的即时值：轮询回调里用来判断扫描结果是否属于这个目录 */
  const extractCidRef = useRef(extractConfig.folderCid);
  useEffect(() => {
    extractCidRef.current = extractConfig.folderCid;
  }, [extractConfig.folderCid]);

  async function loadAccount() {
    try {
      setAccount(await getPan115Snapshot());
    } catch {
      // 保留已有账号信息，避免刷新抖动时卡片闪回默认占位
    }
  }

  function applyQuotaInfo(
    data: Partial<P115Config> & {
      quota?: number | null;
      quotaTotal?: number | null;
      quotaError?: string;
    },
  ) {
    const nextQuota = 'quota' in data || 'quotaTotal' in data ? data.quota ?? null : undefined;
    const nextQuotaTotal =
      'quota' in data || 'quotaTotal' in data ? data.quotaTotal ?? null : undefined;
    const nextQuotaError = data.quotaError
      ? data.quotaError
      : 'quota' in data
        ? ''
        : undefined;

    if (nextQuota !== undefined) setQuota(nextQuota);
    if (nextQuotaTotal !== undefined) setQuotaTotal(nextQuotaTotal);
    if (nextQuotaError !== undefined) setQuotaError(nextQuotaError);

    if (data.spaceUsedText != null) setSpaceUsedText(String(data.spaceUsedText || ''));
    if (data.spaceTotalText != null) setSpaceTotalText(String(data.spaceTotalText || ''));
    if ('spaceUsed' in data) setSpaceUsed(data.spaceUsed ?? null);
    if ('spaceTotal' in data) setSpaceTotal(data.spaceTotal ?? null);

    patchP115PanelCache({
      ...(nextQuota !== undefined ? { quota: nextQuota } : {}),
      ...(nextQuotaTotal !== undefined ? { quotaTotal: nextQuotaTotal } : {}),
      ...(nextQuotaError !== undefined ? { quotaError: nextQuotaError } : {}),
      ...(data.spaceUsedText != null
        ? { spaceUsedText: String(data.spaceUsedText || '') }
        : {}),
      ...(data.spaceTotalText != null
        ? { spaceTotalText: String(data.spaceTotalText || '') }
        : {}),
      ...('spaceUsed' in data ? { spaceUsed: data.spaceUsed ?? null } : {}),
      ...('spaceTotal' in data ? { spaceTotal: data.spaceTotal ?? null } : {}),
    });
  }

  function applyAuth(ok: boolean, error = '') {
    setAuthOk(ok);
    setAuthError(error);
    patchP115PanelCache({ authOk: ok, authError: error });
  }

  function applyConfig(data: P115Config, opts?: { forceOverview?: boolean }) {
    const nextConfigured = Boolean(data.configured);
    const nextHint = data.cookieHint || '';
    const nextTargets = normalizeTargets(data);
    setConfigured(nextConfigured);
    setHint(nextHint);
    setTargets(nextTargets);
    setCookie('');
    setShowCookieEdit(!nextConfigured);
    applyQuotaInfo(data);
    if (!nextConfigured) {
      applyAuth(false, '');
      setTab('overview');
      setTasks([]);
      setTasksLoaded(false);
      setTasksError('');
      setShowBrowser(false);
      setP115PanelCache({
        configured: false,
        authOk: false,
        authError: '',
        hint: nextHint,
        targets: nextTargets,
        tab: 'overview',
        quota: null,
        quotaTotal: null,
        quotaError: '',
        spaceUsedText: '',
        spaceTotalText: '',
        spaceUsed: null,
        spaceTotal: null,
        tasks: [],
        tasksLoaded: false,
        tasksError: '',
      });
      return;
    }
    if (opts?.forceOverview) setTab('overview');
    cacheFromP115Config(data, nextTargets, getP115PanelCache());
  }

  /** Cookie 无效 / 已失效：退回登录入口，不进入工作台 */
  function applyAuthFailed(error: string) {
    applyAuth(false, error || 'Cookie 无效或已过期');
    setConfigured(false);
    setTab('overview');
    setTasks([]);
    setTasksLoaded(false);
    setShowBrowser(false);
    // 缓存也要一起退回登录态，否则下次进面板会先显示旧的工作台
    patchP115PanelCache({
      configured: false,
      tab: 'overview',
      tasks: [],
      tasksLoaded: false,
      tasksError: '',
    });
  }

  /** 依据 /p115/status 的 authOk 判定登录态（configured 只代表存过 Cookie） */
  function applyStatusAuth(status: P115Config): boolean {
    if (status.authOk) {
      applyAuth(true);
      void loadAccount();
      return true;
    }
    applyAuthFailed(status.authError || 'Cookie 无效或已过期');
    return false;
  }

  async function refreshStatus(opts?: { quiet?: boolean }) {
    const seq = ++statusSeq.current;
    const quiet = Boolean(opts?.quiet) && (quota != null || spaceUsed != null);
    if (!quiet) {
      setQuotaLoading(true);
      setQuotaError('');
    }
    try {
      const status = await getP115Status();
      // 旧请求晚到时不覆盖新状态（保存后刷新与后台静默刷新会撞车）
      if (seq !== statusSeq.current) return;
      applyQuotaInfo(status);
      if (!status.configured) {
        applyAuth(false, '');
        return;
      }
      applyStatusAuth(status);
      // 账号卡（头像/用户名/VIP）来自独立快照接口，刷新状态时一并更新
      void loadAccount();
    } catch (e) {
      if (seq !== statusSeq.current) return;
      const err = e instanceof Error ? e.message : '状态读取失败';
      if (isP115AuthError(err)) {
        // Cookie 失效：退回登录入口，不进入工作台
        applyAuthFailed(err);
      } else if (!quiet) {
        setQuotaError(err);
      }
    } finally {
      if (!quiet && seq === statusSeq.current) setQuotaLoading(false);
    }
  }

  async function refreshTasks(opts?: { quiet?: boolean }) {
    if (!configured && !opts?.quiet) return;
    const seq = ++tasksSeq.current;
    if (!opts?.quiet) {
      setTasksLoading(true);
      setTasksError('');
    }
    try {
      const first = await listP115Tasks(1);
      // 任务列表可能有多页，只取第一页会漏掉较早的离线任务
      const pages = Math.min(first.pageCount ?? 1, MAX_TASK_PAGES);
      const rest =
        pages > 1
          ? await Promise.all(
              Array.from({ length: pages - 1 }, (_, i) => listP115Tasks(i + 2)),
            )
          : [];
      if (seq !== tasksSeq.current) return;
      const nextTasks = [first, ...rest].flatMap((page) => page.tasks || []);
      setTasks(nextTasks);
      setTasksLoaded(true);
      setTasksError('');
      patchP115PanelCache({
        tasks: nextTasks,
        tasksLoaded: true,
        tasksError: '',
      });
      if (first.quota != null || first.quotaTotal != null) {
        applyQuotaInfo({
          quota: first.quota,
          quotaTotal: first.quotaTotal,
        });
      }
    } catch (e) {
      if (seq !== tasksSeq.current) return;
      const err = e instanceof Error ? e.message : '获取任务失败';
      setTasksError(err);
      setTasksLoaded(true);
      patchP115PanelCache({ tasksLoaded: true, tasksError: err });
    } finally {
      if (!opts?.quiet && seq === tasksSeq.current) setTasksLoading(false);
    }
  }

  useEffect(() => {
    let cancelled = false;
    const fresh = isP115PanelCacheFresh();
    if (!cached || (cached.configured && !cached.authOk)) setChecking(true);

    void (async () => {
      try {
        // 有新鲜且已登录的缓存：直接展示，后台静默刷配额
        if (fresh && cached?.configured && cached.authOk) {
          // 账号卡走独立快照接口，缓存命中时必须补拉，否则头像/昵称停留在占位
          void loadAccount();
          void refreshStatus({ quiet: true });
          setChecking(false);
          return;
        }
        const data = await getP115();
        if (cancelled) return;
        applyConfig(data, { forceOverview: !cached?.configured && data.configured });
        if (data.configured) {
          // 无配额缓存时才显示「读取中」
          const needSpin = getP115PanelCache()?.quota == null;
          if (needSpin) setQuotaLoading(true);
          try {
            const status = await getP115Status();
            if (cancelled) return;
            applyQuotaInfo(status);
            if (!status.configured) {
              applyAuth(false, '');
            } else {
              applyStatusAuth(status);
              // 账号卡走独立快照接口，冷启动同样要拉一次
              void loadAccount();
            }
          } catch (e) {
            if (cancelled) return;
            const err = e instanceof Error ? e.message : '状态读取失败';
            if (isP115AuthError(err)) {
              // Cookie 失效/过期：只显示登录入口，不进入工作台
              applyAuthFailed(err);
            } else {
              setQuotaError(err);
            }
          } finally {
            if (!cancelled) setQuotaLoading(false);
          }
        } else {
          setQuotaLoading(false);
        }
      } catch (e) {
        if (cancelled) return;
        setMsg(e instanceof Error ? e.message : '读取失败');
      } finally {
        if (!cancelled) setChecking(false);
      }
    })();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    patchP115PanelCache({ tab });
  }, [tab]);

  useEffect(() => {
    if (tab !== 'tasks' || !configured) return;
    if (!tasksLoaded) void refreshTasks();
    // 离线任务进度只能靠轮询推进，停留在任务页时保持刷新
    const timer = window.setInterval(() => void refreshTasks({ quiet: true }), 5000);
    return () => window.clearInterval(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tab, configured, tasksLoaded]);

  useEffect(() => {
    return () => {
      // 勿在卸载时用闭包 state 回写缓存：会覆盖掉 applyConfig/applyQuotaInfo
      // 已写入的正确快照（第二次进入就会空白）。
      qrGenRef.current += 1;
    };
  }, []);

  async function startQrLogin(client?: string) {
    const gen = ++qrGenRef.current;
    const app = client || qrApp;
    setQrApp(app);
    setQrBusy(true);
    setQrOpen(true);
    setQrStatusLabel('生成二维码…');
    setQrSession(null);
    setMsg('');
    try {
      let session = await startP115Qrcode(app);
      if (gen !== qrGenRef.current) return;
      setQrSession(session);
      if (session.apps?.length) setQrApps(session.apps);
      setQrStatusLabel('请用 115 App 扫码');
      setShowCookieEdit(true);
      // 二维码已就绪，后续轮询不再阻塞交互（否则客户端下拉框一直是 disabled）
      setQrBusy(false);

      let failures = 0;
      let expiredCount = 0;
      for (;;) {
        if (gen !== qrGenRef.current) return;
        await new Promise((r) => window.setTimeout(r, 1400));
        if (gen !== qrGenRef.current) return;
        let st: Awaited<ReturnType<typeof pollP115Qrcode>>;
        try {
          st = await pollP115Qrcode({
            uid: session.uid,
            time: session.time,
            sign: session.sign,
          });
          failures = 0;
        } catch (e) {
          // 单次网络抖动不该让整个扫码流程停摆，连续失败才放弃
          if (++failures >= 3) throw e;
          continue;
        }
        if (gen !== qrGenRef.current) return;
        setQrStatusLabel(st.statusLabel || '');
        if (st.expired) {
          expiredCount += 1;
          if (expiredCount > 2) {
            setMsg(st.statusLabel || '二维码已失效，请重新扫码');
            break;
          }
          // 二维码过期自动换一张，不用用户重开弹窗
          setQrStatusLabel('二维码已过期，正在刷新…');
          session = await startP115Qrcode(session.app || app);
          if (gen !== qrGenRef.current) return;
          setQrSession(session);
          if (session.apps?.length) setQrApps(session.apps);
          continue;
        }
        if (st.done) {
          setQrStatusLabel('正在获取 Cookie…');
          const done = await completeP115Qrcode({
            uid: session.uid,
            app: session.app || qrApp,
            save: true,
          });
          if (gen !== qrGenRef.current) return;
          applyConfig(done);
          setShowCookieEdit(false);
          setCookie('');
          setQrOpen(false);
          setQrSession(null);
          setMsg(done.message || '扫码登录成功');
          // 以 /p115/status 的实时校验为准，校验通过才进入工作台
          await refreshStatus({ quiet: true });
          if (getP115PanelCache()?.authOk) setTab('overview');
          break;
        }
      }
    } catch (e) {
      if (gen === qrGenRef.current) {
        setMsg(e instanceof Error ? e.message : '扫码登录失败');
        setQrStatusLabel('扫码失败');
      }
    } finally {
      if (gen === qrGenRef.current) setQrBusy(false);
    }
  }

  function cancelQrLogin() {
    qrGenRef.current += 1;
    setQrBusy(false);
    setQrOpen(false);
    setQrSession(null);
    setQrStatusLabel('');
  }

  async function browseFolders(source: BrowseTarget, cid = '0') {
    setBrowseSource(source);
    setBrowsing(true);
    setMsg('');
    try {
      const data = await listP115Folders({
        cid,
        cookie: cookie.trim() || undefined,
      });
      setFolderPath(data.path || []);
      setFolders(data.folders || []);
      setShowBrowser(true);
    } catch (e) {
      setMsg(e instanceof Error ? e.message : '获取目录失败');
    } finally {
      setBrowsing(false);
    }
  }

  function selectFolder(item: P115FolderItem) {
    if (browseSource === 'extract') {
      const patch = { folderCid: item.cid, folderName: item.name };
      setShowBrowser(false);
      // 换了目录，旧目录的扫描结果作废，等用户手动「扫描」
      setExtractPreview(null);
      setMsg(`已选择「${item.name || '根目录'}」作为解压目录`);
      // 选完立即落库；失败时由 onSaveExtract 保留旧配置并提示
      void onSaveExtract(patch);
      return;
    }
    const nextTargets = {
      ...targets,
      [browseSource]: {
        folderCid: item.cid,
        folderName: item.name,
      },
    };
    setShowBrowser(false);
    // 选完立即落库，等服务端确认后由 applyConfig 更新本地状态（失败则保持旧值）
    void onSave({ targets: nextTargets, cookie: undefined });
  }

  async function onTest() {
    await run('验证失败', async () => {
      const search = targets.search;
      const r = await validateP115({
        cookie: cookie.trim() || undefined,
        folderCid: search.folderCid,
      });
      if (r.folderName) {
        setTargets((prev) => ({
          ...prev,
          search: {
            ...prev.search,
            folderName: String(r.folderName),
          },
        }));
      }
      applyQuotaInfo(r);
      const q = formatQuota(r.quota, r.quotaTotal);
      setMsg(
        [r.message || (r.ok ? '验证成功' : '验证失败'), q ? `云转存 ${q}` : '']
          .filter(Boolean)
          .join(' · '),
      );
      if (r.ok) {
        // 目录可读 + 离线签名就绪：视为已登录
        setConfigured(true);
        applyAuth(true);
        patchP115PanelCache({ configured: true });
        void loadAccount();
      }
    });
  }

  async function onSave(
    patch?: { cookie?: string; targets?: Record<P115SaveSource, P115TargetFolder> },
  ) {
    await run('保存失败', async () => {
      const hasCookie = patch ? 'cookie' in patch : false;
      const next = await putP115({
        cookie: hasCookie ? patch?.cookie : cookie.trim() || undefined,
        targets: patch?.targets ?? targets,
        validate: true,
      });
      applyConfig(next);
      // 以服务端实时校验结果为准：保存成功但 Cookie 失效时不进工作台
      await refreshStatus({ quiet: true });
      setShowCookieEdit(false);
      const q = formatQuota(next.quota, next.quotaTotal);
      setMsg(
        [next.message || '已保存', q ? `云转存 ${q}` : ''].filter(Boolean).join(' · '),
      );
      if (getP115PanelCache()?.authOk) setTab('overview');
      void loadAccount();
    });
  }

  async function onClear(mode: P115ClearMode) {
    const labels: Record<P115ClearMode, string> = {
      done: '已完成',
      failed: '已失败',
      all: '全部',
    };
    if (mode === 'all' && !window.confirm('确定清理全部离线任务？（不会删除网盘内文件）')) {
      return;
    }
    setClearing(mode);
    setMsg('');
    try {
      const data = await clearP115Tasks(mode);
      if (data.tasks) {
        setTasks(data.tasks);
        patchP115PanelCache({
          tasks: data.tasks,
          tasksLoaded: true,
          tasksError: '',
        });
      } else await refreshTasks({ quiet: true });
      if (data.quota != null || data.quotaTotal != null) {
        applyQuotaInfo({
          quota: data.quota,
          quotaTotal: data.quotaTotal,
        });
      }
      setMsg(data.message || `已清理${labels[mode]}任务`);
      setTasksError('');
      setTasksLoaded(true);
    } catch (e) {
      setMsg(e instanceof Error ? e.message : '清理失败');
    } finally {
      setClearing(null);
    }
  }

  async function onDeleteTask(task: P115Task) {
    const hash = String(task.infoHash || '').trim();
    if (!hash) {
      setMsg('该任务缺少 infoHash，无法删除');
      return;
    }
    if (!window.confirm('确定删除这条云下载任务？（不会删除网盘内文件）')) {
      return;
    }
    setDeletingHash(hash);
    setMsg('');
    try {
      const data = await deleteP115Task(hash);
      if (data.tasks) {
        setTasks(data.tasks);
        patchP115PanelCache({
          tasks: data.tasks,
          tasksLoaded: true,
          tasksError: '',
        });
      } else {
        setTasks((prev) => prev.filter((t) => String(t.infoHash || '') !== hash));
        await refreshTasks({ quiet: true });
      }
      if (data.quota != null || data.quotaTotal != null) {
        applyQuotaInfo({
          quota: data.quota,
          quotaTotal: data.quotaTotal,
        });
      }
      setMsg(data.message || '已删除任务');
      setTasksError('');
      setTasksLoaded(true);
    } catch (e) {
      setMsg(e instanceof Error ? e.message : '删除失败');
    } finally {
      setDeletingHash(null);
    }
  }

  /** 扫描指定目录下的压缩包：先看清单，点「开始解压」才真正执行 */
  async function refreshExtractPreview(cid?: string) {
    setExtractPreviewBusy(true);
    setExtractError('');
    try {
      const pv = await getP115ExtractPreview(cid);
      setExtractPreview(pv.items);
      // 扫描即新建一批任务：立刻拉一次状态，旧批次记录直接消失
      setExtractStatus(await getP115ExtractStatus());
    } catch (e) {
      setExtractError(e instanceof Error ? e.message : '扫描目录失败');
    } finally {
      setExtractPreviewBusy(false);
    }
  }

  useEffect(() => {
    if (tab !== 'extract' || !configured || !authOk) return;
    let cancelled = false;
    /** 上一轮请求未返回时跳过，避免慢响应下定时器越叠越多 */
    let ticking = false;
    // 配置只在进入页签时读一次，避免轮询覆盖正在编辑的密码
    void (async () => {
      try {
        const cfg = await getP115ExtractConfig();
        if (!cancelled) {
          setExtractConfig(cfg);
          setExtractError('');
        }
      } catch (e) {
        if (!cancelled) {
          setExtractError(e instanceof Error ? e.message : '读取解压配置失败');
        }
      }
    })();

    const tick = async () => {
      if (ticking) return;
      ticking = true;
      try {
        const st = await getP115ExtractStatus();
        if (cancelled) return;
        setExtractStatus(st);
        // 扫描清单由后端持久化：刷新页面后按目录 CID 恢复
        if (st.preview && st.previewCid && st.previewCid === extractCidRef.current) {
          setExtractPreview(st.preview);
        }
        setExtractError('');
      } catch (e) {
        if (!cancelled) {
          setExtractError(e instanceof Error ? e.message : '读取解压状态失败');
        }
      } finally {
        ticking = false;
      }
    };
    void tick();
    const timer = window.setInterval(() => {
      void tick();
    }, 2000);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [tab, configured, authOk]);

  async function onSaveExtract(patch?: Partial<P115ExtractConfig>) {
    setExtractBusy(true);
    setExtractError('');
    try {
      const next = await putP115ExtractConfig({ ...extractConfig, ...patch });
      setExtractConfig(next);
      setMsg('解压配置已保存');
      // 仅目录变化时作废旧扫描结果；只改密码不影响清单
      if (next.folderCid !== extractConfig.folderCid) setExtractPreview(null);
    } catch (e) {
      const err = e instanceof Error ? e.message : '保存解压配置失败';
      setExtractError(err);
      setMsg(err);
    } finally {
      setExtractBusy(false);
    }
  }

  async function onStartExtract() {
    setExtractBusy(true);
    setExtractError('');
    try {
      const cfg = await putP115ExtractConfig(extractConfig);
      setExtractConfig(cfg);
      const st = await startP115Extract();
      setExtractStatus(st);
      setMsg(st.running ? '解压任务已启动，完成一个后自动处理下一个' : '没有可解压的压缩包');
    } catch (e) {
      const err = e instanceof Error ? e.message : '启动解压失败';
      setExtractError(err);
      setMsg(err);
    } finally {
      setExtractBusy(false);
    }
  }

  async function onStopExtract() {
    setExtractBusy(true);
    setExtractError('');
    try {
      const st = await stopP115Extract();
      setExtractStatus(st);
      setMsg('解压任务已停止');
    } catch (e) {
      const err = e instanceof Error ? e.message : '停止解压失败';
      setExtractError(err);
      setMsg(err);
    } finally {
      setExtractBusy(false);
    }
  }

  const locked = busy || browsing || clearing != null || deletingHash != null;
  // 登录/转存目录/解压等配置接口仅管理员可写，普通用户只读
  const settingsLocked = locked || !isAdmin;
  const taskCounts = {
    run: 0,
    failed: 0,
    done: 0,
  };
  for (const t of tasks) {
    taskCounts[taskFilterOf(t.status)] += 1;
  }
  const filteredTasks = tasks.filter((t) => taskFilterOf(t.status) === taskFilter);
  const quotaRatio =
    quota != null && quotaTotal != null && quotaTotal > 0
      ? Math.max(0, Math.min(1, quota / quotaTotal))
      : null;
  /** 云转存已用任务数（接口给的是剩余额度） */
  const quotaUsed = quota != null && quotaTotal != null ? Math.max(0, quotaTotal - quota) : null;
  /** 云转存占用比例：越满越红 */
  const quotaUsedRatio = quotaRatio == null ? null : 1 - quotaRatio;
  const spaceRatio =
    spaceUsed != null && spaceTotal != null && spaceTotal > 0
      ? Math.max(0, Math.min(1, spaceUsed / spaceTotal))
      : null;

  return {
    tab,
    setTab,
    configured: Boolean(configured && authOk),
    authOk,
    authError,
    authChecking: checking || (configured && !authOk && !authError),
    hint,
    account,
    cookie,
    setCookie,
    showCookieEdit,
    setShowCookieEdit,
    targets,
    browseSource,
    quota,
    quotaTotal,
    quotaError,
    quotaLoading,
    spaceUsedText,
    spaceTotalText,
    spaceUsed,
    spaceTotal,
    showBrowser,
    setShowBrowser,
    browsing,
    folderPath,
    folders,
    msg,
    setMsg,
    busy,
    tasks,
    tasksLoading,
    tasksError,
    tasksLoaded,
    taskFilter,
    setTaskFilter,
    clearing,
    deletingHash,
    qrOpen,
    qrBusy,
    qrSession,
    qrStatusLabel,
    qrApp,
    qrApps,
    refreshStatus,
    refreshTasks,
    startQrLogin,
    cancelQrLogin,
    browseFolders,
    selectFolder,
    extractConfig,
    setExtractConfig,
    extractStatus,
    extractPreview,
    extractPreviewBusy,
    refreshExtractPreview,
    extractBusy,
    extractError,
    onSaveExtract,
    onStartExtract,
    onStopExtract,
    onTest,
    onSave,
    onClear,
    onDeleteTask,
    locked,
    settingsLocked,
    taskCounts,
    filteredTasks,
    quotaRatio,
    quotaUsed,
    quotaUsedRatio,
    spaceRatio,
  };
}
