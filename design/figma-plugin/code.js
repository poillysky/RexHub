// RexHub iOS 设计稿生成器 — Figma development plugin
//
// 定位：以代码为准。这里的所有数值都对齐
// ios/Packages/RexCore/Sources/DesignTokens.swift，改了令牌记得同步本文件。
// 生成结果的用途：评审界面结构、和模拟器截图逐帧比对、给外部看方案。
//
// 生成内容：五个 iPhone 画板（首页 / 影视 / 资源库 / 设置 / 详情）+ 颜色与文字样式。

const KIT = "RexHub iOS";
const BRAND = "#0066FF";

const PALETTE = {
  light: {
    bg: "#F2F5FA",
    surface: "#FFFFFF",
    elevated: "#F2F2F7",
    separator: "#D1D1D6",
    textPrimary: "#0E1116",
    textSecondary: "#55555A",
    textTertiary: "#6F6F74",
    brand: BRAND,
    onBrand: "#FFFFFF",
    danger: "#FF453A",
    success: "#30D158",
    selection: "#E1E7F0",
    field: "#F2F5FA",
    fieldBorder: "#E4E9F1",
    cardBorder: "#E1E7F0",
    divider: "#E5E7EB",
    sheet: "#F7F9FC",
    skeleton: "#E5E7EB",
    shadow: 0.1,
    wash: 0.09,
  },
  dark: {
    bg: "#000000",
    surface: "#1C1C1E",
    elevated: "#2C2C2E",
    separator: "#38383A",
    textPrimary: "#F2F2F7",
    textSecondary: "#B0B0B5",
    textTertiary: "#8E8E93",
    brand: "#4D8DFF",
    onBrand: "#FFFFFF",
    danger: "#FF453A",
    success: "#30D158",
    selection: "#262E3A",
    field: "#1C222B",
    fieldBorder: "#2C3542",
    cardBorder: "#2B3340",
    divider: "#2A3038",
    sheet: "#131820",
    skeleton: "#242A32",
    shadow: 0.45,
    wash: 0.12,
  },
};

// RexRadius
const R = {
  small: 8,
  control: 12,
  card: 12,
  button: 14,
  chip: 16,
  largeCard: 16,
  panel: 20,
  iconTile: 10,
};

// RexSpacing
const SPC = { xs: 4, s: 8, m: 12, l: 16, xl: 20, xxl: 24, section: 32 };

// RexMetrics
const M = {
  screenPadding: 16,
  rowHeight: 56,
  chipHeight: 32,
  ctaHeight: 50,
  fieldHeight: 54,
  minTap: 44,
  statusBar: 54,
  tabBar: 84,
};

// RexFont（语义字号，取 iOS 默认档位）
const TYPE = {
  display: { size: 34, weight: "bold", line: 41 },
  title: { size: 28, weight: "semibold", line: 34 },
  title3: { size: 22, weight: "semibold", line: 28 },
  headline: { size: 17, weight: "semibold", line: 22 },
  body: { size: 17, weight: "regular", line: 24 },
  callout: { size: 16, weight: "regular", line: 21 },
  subheadline: { size: 15, weight: "regular", line: 20 },
  caption: { size: 13, weight: "regular", line: 18 },
  section: { size: 13, weight: "semibold", line: 18 },
  micro: { size: 11, weight: "medium", line: 13 },
};

const SCREEN_W = 393;
const SCREEN_H = 852;
const CONTENT_W = SCREEN_W - M.screenPadding * 2;

let C = PALETTE.dark;
let FAMILY = "SF Pro Text";
let STYLE = { regular: "Regular", medium: "Medium", semibold: "Semibold", bold: "Bold" };

// ---------- 基础工具 ----------

function rgb(h) {
  const v = h.replace("#", "");
  return {
    r: parseInt(v.slice(0, 2), 16) / 255,
    g: parseInt(v.slice(2, 4), 16) / 255,
    b: parseInt(v.slice(4, 6), 16) / 255,
  };
}

function solid(h, opacity = 1) {
  const c = rgb(h);
  return { type: "SOLID", color: { r: c.r, g: c.g, b: c.b }, opacity };
}

function gradient(from, to) {
  const a = rgb(from);
  const b = rgb(to);
  return {
    type: "GRADIENT_LINEAR",
    gradientTransform: [
      [0, 1, 0],
      [1, 0, 0],
    ],
    gradientStops: [
      { position: 0, color: { r: a.r, g: a.g, b: a.b, a: 1 } },
      { position: 1, color: { r: b.r, g: b.g, b: b.b, a: 1 } },
    ],
  };
}

async function initFonts() {
  const all = await figma.listAvailableFontsAsync();
  const families = Array.from(new Set(all.map((f) => f.fontName.family)));
  const preferred = ["SF Pro Text", "SF Pro Display", "Inter", "Helvetica Neue", "Roboto"];
  FAMILY = preferred.find((f) => families.indexOf(f) >= 0) || families[0];

  const styles = all.filter((f) => f.fontName.family === FAMILY).map((f) => f.fontName.style);
  const pick = (candidates, keyword, fallbackIdx) => {
    const hit = candidates.find((c) => styles.indexOf(c) >= 0);
    if (hit) return hit;
    const loose = styles.find((s) => s.toLowerCase().indexOf(keyword) >= 0);
    return loose || styles[fallbackIdx] || styles[0];
  };

  STYLE = {
    regular: pick(["Regular", "Book"], "regular", 0),
    medium: pick(["Medium"], "medium", 0),
    semibold: pick(["Semibold", "Semi Bold", "Semibold Italic"], "semibold", 0),
    bold: pick(["Bold"], "bold", 0),
  };

  for (const key of Object.keys(STYLE)) {
    await figma.loadFontAsync({ family: FAMILY, style: STYLE[key] });
  }
}

function txt(chars, opts = {}) {
  const style = TYPE[opts.type || "body"] || TYPE.body;
  const t = figma.createText();
  t.fontName = { family: FAMILY, style: STYLE[opts.weight || style.weight] || STYLE.regular };
  t.characters = chars;
  t.fontSize = opts.size || style.size;
  t.lineHeight = { unit: "PIXELS", value: opts.line || style.line };
  t.fills = [solid(opts.color || C.textPrimary, opts.opacity == null ? 1 : opts.opacity)];
  t.textAutoResize = "HEIGHT";
  if (opts.width) t.resize(opts.width, t.height);
  if (opts.align) t.textAlignHorizontal = opts.align;
  t.name = opts.name || chars.slice(0, 18);
  return t;
}

function box(opts = {}) {
  const f = figma.createFrame();
  f.name = opts.name || "Frame";
  f.layoutMode = opts.dir || "VERTICAL";
  f.itemSpacing = opts.gap || 0;
  f.paddingTop = opts.pt || 0;
  f.paddingBottom = opts.pb || 0;
  f.paddingLeft = opts.pl || 0;
  f.paddingRight = opts.pr || 0;
  f.fills = opts.bg ? [solid(opts.bg)] : [];
  f.cornerRadius = opts.radius || 0;
  f.clipsContent = opts.clip !== false;

  const horizontal = opts.dir === "HORIZONTAL";
  const primaryFixed = horizontal ? opts.w != null : opts.h != null;
  const counterFixed = horizontal ? opts.h != null : opts.w != null;
  if (opts.w != null && opts.h != null) f.resize(opts.w, opts.h);
  else if (opts.w != null) f.resize(opts.w, 10);
  else if (opts.h != null) f.resize(10, opts.h);
  f.primaryAxisSizingMode = primaryFixed ? "FIXED" : "AUTO";
  f.counterAxisSizingMode = counterFixed ? "FIXED" : "AUTO";
  if (opts.align) f.counterAxisAlignItems = opts.align;
  if (opts.mainAlign) f.primaryAxisAlignItems = opts.mainAlign;
  return f;
}

function bar(w, h, opts = {}) {
  const r = figma.createRectangle();
  r.resize(w, h);
  r.fills = opts.fill === null ? [] : [solid(opts.fill || C.elevated, opts.opacity == null ? 1 : opts.opacity)];
  r.cornerRadius = opts.radius || 0;
  r.name = opts.name || "Rect";
  return r;
}

function spacer(size = 1, grow = false) {
  const f = figma.createFrame();
  f.name = "Spacer";
  f.fills = [];
  f.resize(grow ? 1 : size, grow ? 1 : size);
  if (grow) f.layoutGrow = 1;
  return f;
}

function cardShadow() {  return [
    {
      type: "DROP_SHADOW",
      color: { r: 0, g: 0, b: 0, a: C.shadow },
      offset: { x: 0, y: 8 },
      radius: 24,
      spread: 0,
      visible: true,
      blendMode: "NORMAL",
    },
  ];
}

// 登录页顶部品牌染色：对应 RexAuth.washOpacityLight / washOpacityDark。
function washGradient(endHex) {
  const brand = rgb(C.brand);
  const bg = rgb(endHex || C.bg);
  return {
    type: "GRADIENT_LINEAR",
    gradientTransform: [
      [0, 1, 0],
      [1, 0, 0],
    ],
    gradientStops: [
      { position: 0, color: { r: brand.r, g: brand.g, b: brand.b, a: C.wash } },
      { position: 0.34, color: { r: bg.r, g: bg.g, b: bg.b, a: 1 } },
      { position: 1, color: { r: bg.r, g: bg.g, b: bg.b, a: 1 } },
    ],
  };
}

// ---------- 组件 ----------

function statusBar() {
  const row = box({
    dir: "HORIZONTAL",
    w: SCREEN_W,
    h: M.statusBar,
    pl: 24,
    pr: 24,
    mainAlign: "SPACE_BETWEEN",
    align: "CENTER",
    name: "状态栏",
  });
  row.appendChild(txt("9:41", { type: "subheadline", weight: "semibold" }));
  const right = box({ dir: "HORIZONTAL", gap: 6, align: "CENTER", name: "指示" });
  right.appendChild(bar(18, 11, { radius: 3, fill: C.textPrimary, opacity: 0.85 }));
  right.appendChild(bar(25, 12, { radius: 4, fill: C.textPrimary, opacity: 0.85 }));
  row.appendChild(right);
  return row;
}

function navBar(title, trailing) {
  const row = box({
    dir: "HORIZONTAL",
    w: SCREEN_W,
    h: M.minTap,
    pl: M.screenPadding,
    pr: M.screenPadding,
    mainAlign: "SPACE_BETWEEN",
    align: "CENTER",
    name: "导航栏",
  });
  row.appendChild(txt(title, { type: "title3", weight: "bold" }));
  if (trailing === "add") {
    row.appendChild(bar(28, 28, { radius: R.small, fill: C.elevated }));
  } else if (trailing === "avatar") {
    row.appendChild(bar(30, 30, { radius: 15, fill: C.brand, opacity: 0.85 }));
  } else {
    row.appendChild(bar(1, 1, { fill: null }));
  }
  return row;
}

function tabBar(active) {
  const bar_ = box({
    dir: "HORIZONTAL",
    w: SCREEN_W,
    h: M.tabBar,
    pt: 10,
    pb: 22,
    bg: C.surface,
    mainAlign: "SPACE_BETWEEN",
    align: "CENTER",
    name: "标签栏",
  });
  bar_.strokes = [solid(C.separator, 0.6)];
  bar_.strokeWeight = 1;
  bar_.primaryAxisSizingMode = "FIXED";
  bar_.counterAxisSizingMode = "FIXED";

  const items = [
    ["首页", "home"],
    ["影视", "media"],
    ["资源库", "library"],
    ["设置", "settings"],
  ];
  items.forEach(([label, key]) => {
    const on = key === active;
    const item = box({
      dir: "VERTICAL",
      w: SCREEN_W / 4,
      h: 52,
      gap: 4,
      align: "CENTER",
      mainAlign: "CENTER",
      name: `标签-${label}`,
    });
    item.appendChild(tabIcon(key, on));
    item.appendChild(
      txt(label, {
        type: "micro",
        weight: on ? "semibold" : "regular",
        color: on ? C.brand : C.textSecondary,
      })
    );
    bar_.appendChild(item);
  });
  return bar_;
}

// Figma 插件用不了 SF Symbols，这里用几何形状表示四个入口。
function tabIcon(kind, on) {
  const color = on ? C.brand : C.textSecondary;
  const wrap = box({ w: 24, h: 24, align: "CENTER", mainAlign: "CENTER", name: "图标" });

  if (kind === "home") {
    wrap.appendChild(bar(16, 16, { radius: 5, fill: color, opacity: on ? 1 : 0.7 }));
  } else if (kind === "media") {
    wrap.appendChild(bar(18, 13, { radius: 4, fill: color, opacity: on ? 1 : 0.7 }));
  } else if (kind === "library") {
    const col = box({ dir: "VERTICAL", gap: 3, align: "CENTER", name: "叠层" });
    [14, 18, 11].forEach((w) => col.appendChild(bar(w, 3, { radius: 1.5, fill: color, opacity: on ? 1 : 0.7 })));
    wrap.appendChild(col);
  } else {
    const ring = bar(15, 15, { radius: 7.5, fill: null });
    ring.strokes = [solid(color, on ? 1 : 0.7)];
    ring.strokeWeight = 2;
    wrap.appendChild(ring);
  }
  return wrap;
}

function sectionHeader(title, action) {
  const row = box({
    dir: "HORIZONTAL",
    w: CONTENT_W,
    mainAlign: "SPACE_BETWEEN",
    align: "CENTER",
    name: "区块标题",
  });
  row.appendChild(txt(title, { type: "section", color: C.textSecondary }));
  if (action) row.appendChild(txt(action, { type: "caption", color: C.textTertiary }));
  return row;
}

function chip(label, on) {
  const c = box({
    dir: "HORIZONTAL",
    h: M.chipHeight,
    pl: 14,
    pr: 14,
    radius: R.chip,
    bg: on ? C.brand : C.elevated,
    mainAlign: "CENTER",
    align: "CENTER",
    name: `胶囊-${label}`,
  });
  c.primaryAxisSizingMode = "AUTO";
  c.counterAxisSizingMode = "FIXED";
  c.appendChild(
    txt(label, { type: "subheadline", weight: on ? "semibold" : "regular", color: on ? C.onBrand : C.textSecondary })
  );
  return c;
}

function primaryButton(label) {
  const b = box({
    dir: "HORIZONTAL",
    w: CONTENT_W,
    h: M.ctaHeight,
    radius: R.button,
    bg: C.brand,
    mainAlign: "CENTER",
    align: "CENTER",
    name: "主按钮",
  });
  b.primaryAxisSizingMode = "FIXED";
  b.counterAxisSizingMode = "FIXED";
  b.appendChild(txt(label, { type: "headline", color: C.onBrand }));
  return b;
}

function posterArt(w, ratio) {
  const h = Math.round(w * ratio);
  const art = figma.createFrame();
  art.name = "海报";
  art.resize(w, h);
  art.cornerRadius = R.card;
  art.clipsContent = true;
  art.fills = [gradient("#22304A", "#10151F")];
  return art;
}

function posterCard(w, title, meta, badge) {
  const card = box({ w, gap: SPC.s, name: `海报卡-${title}` });
  const art = posterArt(w, 1.5);
  if (badge) {
    const tag = box({
      dir: "HORIZONTAL",
      pl: 6,
      pr: 6,
      pt: 2,
      pb: 2,
      radius: R.small,
      bg: C.brand,
      mainAlign: "CENTER",
      align: "CENTER",
      name: "角标",
    });
    tag.primaryAxisSizingMode = "AUTO";
    tag.counterAxisSizingMode = "AUTO";
    tag.appendChild(txt(badge, { type: "micro", color: C.onBrand }));
    tag.x = 8;
    tag.y = 8;
    art.appendChild(tag);
  }
  card.appendChild(art);
  card.appendChild(txt(title, { type: "caption", weight: "medium", width: w }));
  card.appendChild(txt(meta, { type: "micro", color: C.textTertiary, width: w }));
  return card;
}

function iconTile(glyph, tinted) {
  const t = box({
    w: 40,
    h: 40,
    radius: R.iconTile,
    bg: tinted ? C.selection : C.elevated,
    align: "CENTER",
    mainAlign: "CENTER",
    name: "图标底",
  });
  t.primaryAxisSizingMode = "FIXED";
  t.counterAxisSizingMode = "FIXED";
  t.appendChild(txt(glyph, { type: "subheadline", weight: "semibold", color: C.brand }));
  return t;
}

function settingRow(glyph, title, detail) {
  const row = box({
    dir: "HORIZONTAL",
    w: CONTENT_W,
    h: M.rowHeight,
    gap: SPC.m,
    pl: SPC.m,
    pr: SPC.m,
    bg: C.surface,
    align: "CENTER",
    name: `行-${title}`,
  });
  row.primaryAxisSizingMode = "FIXED";
  row.counterAxisSizingMode = "AUTO";
  row.appendChild(iconTile(glyph, false));

  const col = box({ dir: "VERTICAL", gap: 2, name: "文本" });
  col.appendChild(txt(title, { type: "body" }));
  if (detail) col.appendChild(txt(detail, { type: "micro", color: C.textTertiary }));
  row.appendChild(col);
  row.appendChild(spacer(1, true));
  row.appendChild(txt("›", { type: "body", color: C.textTertiary }));
  return row;
}

function groupContainer(name) {
  const g = box({ w: CONTENT_W, radius: R.card, bg: C.surface, clip: true, name });
  g.primaryAxisSizingMode = "AUTO";
  g.counterAxisSizingMode = "FIXED";
  g.strokes = [solid(C.cardBorder, 0.8)];
  g.strokeWeight = 1;
  return g;
}

function divider() {
  return bar(CONTENT_W, 1, { fill: C.divider, name: "分隔线" });
}

// 填充式输入框：高度 RexMetrics.fieldHeight，圆角 RexRadius.control，无描边（对齐 rexFilledField）。
function loginField(label, trailingGlyph) {
  const f = box({
    dir: "HORIZONTAL",
    w: CONTENT_W,
    h: M.fieldHeight,
    pl: SPC.l,
    pr: SPC.l,
    gap: SPC.s,
    radius: R.control,
    bg: C.field,
    align: "CENTER",
    name: `输入框-${label}`,
  });
  f.appendChild(txt(label, { type: "body", color: C.textTertiary }));
  f.appendChild(spacer(1, true));
  if (trailingGlyph) f.appendChild(txt(trailingGlyph, { type: "body", color: C.textTertiary }));
  return f;
}

/// 「记住密码」：左侧品牌蓝对勾 + 13pt 次要文字，点按切换，不是开关。
function checkRow(label, on) {
  const row = box({
    dir: "HORIZONTAL",
    w: CONTENT_W,
    h: M.minTap,
    gap: SPC.s,
    align: "CENTER",
    name: `勾选-${label}`,
  });
  row.primaryAxisSizingMode = "FIXED";
  row.counterAxisSizingMode = "FIXED";

  const dot = box({
    w: 18,
    h: 18,
    radius: 9,
    bg: on ? C.brand : null,
    align: "CENTER",
    mainAlign: "CENTER",
    name: "勾选圆",
  });
  dot.primaryAxisSizingMode = "FIXED";
  dot.counterAxisSizingMode = "FIXED";
  if (!on) {
    dot.strokes = [solid(C.textTertiary)];
    dot.strokeWeight = 1.5;
  } else {
    dot.appendChild(txt("✓", { size: 11, weight: "bold", color: C.onBrand }));
  }
  row.appendChild(dot);
  row.appendChild(txt(label, { type: "caption", color: C.textSecondary }));
  return row;
}

function switchRow(label, on) {
  const row = box({
    dir: "HORIZONTAL",
    w: CONTENT_W,
    h: M.minTap,
    align: "CENTER",
    mainAlign: "SPACE_BETWEEN",
    name: `开关-${label}`,
  });
  row.primaryAxisSizingMode = "FIXED";
  row.counterAxisSizingMode = "FIXED";
  row.appendChild(txt(label, { type: "caption", color: C.textSecondary }));

  const track = box({ w: 44, h: 26, radius: 13, bg: on ? C.brand : C.elevated, name: "开关" });
  track.primaryAxisSizingMode = "FIXED";
  track.counterAxisSizingMode = "FIXED";
  track.layoutMode = "NONE";
  const knob = bar(22, 22, { radius: 11, fill: on ? C.onBrand : C.textTertiary, name: "滑块" });
  knob.x = on ? 20 : 2;
  knob.y = 2;
  track.appendChild(knob);
  row.appendChild(track);
  return row;
}

// ---------- 画板 ----------

function phone(name) {
  const f = figma.createFrame();
  f.name = name;
  f.resize(SCREEN_W, SCREEN_H);
  f.layoutMode = "VERTICAL";
  f.itemSpacing = 0;
  f.fills = [solid(C.bg)];
  f.clipsContent = true;
  f.primaryAxisSizingMode = "FIXED";
  f.counterAxisSizingMode = "FIXED";
  return f;
}

function bodyColumn() {
  const c = box({ w: SCREEN_W, pt: SPC.s, pb: SPC.xl, pl: M.screenPadding, pr: M.screenPadding, gap: SPC.l, name: "内容" });
  c.primaryAxisSizingMode = "AUTO";
  c.counterAxisSizingMode = "FIXED";
  c.layoutGrow = 1;
  return c;
}

function buildHome() {
  const f = phone("首页");
  f.appendChild(statusBar());
  f.appendChild(navBar("RexHub", "avatar"));
  const body = bodyColumn();
  const searchField = box({
    dir: "HORIZONTAL",
    w: CONTENT_W,
    h: 64,
    pl: SPC.l,
    pr: SPC.l,
    gap: SPC.s,
    radius: R.button,
    bg: C.field,
    align: "CENTER",
    name: "搜索框",
  });
  searchField.strokes = [solid(C.fieldBorder)];
  searchField.strokeWeight = 1;
  searchField.appendChild(bar(16, 16, { radius: 8, fill: C.textTertiary, opacity: 0.6 }));
  searchField.appendChild(txt("搜索影片、演员、片单", { type: "body", color: C.textTertiary }));
  body.appendChild(searchField);

  const tiles = box({ w: CONTENT_W, gap: SPC.m, name: "功能宫格" });
  tiles.primaryAxisSizingMode = "AUTO";
  tiles.counterAxisSizingMode = "FIXED";
  [
    ["影", "影视"],
    ["库", "资源库"],
    ["剧", "短剧"],
    ["插", "插件"],
    ["史", "搜索历史"],
    ["设", "设置"],
  ].forEach(([glyph, label], i) => {
    if (i % 3 === 0) {
      const row = box({ dir: "HORIZONTAL", w: CONTENT_W, gap: SPC.m, name: "宫格行" });
      row.primaryAxisSizingMode = "AUTO";
      row.counterAxisSizingMode = "FIXED";
      tiles.appendChild(row);
    }
    const cell = box({
      dir: "VERTICAL",
      w: (CONTENT_W - SPC.m * 2) / 3,
      gap: SPC.s,
      align: "CENTER",
      mainAlign: "CENTER",
      name: `宫格-${label}`,
    });
    cell.appendChild(iconTile(glyph, i === 0));
    cell.appendChild(txt(label, { type: "micro", color: C.textSecondary }));
    tiles.children[tiles.children.length - 1].appendChild(cell);
  });
  body.appendChild(tiles);

  body.appendChild(sectionHeader("继续观看", "全部"));
  ["沙丘 2", "漫长的季节"].forEach((title) => {
    const row = box({
      dir: "HORIZONTAL",
      w: CONTENT_W,
      h: 64,
      gap: SPC.m,
      pl: SPC.s,
      pr: SPC.s,
      radius: R.card,
      bg: C.surface,
      align: "CENTER",
      name: `继续-${title}`,
    });
    row.primaryAxisSizingMode = "FIXED";
    row.counterAxisSizingMode = "AUTO";
    const art = posterArt(46, 1.4);
    row.appendChild(art);
    const col = box({ dir: "VERTICAL", gap: 4, name: "文本" });
    col.appendChild(txt(title, { type: "callout", weight: "medium" }));
    col.appendChild(txt("已看 42 分钟 · 进度 38%", { type: "micro", color: C.textTertiary }));
    row.appendChild(col);
    row.appendChild(spacer(1, true));
    row.appendChild(bar(24, 24, { radius: 12, fill: C.brand, opacity: 0.9 }));
    body.appendChild(row);
  });

  f.appendChild(body);
  f.appendChild(tabBar("home"));
  return f;
}

function buildMedia() {
  const f = phone("影视");
  f.appendChild(statusBar());
  f.appendChild(navBar("影视"));
  const body = bodyColumn();

  const seg = box({ dir: "HORIZONTAL", gap: SPC.s, name: "分段" });
  seg.primaryAxisSizingMode = "AUTO";
  seg.counterAxisSizingMode = "AUTO";
  ["推荐", "榜单", "片单"].forEach((t, i) => seg.appendChild(chip(t, i === 0)));
  body.appendChild(seg);

  body.appendChild(sectionHeader("热门", "换一批"));
  const grid = box({ w: CONTENT_W, gap: SPC.m, name: "海报网格" });
  grid.primaryAxisSizingMode = "AUTO";
  grid.counterAxisSizingMode = "FIXED";
  const cols = 3;
  const cardW = (CONTENT_W - SPC.m * (cols - 1)) / cols;
  const data = [
    ["沙丘 2", "2024 · 科幻", "4K"],
    ["奥本海默", "2023 · 传记", ""],
    ["繁花", "2023 · 剧集", ""],
    ["地球脉动", "2023 · 纪录", "HDR"],
    ["三体", "2024 · 剧集", ""],
    ["看不见的客人", "2017 · 悬疑", ""],
  ];
  data.forEach(([title, meta, badge], i) => {
    if (i % cols === 0) {
      const row = box({ dir: "HORIZONTAL", w: CONTENT_W, gap: SPC.m, name: "海报行" });
      row.primaryAxisSizingMode = "AUTO";
      row.counterAxisSizingMode = "FIXED";
      grid.appendChild(row);
    }
    grid.children[grid.children.length - 1].appendChild(posterCard(cardW, title, meta, badge));
  });
  body.appendChild(grid);

  body.appendChild(sectionHeader("高分片单", "全部"));
  const row2 = box({ dir: "HORIZONTAL", w: CONTENT_W, gap: SPC.m, name: "片单" });
  row2.primaryAxisSizingMode = "FIXED";
  row2.counterAxisSizingMode = "AUTO";
  [["影史经典", "32 部"], ["周末一口气", "18 部"], ["新片速递", "24 部"]].forEach(([t, n]) => {
    const c = box({ w: cardW, gap: SPC.xs, name: `片单-${t}` });
    c.appendChild(posterArt(cardW, 1.2));
    c.appendChild(txt(t, { type: "caption", weight: "medium", width: cardW }));
    c.appendChild(txt(n, { type: "micro", color: C.textTertiary }));
    row2.appendChild(c);
  });
  body.appendChild(row2);

  f.appendChild(body);
  f.appendChild(tabBar("media"));
  return f;
}

function buildLibrary() {
  const f = phone("资源库");
  f.appendChild(statusBar());
  f.appendChild(navBar("资源库", "add"));
  const body = bodyColumn();

  body.appendChild(sectionHeader("来源"));
  [
    ["115 网盘", "已绑定 · 剩余 3.2 TB", "85%"],
    ["Emby 服务器", "在线 · 1 个媒体库", "42%"],
  ].forEach(([title, meta, pct]) => {
    const card = box({ w: CONTENT_W, gap: SPC.m, pt: SPC.l, pb: SPC.l, pl: SPC.l, pr: SPC.l, radius: R.card, bg: C.surface, name: `来源-${title}` });
    card.primaryAxisSizingMode = "AUTO";
    card.counterAxisSizingMode = "FIXED";
    card.strokes = [solid(C.cardBorder, 0.8)];
    card.strokeWeight = 1;

    const top = box({ dir: "HORIZONTAL", w: CONTENT_W - SPC.l * 2, gap: SPC.m, align: "CENTER", name: "头部" });
    top.primaryAxisSizingMode = "FIXED";
    top.counterAxisSizingMode = "AUTO";
    top.appendChild(iconTile(title.charAt(0), true));
    const col = box({ dir: "VERTICAL", gap: 2, name: "文本" });
    col.appendChild(txt(title, { type: "callout", weight: "medium" }));
    col.appendChild(txt(meta, { type: "micro", color: C.textTertiary }));
    top.appendChild(col);
    top.appendChild(spacer(1, true));
    top.appendChild(txt("›", { type: "body", color: C.textTertiary }));
    card.appendChild(top);

    const track = box({ w: CONTENT_W - SPC.l * 2, h: 6, radius: 3, bg: C.elevated, name: "容量条", clip: true });
    track.primaryAxisSizingMode = "FIXED";
    track.counterAxisSizingMode = "FIXED";
    track.layoutMode = "NONE";
    const fill = bar(Math.round((CONTENT_W - SPC.l * 2) * (parseInt(pct) / 100)), 6, { radius: 3, fill: C.brand });
    fill.x = 0;
    fill.y = 0;
    track.appendChild(fill);
    card.appendChild(track);
    body.appendChild(card);
  });

  body.appendChild(sectionHeader("最近", "全部"));
  const list = groupContainer("最近文件");
  [
    ["《沙丘 2》2160p.mkv", "115 网盘 · 18.4 GB"],
    ["漫长的季节 S01E03.mp4", "Emby · 1.2 GB"],
    ["地球脉动 第三季.mkv", "115 网盘 · 9.6 GB"],
  ].forEach(([name, meta], i) => {
    list.appendChild(settingRow("档", name, meta));
    if (i < 2) list.appendChild(divider());
  });
  body.appendChild(list);

  f.appendChild(body);
  f.appendChild(tabBar("library"));
  return f;
}

function buildSettings() {
  const f = phone("设置");
  f.appendChild(statusBar());
  f.appendChild(navBar("设置"));
  const body = bodyColumn();

  const profile = box({
    dir: "HORIZONTAL",
    w: CONTENT_W,
    gap: SPC.m,
    pt: SPC.l,
    pb: SPC.l,
    pl: SPC.l,
    pr: SPC.l,
    radius: R.card,
    bg: C.surface,
    align: "CENTER",
    name: "账号卡",
  });
  profile.primaryAxisSizingMode = "FIXED";
  profile.counterAxisSizingMode = "AUTO";
  profile.appendChild(bar(44, 44, { radius: 22, fill: C.brand, opacity: 0.85 }));
  const col = box({ dir: "VERTICAL", gap: 2, name: "文本" });
  col.appendChild(txt("polly", { type: "callout", weight: "semibold" }));
  col.appendChild(txt("nas.local:8080 · 已连接", { type: "micro", color: C.textTertiary }));
  profile.appendChild(col);
  profile.appendChild(spacer(1, true));
  profile.appendChild(txt("›", { type: "body", color: C.textTertiary }));
  body.appendChild(profile);

  const g1 = groupContainer("外观与播放");
  g1.appendChild(settingRow("色", "外观", "跟随系统"));
  g1.appendChild(divider());
  g1.appendChild(settingRow("播", "播放", "默认清晰度 1080p"));
  g1.appendChild(divider());
  g1.appendChild(settingRow("列", "文件列表", "网格 · 中等")); 
  body.appendChild(g1);

  const g2 = groupContainer("功能");
  g2.appendChild(settingRow("史", "播放记录"));
  g2.appendChild(divider());
  g2.appendChild(settingRow("插", "插件中心"));
  g2.appendChild(divider());
  g2.appendChild(settingRow("关", "关于 RexHub", "版本 2.0"));
  body.appendChild(g2);

  body.appendChild(txt("RexHub", { type: "micro", color: C.textTertiary, align: "CENTER", width: CONTENT_W }));

  f.appendChild(body);
  f.appendChild(tabBar("settings"));
  return f;
}

function buildDetail() {
  const f = phone("详情");
  f.appendChild(statusBar());

  const body = bodyColumn();
  const hero = box({ w: CONTENT_W, h: 208, radius: R.largeCard, name: "主视觉", clip: true });
  hero.primaryAxisSizingMode = "FIXED";
  hero.counterAxisSizingMode = "FIXED";
  hero.layoutMode = "NONE";
  hero.fills = [gradient("#2A3A5A", "#0E131C")];
  const play = box({ w: 56, h: 56, radius: 28, bg: C.brand, align: "CENTER", mainAlign: "CENTER", name: "播放键" });
  play.primaryAxisSizingMode = "FIXED";
  play.counterAxisSizingMode = "FIXED";
  play.appendChild(txt("▶", { type: "callout", color: C.onBrand }));
  play.x = (CONTENT_W - 56) / 2;
  play.y = 76;
  hero.appendChild(play);
  body.appendChild(hero);

  body.appendChild(txt("沙丘 2", { type: "title", weight: "bold", width: CONTENT_W }));
  body.appendChild(txt("2024 · 科幻 · 166 分钟 · 4K HDR", { type: "subheadline", color: C.textSecondary, width: CONTENT_W }));

  const chips = box({ dir: "HORIZONTAL", gap: SPC.s, name: "标签行" });
  chips.primaryAxisSizingMode = "AUTO";
  chips.counterAxisSizingMode = "AUTO";
  ["4K", "HDR", "杜比全景声"].forEach((t, i) => chips.appendChild(chip(t, i === 0)));
  body.appendChild(chips);

  body.appendChild(txt("保罗·厄崔迪与契妮 reunite 之后，向弗雷曼人学习……", { type: "callout", color: C.textSecondary, width: CONTENT_W }));

  body.appendChild(primaryButton("立即播放"));

  body.appendChild(sectionHeader("剧集", "共 8 集"));
  const eps = groupContainer("剧集列表");
  ["第 1 集 · 沙丘", "第 2 集 · 预言", "第 3 集 · 沙虫"].forEach((t, i) => {
    eps.appendChild(settingRow(String(i + 1), t, i === 0 ? "上次看到 12:40" : "已看"));
    if (i < 2) eps.appendChild(divider());
  });
  body.appendChild(eps);

  f.appendChild(body);
  return f;
}

function buildLogin() {
  const f = phone("登录");
  // 浅色落在 surface（白），深色落在 background（黑），与 RexAuthBackdrop 一致。
  f.fills = [washGradient(C === PALETTE.dark ? C.bg : C.surface)];
  f.appendChild(statusBar());

  const body = box({
    w: SCREEN_W,
    pt: SPC.section + SPC.l,
    pb: SPC.xxl,
    pl: M.screenPadding,
    pr: M.screenPadding,
    name: "内容",
  });
  body.primaryAxisSizingMode = "AUTO";
  body.counterAxisSizingMode = "FIXED";
  body.layoutGrow = 1;

  // 品牌组合：图标 + 字标，和 RexBrandLockup 一致（间距 20，无副标题）。
  const brand = box({ w: CONTENT_W, gap: SPC.xl, align: "CENTER", name: "品牌区" });
  brand.primaryAxisSizingMode = "AUTO";
  brand.counterAxisSizingMode = "FIXED";
  brand.paddingBottom = SPC.section + SPC.xxl;

  const logo = box({ w: 88, h: 88, radius: 19, bg: C.brand, align: "CENTER", mainAlign: "CENTER", name: "品牌图标" });
  logo.appendChild(txt("R", { size: 42, weight: "bold", color: C.onBrand, align: "CENTER" }));
  logo.effects = [
    {
      type: "DROP_SHADOW",
      color: { r: 0, g: 0, b: 0, a: 0.1 },
      offset: { x: 0, y: 3 },
      radius: 5,
      spread: 0,
      visible: true,
      blendMode: "NORMAL",
    },
  ];
  brand.appendChild(logo);
  brand.appendChild(txt("RexHub", { type: "title", weight: "semibold", align: "CENTER", width: CONTENT_W }));
  body.appendChild(brand);

  // 三个输入框：54 高、12 圆角、12 间距，占位文案与 LoginView 相同。
  const fields = box({ w: CONTENT_W, gap: SPC.m, name: "输入区" });
  fields.primaryAxisSizingMode = "AUTO";
  fields.counterAxisSizingMode = "FIXED";
  fields.appendChild(loginField("请输入IP，域名，端口", "◷"));
  fields.appendChild(loginField("账号"));
  fields.appendChild(loginField("密码", "◎"));
  body.appendChild(fields);

  const remember = checkRow("记住密码", true);
  remember.paddingTop = SPC.m;
  body.appendChild(remember);

  const https = switchRow("HTTPS 安全访问", true);
  https.paddingTop = SPC.xs;
  body.appendChild(https);

  const submit = box({
    dir: "HORIZONTAL",
    w: CONTENT_W,
    h: M.fieldHeight,
    radius: R.control,
    bg: C.brand,
    mainAlign: "CENTER",
    align: "CENTER",
    name: "登录按钮",
  });
  submit.primaryAxisSizingMode = "FIXED";
  submit.counterAxisSizingMode = "FIXED";
  submit.appendChild(txt("登录", { type: "headline", color: C.onBrand }));
  const submitWrap = box({ w: CONTENT_W, name: "登录按钮区" });
  submitWrap.primaryAxisSizingMode = "AUTO";
  submitWrap.counterAxisSizingMode = "FIXED";
  submitWrap.paddingTop = SPC.l;
  submitWrap.appendChild(submit);
  body.appendChild(submitWrap);

  f.appendChild(body);
  return f;
}

function buildLoginHistory() {
  const f = phone("登录历史");
  f.appendChild(statusBar());

  const barRow = box({
    dir: "HORIZONTAL",
    w: SCREEN_W,
    h: M.minTap,
    pl: M.screenPadding,
    pr: M.screenPadding,
    mainAlign: "SPACE_BETWEEN",
    align: "CENTER",
    name: "导航栏",
  });
  barRow.appendChild(txt("‹ 登录历史", { type: "title3", weight: "bold" }));
  barRow.appendChild(txt("清除", { type: "callout", color: C.brand }));
  f.appendChild(barRow);

  const body = bodyColumn();
  body.appendChild(
    txt("选择一条记录可直接回填地址与账号。", { type: "caption", color: C.textTertiary, width: CONTENT_W })
  );

  const list = groupContainer("历史列表");
  [
    ["polly", "192.168.1.10:8020", "刚刚登录", true],
    ["admin", "nas.local:8080", "3 天前", false],
    ["guest", "rexhub.example.com", "上月", false],
  ].forEach(([user, server, when, current], i) => {
    const row = box({
      dir: "HORIZONTAL",
      w: CONTENT_W,
      h: 64,
      pl: SPC.m,
      pr: SPC.m,
      gap: SPC.m,
      bg: current ? C.selection : C.surface,
      align: "CENTER",
      name: `历史-${user}`,
    });
    row.primaryAxisSizingMode = "FIXED";
    row.counterAxisSizingMode = "AUTO";
    row.appendChild(bar(36, 36, { radius: 18, fill: C.brand, opacity: current ? 0.9 : 0.45, name: "头像" }));

    const col = box({ dir: "VERTICAL", gap: 2, name: "文本" });
    col.appendChild(txt(user, { type: "callout", weight: "semibold" }));
    col.appendChild(txt(server, { type: "micro", color: C.textTertiary }));
    row.appendChild(col);
    row.appendChild(spacer(1, true));
    row.appendChild(txt(when, { type: "micro", color: current ? C.brand : C.textTertiary }));
    list.appendChild(row);
    if (i < 2) list.appendChild(divider());
  });
  body.appendChild(list);

  const note = box({
    w: CONTENT_W,
    pt: SPC.m,
    pb: SPC.m,
    pl: SPC.m,
    pr: SPC.m,
    radius: R.card,
    bg: C.elevated,
    gap: SPC.xs,
    name: "说明",
  });
  note.primaryAxisSizingMode = "AUTO";
  note.counterAxisSizingMode = "FIXED";
  note.appendChild(txt("密码只保存在本机钥匙串", { type: "caption", weight: "semibold", color: C.textSecondary }));
  note.appendChild(txt("历史记录会上传服务器，换设备也能把地址补回来。", { type: "micro", color: C.textTertiary, width: CONTENT_W - SPC.m * 2 }));
  body.appendChild(note);

  f.appendChild(body);
  return f;
}

// ---------- 样式 ----------

async function buildStyles() {
  const [paintStyles, textStyles, effectStyles] = await Promise.all([
    figma.getLocalPaintStylesAsync(),
    figma.getLocalTextStylesAsync(),
    figma.getLocalEffectStylesAsync(),
  ]);
  const havePaint = new Set(paintStyles.map((s) => s.name));
  const haveText = new Set(textStyles.map((s) => s.name));
  const haveEffect = new Set(effectStyles.map((s) => s.name));

  const colorKeys = [
    ["背景", "bg"],
    ["表面", "surface"],
    ["次级表面", "elevated"],
    ["分隔", "separator"],
    ["主文字", "textPrimary"],
    ["次文字", "textSecondary"],
    ["三级文字", "textTertiary"],
    ["品牌", "brand"],
    ["危险", "danger"],
    ["成功", "success"],
    ["选中", "selection"],
    ["输入框底", "field"],
    ["卡片描边", "cardBorder"],
  ];
  colorKeys.forEach(([name, key]) => {
    const full = `${KIT}/${name}`;
    if (havePaint.has(full)) return;
    const s = figma.createPaintStyle();
    s.name = full;
    s.paints = [solid(C[key])];
  });

  Object.keys(TYPE).forEach((key) => {
    const spec = TYPE[key];
    const full = `${KIT}/${key} · ${spec.size}`;
    if (haveText.has(full)) return;
    const s = figma.createTextStyle();
    s.name = full;
    s.fontName = { family: FAMILY, style: STYLE[spec.weight] };
    s.fontSize = spec.size;
    s.lineHeight = { unit: "PIXELS", value: spec.line };
  });

  if (!haveEffect.has(`${KIT}/卡片阴影`)) {
    const effect = figma.createEffectStyle();
    effect.name = `${KIT}/卡片阴影`;
    effect.effects = cardShadow();
  }
}

// ---------- 入口 ----------

async function buildAll(theme, withStyles) {
  C = PALETTE[theme] || PALETTE.dark;
  await initFonts();
  await figma.loadAllPagesAsync();

  if (withStyles) await buildStyles();

  const frames = [
    buildLogin(),
    buildHome(),
    buildMedia(),
    buildLibrary(),
    buildSettings(),
    buildDetail(),
    buildLoginHistory(),
  ];

  // 已有内容时往下排，避免和旧画板叠在一起。
  let top = 0;
  for (const node of figma.currentPage.children) {
    if (frames.indexOf(node) >= 0) continue;
    const bottom = node.y + node.height;
    if (bottom > top) top = bottom;
  }
  const baseY = top > 0 ? top + 96 : 0;

  let x = 0;
  frames.forEach((f) => {
    f.x = x;
    f.y = baseY;
    x += SCREEN_W + 32;
  });

  figma.currentPage.selection = frames;
  figma.viewport.scrollAndZoomIntoView(frames);
  say(`已生成 ${frames.length} 个画板（${theme === "dark" ? "深色" : "浅色"}）`);
}

function say(message, error) {
  figma.ui.postMessage({ type: "log", text: message, error: !!error });
  figma.notify(message, error ? { error: true } : undefined);
}

figma.showUI(__html__, { width: 340, height: 300, themeColors: true });

figma.ui.onmessage = async (msg) => {
  try {
    if (msg.type === "build") {
      await buildAll(msg.theme, msg.styles !== false);
    } else if (msg.type === "styles-only") {
      C = PALETTE[msg.theme] || PALETTE.dark;
      await initFonts();
      await buildStyles();
      say("样式已写入");
    }
  } catch (err) {
    say(`出错了：${err && err.message ? err.message : err}`, true);
  }
};
