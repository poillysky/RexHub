/** 从粘贴文本中抽出可转存链接与密码 */

const LINK_RE =
  /(?:magnet:\?[^\s"'<>]+|ed2k:\/\/[^\s"'<>]+|https?:\/\/(?:www\.)?(?:115\.com|115cdn\.com)\/s\/[^\s"'<>]+)/gi;

/** 显式分隔符（冒号/等号）后的密码 */
const PASSWORD_RE =
  /(?:解压密码|压缩密码|访问码|分享码|提取码|密码|pwd|password)\s*[:：=]\s*([^\s，,;；。]{1,64})/i;

/** 「密码 1314」这类空格分隔；限定同一行，避免吞到下一行链接 */
const PASSWORD_SPACE_RE =
  /(?:解压密码|压缩密码|访问码|分享码|提取码|密码)[ \t]+([^\s，,;；。]{2,64})/i;

const INVALID_PASSWORD_VALUES = new Set([
  '无',
  '無',
  '空',
  'none',
  'null',
  'n/a',
  'na',
  '-',
  '—',
  '没有',
  '没有密码',
  '无密码',
  '無密碼',
  '未设置',
  '未設置',
  '暂无',
  '暫無',
  '未知',
]);

/**
 * 色花资源库 `resource_sources.extract_password` 频次前列（已去掉「無/没有密码」等无效项）。
 * 供粘贴转存页一键填入。
 */
export const COMMON_EXTRACT_PASSWORDS: readonly string[] = [
  '1998@www.98T.la',
  'www.98T.la@',
  '暴龙整理',
  '1314',
  '98tang',
  'www.98T.la',
  'sehuatang',
] as const;

function trimTrailingJunk(link: string) {
  return link.replace(/[)\]}>.,;，。；]+$/g, '').trim();
}

export function extractPasteLinks(text: string): string[] {
  const raw = text || '';
  const found: string[] = [];
  const push = (u: string) => {
    const link = trimTrailingJunk(u);
    if (!link || found.includes(link)) return;
    found.push(link);
  };

  for (const m of raw.matchAll(LINK_RE)) {
    push(m[0]);
  }

  return found;
}

function cleanPassword(raw: string | undefined): string | null {
  if (!raw) return null;
  const value = raw
    .trim()
    .replace(/^["'“”‘’(\[【]+/, '')
    .replace(/["'“”‘’)\]】]+$/, '')
    .trim();
  if (!value) return null;
  if (INVALID_PASSWORD_VALUES.has(value.toLowerCase())) return null;
  // 「密码错误请重试」之类提示语不是密码
  if (/^(?:错误|不正确|失败|无效|不正確|無效)/.test(value)) return null;
  return value;
}

export function extractPastePassword(text: string): string | null {
  const raw = text || '';
  const m = raw.match(PASSWORD_RE) || raw.match(PASSWORD_SPACE_RE);
  return cleanPassword(m?.[1]);
}
