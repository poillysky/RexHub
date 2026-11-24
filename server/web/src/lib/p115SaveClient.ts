import { apiFetch, type P115SaveSource } from "@/lib/api";
import { linkKindOf } from "@/lib/detailResource";
import { resolveP115SaveSource } from "@/lib/p115Source";

/** 单次请求的链接上限：与后端 Pydantic max_length 对齐。
 *  超出的部分由本模块自动分批串行提交，调用方无需关心。 */
export const SHARE_CHUNK_SIZE = 20;
export const OFFLINE_CHUNK_SIZE = 50;

export type P115SaveProgress = {
  /** 已提交完成的批次数（含失败批） */
  done: number;
  /** 总批次数 */
  total: number;
  /** 当前阶段 */
  phase: "share" | "offline";
};

export type P115SaveResult = {
  ok: boolean;
  message: string;
  needConfig?: boolean;
  needLogin?: boolean;
  renameScheduled?: boolean;
  shareCount?: number;
  offlineCount?: number;
  /** 本次实际拆成的批次数（>1 时 UI 可提示「分 M 批」） */
  batches?: number;
  /** 失败明细（跨批次聚合） */
  failed?: { url?: string; message?: string }[];
  destName?: string;
  destCid?: string;
  source?: P115SaveSource;
};

type Envelope = {
  status?: number;
  data?: {
    ok?: boolean;
    message?: string;
    renameScheduled?: boolean;
    added?: number;
    failed?: { url?: string; message?: string }[];
    destName?: string;
    destCid?: string;
  } | null;
  message?: string;
  detail?: string | { msg?: string; message?: string }[];
};

function envelopeMessage(json: Envelope, fallback: string): string {
  if (typeof json.detail === "string" && json.detail.trim()) {
    return json.detail.trim();
  }
  if (Array.isArray(json.detail) && json.detail[0]) {
    const first = json.detail[0];
    const m = first.msg || first.message;
    if (m) return String(m);
  }
  const dataMsg = json.data?.message?.trim();
  if (dataMsg) return dataMsg;
  const failedMsg = json.data?.failed?.[0]?.message?.trim();
  if (failedMsg) return failedMsg;
  if (json.message?.trim()) return json.message.trim();
  return fallback;
}

/** 把 pydantic 的英文校验原文换成可操作的中文提示 */
function localizeValidation(raw: string): string {
  const tooLong = raw.match(/at most (\d+) items?/i);
  if (tooLong) {
    return `单批链接过多（上限 ${tooLong[1]} 条），已自动分批提交，请重试`;
  }
  if (/at least 1 item/i.test(raw)) {
    return "没有可转存的链接";
  }
  if (/field required/i.test(raw)) {
    return "请求缺少必填字段，请刷新页面后重试";
  }
  return raw;
}

function classifyFail(msg: string): P115SaveResult {
  const text = localizeValidation(msg);
  if (/登录|鉴权|401|未登录/i.test(text) && !/Cookie|115/i.test(text)) {
    return { ok: false, message: "请先登录后再转存", needLogin: true };
  }
  if (/尚未配置|缺少 UID|缺少 CID|缺少 SEID|Cookie 无效|Cookie 可能过期|重新粘贴|重新登录 115/i.test(text)) {
    return {
      ok: false,
      message: /尚未配置/.test(text)
        ? "尚未配置 115，请先到更多填写 Cookie"
        : text,
      needConfig: true,
    };
  }
  if (/验证码|911/i.test(text)) {
    return {
      ok: false,
      message: "需要验证码：请先在 115 网页打开「云下载」完成验证后再点转存",
    };
  }
  if (/配额|10009/i.test(text)) {
    return {
      ok: false,
      message: "离线任务配额已满，请到 115 清理云下载任务后再试",
    };
  }
  if (/空间不足|10007/i.test(text)) {
    return { ok: false, message: "115 空间不足，请清理后再转存" };
  }
  return { ok: false, message: text || "转存 115 失败" };
}

/** 致命错误：不值得继续提交后续批次 */
function isFatal(result: P115SaveResult): boolean {
  return Boolean(result.needConfig || result.needLogin);
}

function chunk<T>(items: T[], size: number): T[][] {
  if (!items.length) return [];
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) {
    out.push(items.slice(i, i + size));
  }
  return out;
}

type BatchOutcome = {
  ok: boolean;
  message: string;
  data?: Envelope["data"];
  /** 该批的致命错误（配置/登录），需要中断后续批次 */
  fatal?: P115SaveResult;
  failed: { url?: string; message?: string }[];
};

async function postBatch(
  path: string,
  payload: Record<string, unknown>,
): Promise<BatchOutcome> {
  const res = await apiFetch(path, {
    method: "POST",
    body: JSON.stringify(payload),
  });
  const json = (await res.json().catch(() => ({}))) as Envelope;
  const failed = Array.isArray(json.data?.failed) ? json.data!.failed! : [];

  if (!res.ok) {
    const raw = envelopeMessage(
      json,
      res.status >= 500
        ? "转存服务异常，请稍后重试或检查 115 Cookie"
        : `转存失败（${res.status}）`,
    );
    const classified = classifyFail(raw);
    return {
      ok: false,
      message: classified.message,
      fatal: isFatal(classified) ? classified : undefined,
      failed,
    };
  }

  return {
    ok: true,
    message: envelopeMessage(json, ""),
    data: json.data,
    failed,
  };
}

/** 分享 → /pan/share；磁力/ED2K → /pan/offline（有密码时完成后标注压缩包名）
 *
 *  链接数超过单批上限时自动分批串行提交，结果跨批次聚合：
 *  - 分享批 20 条/批，离线批 50 条/批
 *  - 任一批次出现「未配置 / 未登录」立即中断，避免把 50 条白刷 10 遍
 *  - 只要有一批成功即返回 ok，失败明细完整保留 */
export async function runP115Save(opts: {
  urls: string[];
  password?: string | null;
  titleHint?: string;
  /** 入口：仓库 / 影视 / 分区 → 对应保存目录 */
  source?: P115SaveSource;
  /** 分批进度回调（多批时 UI 可显示「第 N/M 批」） */
  onProgress?: (p: P115SaveProgress) => void;
}): Promise<P115SaveResult> {
  const urls = Array.from(
    new Set((opts.urls || []).map((u) => u.trim()).filter(Boolean)),
  );
  const password = (opts.password || "").trim();
  const source = resolveP115SaveSource(opts.source);
  if (!urls.length) {
    return { ok: false, message: "没有可转存的磁力 / ED2K / 115 分享链接" };
  }

  const shareUrls = urls.filter((u) => linkKindOf(u) === "115share");
  // 离线只收磁力 / ED2K；普通网页链接与 stub 不应进入云下载队列
  const offlineUrls = urls.filter((u) => {
    const kind = linkKindOf(u);
    return kind === "magnet" || kind === "ed2k";
  });

  if (!shareUrls.length && !offlineUrls.length) {
    return { ok: false, message: "仅支持磁力 / ED2K / 115 分享链接" };
  }

  const shareBatches = chunk(shareUrls, SHARE_CHUNK_SIZE);
  const offlineBatches = chunk(offlineUrls, OFFLINE_CHUNK_SIZE);
  const total = shareBatches.length + offlineBatches.length;
  let done = 0;
  const report = (phase: "share" | "offline") =>
    opts.onProgress?.({ done, total, phase });

  let shareReceived = 0;
  let offlineAdded = 0;
  let renameScheduled = false;
  let destName: string | undefined;
  let destCid: string | undefined;
  const failedRows: { url?: string; message?: string }[] = [];
  const batchMessages: string[] = [];
  let fatal: P115SaveResult | undefined;

  try {
    // —— 115 分享：逐批转存 ——
    for (let i = 0; i < shareBatches.length; i += 1) {
      report("share");
      const outcome = await postBatch("/pan/share", {
        urls: shareBatches[i],
        password: password || undefined,
        source,
      });
      done += 1;
      if (outcome.fatal) {
        fatal = outcome.fatal;
        break;
      }
      if (outcome.ok) {
        shareReceived += shareBatches[i].length - outcome.failed.length;
        if (outcome.data?.destName) destName = String(outcome.data.destName);
        if (outcome.data?.destCid) destCid = String(outcome.data.destCid);
        if (outcome.message) batchMessages.push(outcome.message);
      } else {
        batchMessages.push(outcome.message);
      }
      failedRows.push(...outcome.failed);
    }

    // —— 磁力 / ED2K：逐批提交云下载 ——
    if (!fatal) {
      for (let i = 0; i < offlineBatches.length; i += 1) {
        report("offline");
        const outcome = await postBatch("/pan/offline", {
          urls: offlineBatches[i],
          password: password || undefined,
          // 命名提示只给第一批，避免重复标注同一标题
          titleHint: i === 0 ? opts.titleHint || undefined : undefined,
          source,
        });
        done += 1;
        if (outcome.fatal) {
          fatal = outcome.fatal;
          break;
        }
        if (outcome.ok) {
          offlineAdded += offlineBatches[i].length - outcome.failed.length;
          if (outcome.data?.renameScheduled) renameScheduled = true;
          if (outcome.data?.destName) destName = String(outcome.data.destName);
          if (outcome.data?.destCid) destCid = String(outcome.data.destCid);
          if (outcome.message) batchMessages.push(outcome.message);
        } else {
          batchMessages.push(outcome.message);
        }
        failedRows.push(...outcome.failed);
      }
    }
  } catch (err) {
    const raw = err instanceof Error ? err.message : String(err || "");
    const msg = /failed to fetch|network|load failed/i.test(raw)
      ? "网络异常，请检查 API 是否可用后再试"
      : raw || "转存 115 失败";
    // 已有部分成功时不要整体报失败，避免用户重复点转存
    if (!shareReceived && !offlineAdded) {
      return { ok: false, message: msg, batches: total };
    }
    batchMessages.push(msg);
  }

  const anyOk = shareReceived > 0 || offlineAdded > 0;
  if (fatal && !anyOk) {
    return { ...fatal, batches: total };
  }

  const shareHint = shareReceived ? `115 分享 ${shareReceived} 个已转存` : "";
  const offlineHint = offlineAdded
    ? `已提交 ${offlineAdded} 条到 115 云下载`
    : "";
  const head = [shareHint, offlineHint].filter(Boolean).join("；");

  if (anyOk) {
    const parts = [head];
    if (renameScheduled) parts.push("完成后自动给压缩包标注密码");
    if (failedRows.length) parts.push(`失败 ${failedRows.length} 条`);
    if (fatal) parts.push(fatal.message);
    return {
      ok: true,
      renameScheduled,
      offlineCount: offlineAdded || undefined,
      shareCount: shareReceived || undefined,
      batches: total,
      failed: failedRows,
      destName,
      destCid,
      message: parts.filter(Boolean).join(" · "),
    };
  }

  // 全批失败：优先返回首个可操作错误
  const firstMsg =
    failedRows[0]?.message || batchMessages.find(Boolean) || "转存 115 失败";
  return { ...classifyFail(String(firstMsg)), batches: total, failed: failedRows };
}
