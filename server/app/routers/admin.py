from __future__ import annotations

import asyncio
import html
import json
import time
from urllib.parse import quote

from fastapi import APIRouter, Form, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response

from .. import (
    __version__,
    appearance_store,
    config,
    docker_svc,
    pan115,
    resource_search,
    security,
    services_store,
)

router = APIRouter(prefix="/admin", tags=["admin"])

COOKIE_NAME = "rexhub_admin"
STARTED_AT = time.monotonic()

ICONS = {
    "drive": '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M7.5 18h9a4 4 0 0 0 .6-7.96A5.5 5.5 0 0 0 6.5 9.6 4.2 4.2 0 0 0 7.5 18Z"/></svg>',
    "service": '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="4" width="17" height="6.5" rx="2"/><rect x="3.5" y="13.5" width="17" height="6.5" rx="2"/><path d="M7 7.25h.01M7 16.75h.01"/></svg>',
    "plugins": '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M9.5 4.5a2 2 0 1 1 4 0v1h3a1.5 1.5 0 0 1 1.5 1.5v3h1a2 2 0 1 1 0 4h-1v3a1.5 1.5 0 0 1-1.5 1.5h-3v-1a2 2 0 1 0-4 0v1h-3A1.5 1.5 0 0 1 5 17.5v-3H4a2 2 0 1 1 0-4h1v-3A1.5 1.5 0 0 1 6.5 4.5h3Z"/></svg>',
    "search": '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="6.5"/><path d="m16 16 4 4"/></svg>',
    "system": '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h10M18 7h2M4 17h2M10 17h10"/><circle cx="16" cy="7" r="2"/><circle cx="8" cy="17" r="2"/></svg>',
    "appearance": '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3a9 9 0 1 0 0 18c1.1 0 1.8-.8 1.8-1.8 0-.5-.2-.9-.5-1.2-.3-.3-.5-.7-.5-1.2 0-.9.7-1.6 1.6-1.6h1.4A5.2 5.2 0 0 0 21 9.9C21 6 17 3 12 3Z"/><circle cx="8" cy="9.5" r="1.1" fill="currentColor" stroke="none"/><circle cx="12" cy="7.5" r="1.1" fill="currentColor" stroke="none"/><circle cx="16" cy="9.5" r="1.1" fill="currentColor" stroke="none"/></svg>',
    "puzzle-lg": '<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M9.5 4.5a2 2 0 1 1 4 0v1h3a1.5 1.5 0 0 1 1.5 1.5v3h1a2 2 0 1 1 0 4h-1v3a1.5 1.5 0 0 1-1.5 1.5h-3v-1a2 2 0 1 0-4 0v1h-3A1.5 1.5 0 0 1 5 17.5v-3H4a2 2 0 1 1 0-4h1v-3A1.5 1.5 0 0 1 6.5 4.5h3Z"/></svg>',
    "stat-container": '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3.2 20 7.6v8.8L12 20.8 4 16.4V7.6l8-4.4Z"/><path d="M4 7.6l8 4.4 8-4.4M12 12v8.8"/></svg>',
    "stat-run": '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="8.5"/><path d="M10.2 9.2 15 12l-4.8 2.8V9.2Z"/></svg>',
    "stat-idle": '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="8.5"/><path d="M10 9.5v5M14 9.5v5"/></svg>',
    "stat-stack": '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="m12 3.5 8 4.2-8 4.2-8-4.2 8-4.2Z"/><path d="m4 12.2 8 4.2 8-4.2"/><path d="m4 16.4 8 4.2 8-4.2"/></svg>',
}

NAV_ITEMS = [
    ("drive", "网盘管理", "/admin/drive"),
    ("search", "搜索服务", "/admin/search"),
    ("service", "服务管理", "/admin/service"),
    ("plugins", "插件管理", "/admin/plugins"),
    ("appearance", "外观设置", "/admin/appearance"),
    ("system", "系统管理", "/admin/system"),
]

STYLE = """
:root {
  --blue: #3B82F6;
  --blue-soft: #EFF5FF;
  --ink: #0F172A;
  --muted: #8B8F98;
  --line: #E5E7EB;
  --bg: #F2F5FA;
  --surface: #FFFFFF;
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg); color: var(--ink);
  font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", Arial, sans-serif;
  -webkit-font-smoothing: antialiased;
}
a { color: var(--blue); text-decoration: none; }
.mark {
  width: 36px; height: 36px; border-radius: 10px; background: var(--blue);
  color: #fff; display: grid; place-items: center; font-weight: 700; font-size: 18px;
  letter-spacing: .5px; object-fit: cover;
}
img.mark, .login-card img.mark, .sidebar .brand img.mark {
  background: transparent; border-radius: 0;
}
.brand { display: flex; align-items: center; gap: 12px; }
.brand h1 { font-size: 18px; margin: 0; font-weight: 600; }
.brand span { display: block; font-size: 12px; color: var(--muted); margin-top: 2px; }
.ghost {
  border: 1px solid var(--line); background: var(--surface); color: var(--ink);
  border-radius: 10px; padding: 8px 14px; font-size: 13px; cursor: pointer; font-family: inherit;
  transition: background .15s ease, border-color .15s ease;
}
.ghost:hover { background: #F7F9FC; }
.ghost:focus-visible { outline: 2px solid rgba(59, 130, 246, .45); outline-offset: 2px; }
.ghost.solid {
  background: var(--blue); border-color: var(--blue); color: #fff;
  box-shadow: 0 6px 16px rgba(59, 130, 246, .24);
}
.ghost.solid:hover { background: #2F74E8; border-color: #2F74E8; box-shadow: 0 8px 20px rgba(59, 130, 246, .3); }
.ghost.danger { color: #DC2626; border-color: #FBD5D5; }
.ghost.danger:hover { background: #FEF2F2; }
.ghost:disabled { cursor: not-allowed; color: var(--muted); background: #F7F9FC; }
.ghost.solid:disabled { border-color: var(--line); box-shadow: none; }
.grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; }
.grid.cols-2 { grid-template-columns: repeat(2, 1fr); }
.card {
  background: var(--surface); border: 1px solid #E9EDF3; border-radius: 16px; padding: 18px;
  box-shadow: 0 1px 2px rgba(15, 23, 42, .03);
  transition: border-color .18s ease, box-shadow .18s ease, transform .18s ease;
}
.card.flush { padding: 0; overflow: hidden; }
.card.stat { display: flex; align-items: center; gap: 12px; }
.card.stat:hover { border-color: #DCE6F5; box-shadow: 0 8px 22px rgba(15, 23, 42, .06); }
.stat-ico {
  width: 40px; height: 40px; flex: none; color: var(--blue);
  display: grid; place-items: center;
}
.stat-ico img { width: 40px; height: 40px; display: block; object-fit: contain; }
.stat-ico.brand img { width: 36px; height: 36px; border-radius: 50%; }
.stat-body { flex: 1; min-width: 0; }
.card .label { font-size: 12px; color: var(--muted); letter-spacing: .02em; }
.card .value { font-size: 21px; font-weight: 600; margin-top: 4px; letter-spacing: -.2px; }
.card .value.ok { color: #10B981; }
.card .value.muted { color: var(--muted); font-weight: 500; }
.card .value.small { font-size: 15px; letter-spacing: 0; }
.card-head { padding: 14px 18px; border-bottom: 1px solid var(--line); }
.card-head h2 { margin: 0; font-size: 13px; font-weight: 600; color: var(--muted); }
.section { margin-top: 28px; }
.section h2 {
  display: flex; align-items: center; gap: 8px;
  font-size: 13px; font-weight: 600; margin: 0 0 12px; color: #5B6472; letter-spacing: .02em;
}
.section h2::before { content: ""; width: 3px; height: 12px; border-radius: 2px; background: var(--blue); }
.row {
  display: flex; align-items: center; justify-content: space-between; gap: 16px;
  padding: 15px 20px; border-bottom: 1px solid var(--line); font-size: 14px;
  transition: background .15s ease;
}
.row:last-child { border-bottom: none; }
.row.link:hover { background: #F8FAFD; }
.row-title { font-size: 14px; font-weight: 500; }
.row .sub, .sub { color: var(--muted); font-size: 12px; margin-top: 4px; }
.row .mono-sm { font-size: 12px; color: var(--muted); font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
.tag {
  display: inline-flex; align-items: center; gap: 6px;
  font-size: 12px; font-weight: 500; border-radius: 999px; padding: 4px 11px;
  background: var(--blue-soft); color: var(--blue); white-space: nowrap;
}
.tag.muted { background: #F3F4F6; color: var(--muted); }
.empty { display: flex; flex-direction: column; align-items: center; text-align: center; gap: 10px; padding: 40px 24px; }
.empty .ico {
  width: 56px; height: 56px; border-radius: 16px; background: var(--blue-soft); color: var(--blue);
  display: grid; place-items: center; margin-bottom: 4px;
}
.empty h3 { margin: 0; font-size: 15px; font-weight: 600; }
.empty p { margin: 0; font-size: 13px; color: var(--muted); max-width: 440px; line-height: 1.6; }
.empty .ghost { margin-top: 6px; }

/*
 * 管理台布局
 */
.layout { display: flex; min-height: 100vh; }
.sidebar {
  width: 232px; flex: none; position: sticky; top: 0; height: 100vh;
  display: flex; flex-direction: column; padding: 20px 14px;
  background: var(--surface); border-right: 1px solid var(--line);
}
.sidebar .brand { padding: 2px 8px 18px; gap: 10px; }
.sidebar .brand .mark { width: 34px; height: 34px; border-radius: 9px; font-size: 16px; }
.sidebar .brand h1 { font-size: 15px; }
.sidebar .brand span { font-size: 11px; margin-top: 1px; }
.nav { display: flex; flex-direction: column; gap: 4px; }
.nav-label { font-size: 11px; color: var(--muted); padding: 10px 10px 6px; letter-spacing: .04em; }
.nav a {
  display: flex; align-items: center; gap: 10px; padding: 10px 12px; border-radius: 10px;
  font-size: 14px; color: #4B5563; transition: background .15s ease, color .15s ease;
}
.nav a svg { flex: none; color: #9AA3B2; }
.nav a:hover { background: #F5F8FC; color: var(--ink); }
.nav a.active { background: var(--blue-soft); color: var(--blue); font-weight: 600; }
.nav a.active svg { color: var(--blue); }
.sidebar-foot { margin-top: auto; padding-top: 16px; border-top: 1px solid #F0F3F8; }
.version { font-size: 11px; color: var(--muted); padding: 10px 2px 0; text-align: center; }
.main { flex: 1; min-width: 0; display: flex; flex-direction: column; }
.admin-topbar {
  display: flex; align-items: flex-start; justify-content: space-between; gap: 16px;
  padding: 26px 32px 0; max-width: 1120px; width: 100%; margin: 0 auto;
}
.admin-topbar h1 { font-size: 22px; margin: 0 0 5px; font-weight: 600; letter-spacing: -.2px; }
.admin-topbar p { margin: 0; font-size: 13px; color: var(--muted); }
.user-menu { position: relative; flex: none; }
.user-chip {
  display: flex; align-items: center; gap: 9px; padding: 5px 14px 5px 5px;
  background: var(--surface); border: 1px solid var(--line); border-radius: 999px;
  font-size: 13px; font-family: inherit; color: var(--ink); cursor: pointer;
  transition: background .15s ease, border-color .15s ease;
}
.user-chip:hover { background: #F8FAFD; border-color: #D8E1EE; }
.user-chip:focus-visible { outline: 2px solid var(--blue); outline-offset: 2px; }
.user-chip .chev { color: var(--muted); transition: transform .18s ease; }
.user-chip[aria-expanded="true"] .chev { transform: rotate(180deg); }
.user-dropdown {
  position: absolute; right: 0; top: calc(100% + 8px); z-index: 40;
  min-width: 168px; padding: 6px; border-radius: 12px;
  background: var(--surface); border: 1px solid #E8EDF5;
  box-shadow: 0 10px 30px rgba(15, 23, 42, .12);
  opacity: 0; transform: translateY(-6px); pointer-events: none;
  transition: opacity .16s ease, transform .16s ease;
}
.user-dropdown.open { opacity: 1; transform: none; pointer-events: auto; }
.user-dropdown form { margin: 0; }
.menu-item {
  display: block; width: 100%; text-align: left; padding: 9px 11px;
  border: none; border-radius: 8px; background: transparent;
  font-family: inherit; font-size: 13px; color: var(--ink); cursor: pointer;
  transition: background .15s ease;
}
.menu-item:hover { background: #F5F8FC; }
.menu-item.danger { color: #DC2626; }
.menu-item.danger:hover { background: #FEF2F2; }
.avatar {
  width: 28px; height: 28px; border-radius: 50%; background: var(--blue-soft); color: var(--blue);
  display: grid; place-items: center; font-size: 12px; font-weight: 700;
}
.content { padding: 24px 32px 56px; max-width: 1120px; width: 100%; margin: 0 auto; }

/*
 * 登录页
 */
.login-body {
  min-height: 100vh; display: flex; align-items: center; justify-content: center;
  padding: 40px 24px;
  position: relative; overflow: hidden;
  background:
    radial-gradient(880px 500px at 6% -8%, #C9DEFF 0%, transparent 58%),
    radial-gradient(720px 460px at 98% 0%, #D5D9FF 0%, transparent 54%),
    radial-gradient(640px 380px at 80% 110%, #C4ECFF 0%, transparent 50%),
    linear-gradient(180deg, #F3F7FF 0%, #EAF0FA 52%, #E3EBF6 100%);
}
.login-scene { position: fixed; inset: 0; pointer-events: none; z-index: 0; overflow: hidden; }
.login-orb {
  position: absolute; border-radius: 50%; filter: blur(28px);
}
.login-orb.o1 {
  width: 420px; height: 420px; left: -120px; top: -100px;
  background: radial-gradient(circle at 40% 40%, rgba(96, 165, 250, .72), rgba(59, 130, 246, .16) 58%, transparent 72%);
  animation: orb-float 18s ease-in-out infinite;
}
.login-orb.o2 {
  width: 340px; height: 340px; right: -70px; top: 6%;
  background: radial-gradient(circle at 50% 50%, rgba(129, 140, 248, .58), rgba(165, 180, 252, .14) 60%, transparent 74%);
  animation: orb-float 22s ease-in-out infinite reverse;
}
.login-orb.o3 {
  width: 480px; height: 480px; left: 46%; bottom: -220px;
  background: radial-gradient(circle at 50% 40%, rgba(56, 189, 248, .36), rgba(147, 197, 253, .1) 56%, transparent 72%);
  animation: orb-float 26s ease-in-out infinite;
}
.login-grid {
  position: absolute; inset: 0;
  background-image:
    linear-gradient(rgba(59, 130, 246, .08) 1px, transparent 1px),
    linear-gradient(90deg, rgba(59, 130, 246, .08) 1px, transparent 1px);
  background-size: 56px 56px;
  mask-image: radial-gradient(ellipse 70% 60% at 50% 36%, #000 12%, transparent 76%);
  -webkit-mask-image: radial-gradient(ellipse 70% 60% at 50% 36%, #000 12%, transparent 76%);
}
.login-spark {
  position: absolute; inset: 0;
  background:
    radial-gradient(2.5px 2.5px at 18% 22%, rgba(59, 130, 246, .7), transparent),
    radial-gradient(2px 2px at 72% 16%, rgba(99, 102, 241, .55), transparent),
    radial-gradient(2px 2px at 84% 38%, rgba(14, 165, 233, .6), transparent),
    radial-gradient(2px 2px at 28% 64%, rgba(59, 130, 246, .38), transparent),
    radial-gradient(1.8px 1.8px at 62% 72%, rgba(129, 140, 248, .45), transparent);
  animation: spark-twinkle 7s ease-in-out infinite;
}
.login-wave {
  position: absolute; left: -6%; bottom: 0; width: 112%; height: 40vh;
}
.login-wave .w2 { animation: wave-drift 18s ease-in-out infinite; }
.login-wave .w3 { animation: wave-drift 24s ease-in-out infinite reverse; }
.login-grain {
  position: absolute; inset: 0; opacity: .07;
  background-image: url("data:image/svg+xml,%3Csvg viewBox='0 0 160 160' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E");
}
@keyframes orb-float {
  0%, 100% { transform: translate3d(0, 0, 0) scale(1); }
  50% { transform: translate3d(28px, 18px, 0) scale(1.06); }
}
@keyframes wave-drift {
  0%, 100% { transform: translateX(0); }
  50% { transform: translateX(-3.5%); }
}
@keyframes spark-twinkle {
  0%, 100% { opacity: .7; }
  50% { opacity: 1; }
}
.login-card {
  position: relative; z-index: 1;
  width: 100%; max-width: 392px;
  background: rgba(255, 255, 255, .94);
  backdrop-filter: blur(16px) saturate(1.15);
  -webkit-backdrop-filter: blur(16px) saturate(1.15);
  border: 1px solid rgba(255, 255, 255, .95);
  border-radius: 22px; padding: 40px 36px 30px;
  box-shadow:
    0 1px 0 rgba(255, 255, 255, .9) inset,
    0 2px 6px rgba(15, 23, 42, .04),
    0 28px 64px rgba(30, 58, 138, .13);
  animation: card-in .5s cubic-bezier(.22, .8, .3, 1) both;
}
.login-card::before {
  content: ""; position: absolute; left: 50%; top: -1px; transform: translateX(-50%);
  width: 68%; height: 2px; border-radius: 2px; pointer-events: none;
  background: linear-gradient(90deg, transparent, rgba(59, 130, 246, .55), rgba(99, 102, 241, .45), transparent);
}
@keyframes card-in {
  from { opacity: 0; transform: translateY(14px); }
  to { opacity: 1; transform: none; }
}
@media (prefers-reduced-motion: reduce) {
  .login-card { animation: none; }
  .login-orb, .login-spark, .login-wave .w2, .login-wave .w3 { animation: none; }
}
.login-head { display: flex; flex-direction: column; align-items: center; text-align: center; position: relative; }
.login-head::before {
  content: ""; position: absolute; top: -34px; left: 50%; transform: translateX(-50%);
  width: 168px; height: 168px; border-radius: 50%; pointer-events: none;
  background: radial-gradient(circle, rgba(59, 130, 246, .16) 0%, rgba(59, 130, 246, .05) 45%, transparent 70%);
}
.login-head > * { position: relative; }
.login-card .mark {
  width: 56px; height: 56px; border-radius: 16px; font-size: 24px; margin-bottom: 18px;
  box-shadow: 0 10px 24px rgba(59, 130, 246, .28), 0 0 0 8px rgba(59, 130, 246, .06);
}
.login-card h1 { font-size: 22px; margin: 0 0 8px; font-weight: 600; letter-spacing: -.3px; }
.login-badge {
  display: inline-flex; align-items: center; gap: 6px; margin-bottom: 14px;
  font-size: 12px; font-weight: 500; color: var(--blue);
  background: var(--blue-soft); border-radius: 999px; padding: 4px 12px;
}
.login-card > .login-head p, .login-sub {
  font-size: 13px; color: var(--muted); margin: 0; line-height: 1.6;
}
.login-card .field { margin-top: 22px; }
.field > label { display: block; font-size: 12px; font-weight: 500; color: #5B6472; margin: 0 0 8px; letter-spacing: .02em; }
.input-wrap {
  display: flex; align-items: center; gap: 10px;
  height: 50px; padding: 0 14px; border-radius: 13px;
  background: #FFFFFF; border: 1px solid #E3E9F3;
  box-shadow: 0 1px 2px rgba(15, 23, 42, .03);
  transition: border-color .18s ease, background .18s ease, box-shadow .18s ease;
}
.input-wrap:hover { border-color: #D3DEEE; }
.input-wrap:focus-within {
  background: #fff; border-color: var(--blue);
  box-shadow: 0 0 0 4px rgba(59, 130, 246, .12), 0 6px 18px rgba(59, 130, 246, .10);
}
.input-wrap svg { flex: none; color: #A2A9B4; transition: color .18s ease; }
.input-wrap:focus-within svg { color: var(--blue); }
input {
  flex: 1; min-width: 0; height: 100%; border: none; background: transparent;
  padding: 0; font-size: 15px; color: var(--ink); outline: none;
  font-family: inherit;
}
input::placeholder { color: #B6BCC6; }
input:-webkit-autofill { -webkit-box-shadow: 0 0 0 40px #FFFFFF inset; -webkit-text-fill-color: var(--ink); }
.eye {
  flex: none; display: grid; place-items: center; width: 30px; height: 30px;
  border: none; background: transparent; border-radius: 8px; cursor: pointer; color: #A2A9B4;
}
.eye:hover { color: #5B6472; background: #EFF3F9; }
.eye svg.eye-off { display: none; }
.eye[data-visible="true"] svg.eye-on { display: none; }
.eye[data-visible="true"] svg.eye-off { display: block; }
button.primary {
  width: 100%; height: 50px; margin-top: 26px; border: none; border-radius: 13px;
  background: linear-gradient(180deg, #4C8DF8 0%, #3B82F6 55%, #3376EA 100%);
  color: #fff; font-size: 15px; font-weight: 600; cursor: pointer; font-family: inherit;
  box-shadow: 0 1px 0 rgba(255, 255, 255, .22) inset, 0 10px 24px rgba(59, 130, 246, .28);
  transition: transform .12s ease, box-shadow .18s ease, filter .18s ease;
}
button.primary:hover { filter: brightness(1.04); box-shadow: 0 12px 28px rgba(59, 130, 246, .34); }
button.primary:active { transform: translateY(1px); box-shadow: 0 6px 16px rgba(59, 130, 246, .24); }
button.primary:focus-visible { outline: 3px solid rgba(59, 130, 246, .35); outline-offset: 2px; }
.error {
  margin-top: 16px; color: #DC2626; font-size: 13px;
  background: #FEF2F2; border: 1px solid #FEE2E2; border-radius: 10px; padding: 10px 12px;
}
.notice { margin-bottom: 14px; font-size: 13px; border-radius: 10px; padding: 10px 12px; }
.notice.ok { color: #059669; background: #ECFDF5; border: 1px solid #D1FAE5; }
.notice.err { color: #DC2626; background: #FEF2F2; border: 1px solid #FEE2E2; }
.lib-form { padding: 18px; }
.lib-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; margin-bottom: 12px; }
.lib-row {
  display: flex; align-items: flex-start; gap: 10px; padding: 14px;
  border: 1px solid #E9EDF3; border-radius: 12px; background: #FBFCFE;
}
.lib-row + .lib-row { margin-top: 10px; }
.lib-main { flex: 1; min-width: 0; }
.lib-url {
  width: 100%; height: 38px; padding: 0 11px; border: 1px solid #E3E9F3; border-radius: 9px;
  background: #fff; color: var(--ink); font-size: 12.5px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  transition: border-color .18s ease, box-shadow .18s ease;
}
.lib-url:focus { outline: none; border-color: var(--blue); box-shadow: 0 0 0 3px rgba(59, 130, 246, .12); }
.lib-actions { display: flex; gap: 6px; flex: none; }
.lib-preview-btn {
  height: 34px; padding: 0 12px; border: 1px solid #E3E9F3; border-radius: 9px;
  background: #fff; color: #3F4A5A; font-size: 12.5px; font-family: inherit; cursor: pointer;
  transition: border-color .15s ease, color .15s ease, box-shadow .15s ease;
}
.lib-preview-btn:hover { border-color: var(--blue); color: var(--blue); box-shadow: 0 2px 8px rgba(59, 130, 246, .12); }
.lib-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(96px, 1fr)); gap: 12px; margin-top: 16px; }
.lib-cell {
  display: flex; flex-direction: column; align-items: center; gap: 8px;
  padding: 16px 8px 12px; border: 1px solid #EDF1F7; border-radius: 14px; background: #FBFCFE;
}
.lib-cell img { width: 40px; height: 40px; object-fit: contain; }
.lib-cell span {
  max-width: 100%; font-size: 11px; color: var(--muted);
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.lib-grid .muted { font-size: 12.5px; color: var(--muted); grid-column: 1 / -1; }
#lib-modal .modal-panel { width: min(920px, calc(100vw - 32px)); }
.lib-tools { display: flex; align-items: center; gap: 12px; }
.lib-tools input {
  flex: 1; min-width: 0; height: 38px; padding: 0 12px; border: 1px solid #E3E9F3; border-radius: 10px;
  background: #fff; color: var(--ink); font-size: 13px; font-family: inherit;
}
.lib-tools input:focus { outline: none; border-color: var(--blue); box-shadow: 0 0 0 3px rgba(59, 130, 246, .12); }
.lib-tools .sub {
  margin: 0; flex: none; max-width: 46%;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.lib-more { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-top: 14px; }
.lib-more[hidden] { display: none; }
.lib-more .sub { margin: 0; }
.lib-del {
  flex: none; width: 34px; height: 34px; border: none; border-radius: 9px;
  background: transparent; color: #9AA3B2; font-size: 20px; line-height: 1; cursor: pointer;
  transition: background .15s ease, color .15s ease;
}
.lib-del:hover { background: #FEF2F2; color: #DC2626; }
.lib-add { display: flex; gap: 10px; margin-top: 12px; }
.lib-add input {
  flex: 1; height: 40px; padding: 0 12px; border: 1px solid #E3E9F3; border-radius: 10px;
  background: #fff; color: var(--ink); font-size: 13px; font-family: inherit;
  transition: border-color .18s ease, box-shadow .18s ease;
}
.lib-add input:focus { outline: none; border-color: var(--blue); box-shadow: 0 0 0 3px rgba(59, 130, 246, .12); }
.form-foot { display: flex; align-items: center; gap: 12px; margin-top: 14px; }
.remember {
  display: flex; align-items: center; gap: 9px;
  margin-top: 18px; font-size: 13px; color: #5B6472;
  cursor: pointer; user-select: none; width: fit-content;
}
.remember input[type="checkbox"] {
  appearance: none; -webkit-appearance: none;
  flex: none; width: 18px; height: 18px; margin: 0; padding: 0;
  border: 1.5px solid #CBD5E1; border-radius: 6px; background: #fff;
  position: relative; cursor: pointer;
  transition: background .16s ease, border-color .16s ease, box-shadow .16s ease;
}
.remember input[type="checkbox"]:hover { border-color: var(--blue); }
.remember input[type="checkbox"]:checked {
  background: var(--blue); border-color: var(--blue);
  box-shadow: 0 3px 8px rgba(59, 130, 246, .32);
}
.remember input[type="checkbox"]:checked::after {
  content: ""; position: absolute; left: 5px; top: 1.5px;
  width: 5px; height: 9px; border: solid #fff; border-width: 0 2px 2px 0;
  transform: rotate(45deg);
}
.remember input[type="checkbox"]:focus-visible {
  outline: none; box-shadow: 0 0 0 3px rgba(59, 130, 246, .22);
}
.foot { margin-top: 18px; font-size: 12px; color: var(--muted); text-align: center; }
.login-card .foot {
  margin-top: 22px; padding-top: 16px; border-top: 1px solid #F0F3F8;
  display: flex; align-items: center; justify-content: center; gap: 10px;
  font-size: 12px; color: var(--muted);
}
.foot-badge {
  display: inline-flex; align-items: center; gap: 6px; padding: 3px 10px;
  border-radius: 999px; background: #ECFDF5; color: #059669; font-size: 11px; font-weight: 500;
}
.foot-badge .dot {
  width: 6px; height: 6px; border-radius: 50%; background: #10B981;
  box-shadow: 0 0 0 3px rgba(16, 185, 129, .14);
  animation: dot-pulse 2.4s ease-in-out infinite;
}
@keyframes dot-pulse {
  0%, 100% { box-shadow: 0 0 0 3px rgba(16, 185, 129, .14); }
  50% { box-shadow: 0 0 0 5px rgba(16, 185, 129, .06); }
}
@media (prefers-reduced-motion: reduce) {
  .foot-badge .dot { animation: none; }
}
.foot-sep { width: 1px; height: 10px; background: var(--line); }

/*
 * 115 网盘
 */
.card .value.danger { color: #DC2626; }
.tag.ok { background: #ECFDF5; color: #059669; }
.tag.ok::before,
.tag.danger::before { content: ""; width: 6px; height: 6px; border-radius: 50%; background: currentColor; }
.tag.danger { background: #FEE2E2; color: #DC2626; }
.pan-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
.pan-card h3 { margin: 0 0 6px; font-size: 15px; font-weight: 600; }
.pan-card .help { margin: 0; font-size: 12px; color: var(--muted); line-height: 1.6; }
.pan-card textarea {
  width: 100%; min-height: 104px; margin-top: 14px; padding: 12px 14px; resize: vertical;
  border: 1px solid #E5EBF3; border-radius: 12px; background: #F7F9FC; color: var(--ink);
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; line-height: 1.6;
  transition: border-color .18s ease, background .18s ease, box-shadow .18s ease;
}
.pan-card textarea:focus {
  outline: none; background: #fff; border-color: var(--blue);
  box-shadow: 0 0 0 4px rgba(59, 130, 246, .10);
}
.pan-card .ghost { margin-top: 14px; }
.qr-app { display: flex; align-items: center; gap: 10px; margin-top: 14px; font-size: 12px; color: var(--muted); }
.qr-app select {
  flex: 1; height: 38px; padding: 0 10px; border-radius: 10px;
  border: 1px solid #E5EBF3; background: #F7F9FC; color: var(--ink);
  font-family: inherit; font-size: 13px; cursor: pointer;
  transition: border-color .18s ease, background .18s ease, box-shadow .18s ease;
}
.qr-app select:focus {
  outline: none; background: #fff; border-color: var(--blue);
  box-shadow: 0 0 0 4px rgba(59, 130, 246, .10);
}
.qr-box {
  display: grid; place-items: center; min-height: 198px; margin: 14px 0 0;
  background: #FAFBFE; border: 1px dashed #D9E2F0; border-radius: 12px;
}
.qr-box img { width: 180px; height: 180px; display: block; }
.qr-placeholder { font-size: 12px; color: var(--muted); }
.pan-note { min-height: 18px; margin-top: 10px; font-size: 12px; color: var(--muted); line-height: 1.5; }
.pan-note.ok { color: #059669; }
.pan-note.err { color: #DC2626; }
.pan-avatar {
  width: 40px; height: 40px; border-radius: 50%; flex: none; overflow: hidden;
  background: var(--blue-soft); color: var(--blue);
  display: grid; place-items: center; font-size: 16px; font-weight: 700;
}
.pan-avatar img { width: 100%; height: 100%; object-fit: cover; display: block; }
.pan-id-row { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin-top: 2px; }
.pan-id-row .value { margin-top: 0; }
.pan-vip { display: inline-flex; align-items: center; font-size: 11px; color: var(--muted); white-space: nowrap; }
.pan-vip.vip {
  color: #B45309; background: #FEF6E7; border: 1px solid #FBE3B8;
  border-radius: 999px; padding: 2px 9px; font-weight: 500;
}
.pan-vip-exp { margin-top: 4px; font-size: 11px; color: var(--muted); white-space: nowrap; }
.bar { height: 6px; margin-top: 10px; background: #EDF1F7; border-radius: 999px; overflow: hidden; }
.bar > span { display: block; height: 100%; width: 0; background: var(--blue); border-radius: 999px; transition: width .4s ease; }
.bar.slim { height: 4px; margin-top: 8px; }
.row-actions { display: flex; align-items: center; gap: 10px; flex: none; }
.row-main { flex: 1; min-width: 0; }

/* 搜索服务 */
.search-bar { display: flex; gap: 10px; margin-bottom: 12px; }
.search-bar input {
  flex: 1; height: 42px; padding: 0 14px; font: inherit; font-size: 14px;
  color: var(--ink); background: #fff; border: 1px solid var(--line); border-radius: 10px;
}
.search-bar input:focus { outline: none; border-color: #BFD4F7; box-shadow: 0 0 0 3px rgba(59, 130, 246, .12); }
.search-scope {
  display: flex; align-items: center; flex-wrap: wrap; gap: 8px;
  padding: 10px 14px 10px 14px; margin-bottom: 18px;
  background: #fff; border: 1px solid var(--line); border-radius: 12px;
}
.scope-label {
  display: inline-flex; align-items: center; align-self: stretch;
  font-size: 12px; font-weight: 500; color: var(--muted);
  padding-right: 12px; margin-right: 2px; border-right: 1px solid var(--line);
  white-space: nowrap;
}
.scope-item {
  display: inline-flex; align-items: center; gap: 4px; margin: 0;
  font-size: 13px; color: #4B5563; line-height: 1;
  background: #F7F9FC; border: 1px solid transparent; border-radius: 999px;
  padding: 6px 11px 6px 8px; cursor: pointer;
  transition: background .15s ease, border-color .15s ease, color .15s ease;
}
.scope-item:hover { background: #EDF2FA; color: var(--ink); }
.scope-item input {
  appearance: none; -webkit-appearance: none; flex: none;
  width: 15px; height: 15px; margin: 0; cursor: pointer;
  background: #fff; border: 1.5px solid #C3CBD8; border-radius: 5px;
  transition: background .15s ease, border-color .15s ease;
}
.scope-item input:checked {
  background: var(--blue); border-color: var(--blue);
  background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 12 12' fill='none' stroke='white' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><path d='M2.2 6.3 4.7 8.8 9.8 3.4'/></svg>");
  background-repeat: no-repeat; background-position: center; background-size: 11px 11px;
}
.scope-item:has(input:checked) {
  background: var(--blue-soft); border-color: #CFDFF8; color: #1D4ED8; font-weight: 500;
}
.scope-item:focus-within { box-shadow: 0 0 0 3px rgba(59, 130, 246, .16); }
.scope-empty { font-size: 12px; color: var(--muted); }
.search-summary { font-size: 13px; color: var(--muted); margin-bottom: 14px; }
/* 搜索提交中的加载态 */
.spinner {
  display: inline-block; width: 12px; height: 12px; margin-right: 6px;
  vertical-align: -2px; border: 2px solid currentColor; border-top-color: transparent;
  border-radius: 50%; animation: spin .7s linear infinite;
}
@keyframes spin { to { transform: rotate(360deg); } }
button.loading { cursor: progress; }
.ghost.solid.loading:disabled {
  background: var(--blue); border-color: var(--blue); color: #fff;
  box-shadow: 0 6px 16px rgba(59, 130, 246, .24);
}
/* 搜索结果 · 通用资源行（资源名称 + 资源链接） */
.res-list { display: flex; flex-direction: column; }
.res-item {
  display: flex; align-items: center; gap: 14px;
  padding: 12px 18px; border-top: 1px solid var(--line);
  color: inherit; text-decoration: none;
}
.res-item:first-child { border-top: 0; }
.res-item:hover { background: #F7FAFF; }
.res-body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 4px; }
.res-name {
  font-size: 13px; font-weight: 500;
  color: var(--ink); line-height: 1.45; word-break: break-word;
}
.res-link {
  display: flex; align-items: center; gap: 6px; min-width: 0;
  font-size: 12px; color: var(--muted); line-height: 1.5;
}
.res-link .ico { flex: none; width: 14px; text-align: center; }
.res-link .url { min-width: 0; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
.res-item:hover .res-link { color: var(--blue); }
.res-pwd {
  flex: none; font-size: 12px; line-height: 1.4; padding: 3px 8px; border-radius: 6px;
  color: #B45309; background: #FFF7ED; border: 1px solid #FDE7C7;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  user-select: all; white-space: nowrap;
}
.res-kind { flex: none; margin-right: 4px; }
.res-more-wrap {
  display: flex; justify-content: center; padding: 12px 18px;
  border-top: 1px solid var(--line); background: #FCFDFF;
}
.res-more-wrap[hidden] { display: none; }
.res-more[disabled] { cursor: default; }
/* 多个资源库的结果页签，点击切换显示 */
.res-tabs {
  display: flex; flex-wrap: wrap; gap: 8px;
  margin-bottom: 14px; padding-bottom: 12px; border-bottom: 1px solid var(--line);
}
.res-tab {
  display: inline-flex; align-items: center; gap: 8px;
  font: inherit; font-size: 13px; color: #4B5563;
  background: var(--surface); border: 1px solid var(--line); border-radius: 10px;
  padding: 7px 14px; cursor: pointer;
  transition: background .15s ease, border-color .15s ease, color .15s ease;
}
.res-tab:hover { background: #F7F9FC; }
.res-tab.active { background: var(--blue-soft); border-color: #CFDFF8; color: #1D4ED8; font-weight: 600; }
.res-tab-count { font-size: 12px; font-weight: 500; color: var(--muted); }
.res-tab.active .res-tab-count { color: var(--blue); }
.res-panel[hidden] { display: none; }

/* 服务管理 · Docker 聚合 */
.section-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 12px; }
.section-head h2 { margin: 0; }
.toolbar { display: flex; align-items: center; gap: 8px; }
.seg { display: inline-flex; gap: 2px; padding: 2px; background: #EDF1F7; border-radius: 9px; }
.seg button {
  border: 0; background: transparent; font: inherit; font-size: 12px; color: #6B7280;
  padding: 5px 11px; border-radius: 7px; cursor: pointer;
}
.seg button.on { background: #fff; color: var(--ink); font-weight: 600; box-shadow: 0 1px 2px rgba(15, 23, 42, .08); }
.seg button:focus-visible { outline: 2px solid rgba(59, 130, 246, .45); outline-offset: 1px; }
.ghost.sm { padding: 5px 10px; font-size: 12px; border-radius: 8px; }
.dock-row {
  display: grid; align-items: center; gap: 14px;
  grid-template-columns: 8px minmax(0, 1fr) auto auto;
}
.state-dot { width: 8px; height: 8px; border-radius: 50%; background: #C7CCD6; }
.state-dot.on { background: #10B981; box-shadow: 0 0 0 3px rgba(16, 185, 129, .14); }
.state-dot.warn { background: #F59E0B; }
.state-dot.err { background: #EF4444; }
.dock-name { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.dock-ports { display: flex; flex-wrap: wrap; gap: 4px 6px; }
.dock-ports code {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px;
  color: #475569; background: #F4F7FC; border-radius: 6px; padding: 2px 6px;
}
.dock-note { margin: 12px 2px 0; font-size: 12px; color: var(--muted); }

/* 我的服务 · 卡片 */
.svc-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 14px; }
.svc-card {
  text-align: left; font: inherit; cursor: pointer; display: flex; flex-direction: column; gap: 12px;
  background: var(--surface); border: 1px solid #E9EDF3; border-radius: 16px; padding: 16px;
  box-shadow: 0 1px 2px rgba(15, 23, 42, .03);
  transition: border-color .18s ease, box-shadow .18s ease, transform .18s ease;
}
.svc-card:hover { border-color: #CFDFF8; box-shadow: 0 10px 24px rgba(15, 23, 42, .07); transform: translateY(-1px); }
.svc-card:focus-visible { outline: 2px solid rgba(59, 130, 246, .45); outline-offset: 2px; }
.svc-top { display: flex; align-items: center; gap: 8px; min-width: 0; }
.svc-name { font-size: 15px; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.svc-top .tag { margin-left: auto; flex: none; }
.svc-addr {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px; color: #334155;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.svc-addr span { color: var(--blue); }
.svc-foot { display: flex; align-items: center; gap: 8px; }
.tag.ok { background: #ECFDF5; color: #059669; }
.tag.danger { background: #FEF2F2; color: #DC2626; }
.svc-notes { font-size: 12px; color: var(--muted); line-height: 1.5; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

/* 服务配置弹窗 */
.modal { position: fixed; inset: 0; z-index: 60; display: none; }
.modal.open { display: block; }
.modal-mask { position: absolute; inset: 0; background: rgba(15, 23, 42, .34); }
.modal-panel {
  position: relative; width: min(560px, calc(100vw - 32px)); margin: 8vh auto 0; max-height: 84vh;
  overflow: auto; background: var(--surface); border-radius: 18px;
  box-shadow: 0 24px 60px rgba(15, 23, 42, .22); padding: 20px 22px 18px;
}
.modal-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 16px; }
.modal-head h3 { margin: 0; font-size: 16px; font-weight: 600; }
.modal-x {
  border: 0; background: transparent; font-size: 22px; line-height: 1; color: var(--muted);
  cursor: pointer; padding: 2px 6px; border-radius: 8px;
}
.modal-x:hover { background: #F3F6FB; color: var(--ink); }
.fields { display: grid; grid-template-columns: repeat(2, 1fr); gap: 12px; }
.fields .field { display: flex; flex-direction: column; gap: 6px; font-size: 12px; color: var(--muted); }
.fields .field.wide { grid-column: 1 / -1; }
.fields .field input, .fields .field select {
  font: inherit; font-size: 13px; color: var(--ink); background: #fff;
  border: 1px solid var(--line); border-radius: 10px; padding: 9px 11px; width: 100%;
}
.fields .field input:focus, .fields .field select:focus {
  outline: none; border-color: var(--blue); box-shadow: 0 0 0 3px rgba(59, 130, 246, .14);
}
.modal-foot { display: flex; align-items: center; gap: 8px; margin-top: 18px; }
.modal-msg { flex: 1; font-size: 12px; color: var(--muted); }
.modal-msg.err { color: #DC2626; }
@media (max-width: 760px) {
  .dock-row { grid-template-columns: 8px minmax(0, 1fr); row-gap: 10px; }
  .dock-row .dock-ports, .dock-row .row-actions { grid-column: 2; }
  .section-head { flex-wrap: wrap; }
  .svc-grid { grid-template-columns: repeat(2, 1fr); }
}
@media (max-width: 900px) {
  .grid { grid-template-columns: repeat(2, 1fr); }
  .layout { flex-direction: column; }
  .sidebar {
    position: static; width: 100%; height: auto; flex-direction: row; flex-wrap: wrap;
    align-items: center; gap: 8px; padding: 14px 18px;
    border-right: none; border-bottom: 1px solid var(--line);
  }
  .sidebar .brand { padding: 0; margin-right: 8px; }
  .nav { flex-direction: row; overflow-x: auto; flex: 1; }
  .nav-label { display: none; }
  .nav a { white-space: nowrap; padding: 8px 12px; }
  .sidebar-foot { margin: 0; padding: 0; border: none; }
  .version { display: none; }
  .admin-topbar, .content { padding-left: 18px; padding-right: 18px; }
}
@media (max-width: 720px) {
  .grid.cols-2 { grid-template-columns: 1fr; }
  .pan-grid { grid-template-columns: 1fr; }
  .svc-grid { grid-template-columns: 1fr; }
  .fields { grid-template-columns: 1fr; }
}
@media (max-width: 420px) {
  .grid { grid-template-columns: 1fr; }
  .login-body { padding: 28px 18px; }
  .login-card { padding: 32px 24px 24px; border-radius: 20px; }
}
"""

EYE_SCRIPT = """
  <script>
    document.querySelectorAll('.eye').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var wrap = btn.closest('.input-wrap');
        var input = wrap ? wrap.querySelector('input') : null;
        if (!input) return;
        var show = input.type === 'password';
        input.type = show ? 'text' : 'password';
        btn.dataset.visible = show ? 'true' : 'false';
        btn.setAttribute('aria-label', show ? '隐藏密码' : '显示密码');
        input.focus();
      });
    });
  </script>"""

LOGIN_SCENE = """
  <div class="login-scene" aria-hidden="true">
    <div class="login-orb o1"></div>
    <div class="login-orb o2"></div>
    <div class="login-orb o3"></div>
    <div class="login-grid"></div>
    <div class="login-spark"></div>
    <svg class="login-wave" viewBox="0 0 1440 420" preserveAspectRatio="none">
      <defs>
        <linearGradient id="lw1" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stop-color="#D7E6FF"/>
          <stop offset="100%" stop-color="#EAF2FF"/>
        </linearGradient>
        <linearGradient id="lw2" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stop-color="#C5DBFF"/>
          <stop offset="100%" stop-color="#DCEBFF"/>
        </linearGradient>
        <linearGradient id="lw3" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stop-color="#B9D4FF"/>
          <stop offset="100%" stop-color="#C9DCF8"/>
        </linearGradient>
      </defs>
      <path class="w1" d="M0 238 C 180 188, 360 288, 560 248 C 780 204, 980 292, 1440 228 L1440 420 L0 420 Z" fill="url(#lw1)" opacity=".72"/>
      <path class="w2" d="M0 286 C 220 236, 420 334, 700 292 C 980 250, 1180 338, 1440 286 L1440 420 L0 420 Z" fill="url(#lw2)" opacity=".78"/>
      <path class="w3" d="M0 338 C 260 298, 500 372, 780 338 C 1060 304, 1240 372, 1440 332 L1440 420 L0 420 Z" fill="url(#lw3)" opacity=".9"/>
    </svg>
    <div class="login-grain"></div>
  </div>
"""

REMEMBER_SCRIPT = """
  <script>
    (function () {
      var KEY = 'rexhub.login';
      var form = document.querySelector('form.login-card');
      var user = document.getElementById('username');
      var pass = document.getElementById('password');
      var remember = document.getElementById('remember');
      if (!form || !user || !pass || !remember) return;

      try {
        var saved = JSON.parse(decodeURIComponent(atob(localStorage.getItem(KEY) || '')));
        if (saved && saved.u) {
          user.value = saved.u;
          if (saved.p) pass.value = saved.p;
          remember.checked = true;
        }
      } catch (e) {}

      form.addEventListener('submit', function () {
        try {
          if (remember.checked && user.value && pass.value) {
            localStorage.setItem(
              KEY,
              btoa(encodeURIComponent(JSON.stringify({ u: user.value, p: pass.value })))
            );
          } else {
            localStorage.removeItem(KEY);
          }
        } catch (e) {}
      });
    })();
  </script>"""


DRIVE_SCRIPT = """
  <script>
    (function () {
      var $ = function (id) { return document.getElementById(id); };
      function pad(n) { return n < 10 ? '0' + n : '' + n; }
      function fmtTime(ts) {
        var d = new Date(ts * 1000);
        return pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
      }
      function fmtSize(v) {
        if (!v) return '—';
        var units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'], i = 0, n = v;
        while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
        return (n < 10 ? n.toFixed(1) : Math.round(n)) + ' ' + units[i];
      }
      function spaceText(j) {
        if (!j.total) return '—';
        return fmtSize(j.used) + ' / ' + fmtSize(j.total);
      }
      function vipNode(cls, text) {
        var el = document.createElement('span');
        el.className = cls;
        el.textContent = text;
        return el;
      }
      function renderVip(box, exp, j) {
        if (box) {
          box.textContent = '';
          box.appendChild(j.vip_active ? vipNode('pan-vip vip', '超级会员') : vipNode('pan-vip', '非会员'));
        }
        if (exp) {
          exp.textContent = !j.vip_active ? '' : (j.vip_forever ? '永久有效' : ((j.vip_expire || '未知') + ' 到期'));
        }
      }
      function note(el, text, cls) {
        if (!el) return;
        el.textContent = text || '';
        el.className = 'pan-note' + (cls ? ' ' + cls : '');
      }
      function postJSON(url, body) {
        return fetch(url, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body || {})
        }).then(function (r) {
          return r.json().catch(function () { return { ok: false, message: '服务返回异常' }; });
        });
      }

      var STATE = {
        unbound: ['未绑定', 'muted', '绑定 115 账号后可浏览与直连播放'],
        pending: ['待检测', 'muted', '点击「立即检测」获取账号状态'],
        ok: ['已绑定', 'ok', '授权正常，App 可直接浏览与播放'],
        invalid: ['授权失效', 'danger', 'Cookie 已失效，请重新绑定']
      };

      function applyStatus(j) {
        var s = STATE[j.status] || STATE.pending;
        var value = $('pan-state'), tag = $('pan-tag');
        if (value) { value.textContent = s[0]; value.className = 'value ' + (s[1] === 'muted' ? 'muted' : s[1]); }
        if (tag) { tag.textContent = s[0]; tag.className = 'tag ' + s[1]; }
        var sub = $('pan-state-sub');
        if (sub) sub.textContent = j.message || s[2];
        var account = $('pan-account');
        if (account) {
          account.textContent = j.username || '—';
          account.className = 'value small' + (j.username ? '' : ' muted');
        }
        var avatar = $('pan-avatar');
        if (avatar) {
          if (j.avatar) {
            avatar.innerHTML = '<img alt="">';
            avatar.firstChild.src = j.avatar;
          } else {
            avatar.textContent = (j.username || '—').slice(0, 1).toUpperCase();
          }
        }
        renderVip($('pan-vip'), $('pan-vip-exp'), j);
        var space = $('pan-space');
        if (space) {
          space.textContent = spaceText(j);
          space.className = 'value small' + (j.total ? '' : ' muted');
        }
        var detail = $('pan-space-detail');
        if (detail) detail.textContent = spaceText(j);
        var pct = j.total ? Math.min(100, Math.round((j.used || 0) * 100 / j.total)) : 0;
        var bar = $('pan-bar');
        if (bar) bar.style.width = pct + '%';
        var mini = $('pan-bar-mini');
        if (mini) mini.style.width = pct + '%';
        var checked = j.checked_at ? fmtTime(j.checked_at) : '—';
        var c1 = $('pan-checked'), c2 = $('pan-checked-2');
        if (c1) c1.textContent = checked;
        if (c2) c2.textContent = checked;
      }

      var checkBtn = $('btn-check');
      if (checkBtn) checkBtn.addEventListener('click', function () {
        checkBtn.disabled = true;
        checkBtn.textContent = '检测中…';
        postJSON('/admin/drive/check').then(function (j) {
          if (j && j.ok) { location.reload(); }
          else { checkBtn.disabled = false; checkBtn.textContent = '立即检测'; }
        });
      });

      var unbindBtn = $('btn-unbind');
      if (unbindBtn) unbindBtn.addEventListener('click', function () {
        if (!confirm('确定解除 115 网盘绑定？')) return;
        unbindBtn.disabled = true;
        postJSON('/admin/drive/unbind').then(function (j) {
          if (j && j.ok) { location.reload(); }
          else { unbindBtn.disabled = false; alert((j && j.message) || '解绑失败'); }
        });
      });

      var qrBtn = $('btn-qr'), qrBox = $('qr-box'), qrNote = $('qr-note'), qrApp = $('qr-app'), timer = null;
      function stopPoll() { if (timer) { clearInterval(timer); timer = null; } }
      function startQR() {
        stopPoll();
        qrBtn.disabled = true;
        note(qrNote, '正在生成二维码…');
        postJSON('/admin/drive/qr', { app: qrApp ? qrApp.value : 'alipaymini' }).then(function (j) {
          qrBtn.disabled = false;
          if (!j || !j.ok) { note(qrNote, (j && j.message) || '生成失败', 'err'); return; }
          qrBox.innerHTML = '<img src="' + j.image + '" alt="115 登录二维码">';
          note(qrNote, '二维码有效期 ' + Math.round(j.expires_in / 60) + ' 分钟，请用 115 App 扫描');
          timer = setInterval(function () {
            fetch('/admin/drive/qr/status?uid=' + encodeURIComponent(j.uid))
              .then(function (r) { return r.json(); })
              .then(function (s) {
                if (!s) return;
                note(qrNote, s.message, s.status === 2 ? 'ok' : (s.status < 0 ? 'err' : ''));
                if (s.status === 2 && s.bound) {
                  stopPoll();
                  note(qrNote, '绑定成功，正在刷新…', 'ok');
                  setTimeout(function () { location.reload(); }, 600);
                } else if (s.status < 0) {
                  stopPoll();
                }
              })
              .catch(function () {});
          }, 2000);
        });
      }
      if (qrBtn) qrBtn.addEventListener('click', startQR);
      if (qrApp) qrApp.addEventListener('change', function () {
        if (qrBox && qrBox.querySelector('img')) startQR();
      });

      var cookieBtn = $('btn-cookie'), cookieInput = $('cookie-input'), cookieNote = $('cookie-note');
      if (cookieBtn) cookieBtn.addEventListener('click', function () {
        var value = (cookieInput.value || '').trim();
        if (!value) { note(cookieNote, '请先粘贴 Cookie', 'err'); return; }
        cookieBtn.disabled = true;
        note(cookieNote, '正在验证…');
        postJSON('/admin/drive/cookie', { cookie: value }).then(function (j) {
          cookieBtn.disabled = false;
          if (j && j.ok) {
            note(cookieNote, '绑定成功，正在刷新…', 'ok');
            setTimeout(function () { location.reload(); }, 600);
          } else {
            note(cookieNote, (j && j.message) || 'Cookie 校验失败', 'err');
          }
        });
      });

      var root = $('pan-root');
      if (root && root.dataset.bound === '1') {
        var KEY = 'rexhub.pan.check';
        var last = Number(sessionStorage.getItem(KEY) || 0);
        if (Date.now() - last > 60000) {
          sessionStorage.setItem(KEY, String(Date.now()));
          postJSON('/admin/drive/check').then(function (j) { if (j && j.ok) applyStatus(j); });
        }
      }
    })();
  </script>"""


def _fmt_uptime(seconds: float) -> str:
    seconds = int(seconds)
    days, seconds = divmod(seconds, 86400)
    hours, seconds = divmod(seconds, 3600)
    minutes = seconds // 60
    if days:
        return f"{days} 天 {hours} 小时"
    if hours:
        return f"{hours} 小时 {minutes} 分"
    return f"{minutes} 分"


def _is_authenticated(request: Request) -> bool:
    token = request.cookies.get(COOKIE_NAME)
    if not token:
        return False
    return security.verify_token(token, scope="admin") is not None


def _login_page(error: str = "") -> str:
    error_html = f'<div class="error">{error}</div>' if error else ""
    return f"""<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="theme-color" content="#EEF3FB">
<title>RexHub 管理台 · 登录</title><style>{STYLE}</style></head>
<body class="login-body">
  {LOGIN_SCENE}
  <form class="login-card" method="post" action="/admin/login">
    <div class="login-head">
      <img class="mark" src="/static/brandmark.png" alt="RexHub">
      <h1>RexHub 管理台</h1>
      <p>登录后管理网盘授权、插件与播放服务</p>
    </div>

    <div class="field">
      <label for="username">账号</label>
      <div class="input-wrap">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="8" r="3.6"/><path d="M4.8 20c.7-3.6 3.6-5.4 7.2-5.4s6.5 1.8 7.2 5.4"/></svg>
        <input id="username" name="username" placeholder="请输入账号" autocomplete="username" required autofocus>
      </div>
    </div>

    <div class="field">
      <label for="password">密码</label>
      <div class="input-wrap">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><rect x="5" y="10.5" width="14" height="9.5" rx="2.6"/><path d="M8.4 10.5V8a3.6 3.6 0 0 1 7.2 0v2.5"/></svg>
        <input id="password" name="password" type="password" placeholder="请输入密码" autocomplete="current-password" required>
        <button class="eye" type="button" aria-label="显示密码">
          <svg class="eye-on" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 12S6 5.8 12 5.8 21.5 12 21.5 12 18 18.2 12 18.2 2.5 12 2.5 12Z"/><circle cx="12" cy="12" r="2.9"/></svg>
          <svg class="eye-off" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 4l16 16"/><path d="M9.9 5.1A9.6 9.6 0 0 1 12 4.9c6 0 9.5 7.1 9.5 7.1a17 17 0 0 1-2.6 3.5M6.6 6.8A17.3 17.3 0 0 0 2.5 12s3.5 7.1 9.5 7.1c1.5 0 2.8-.4 4-1"/><path d="M10.2 10.3a2.9 2.9 0 0 0 4 4"/></svg>
        </button>
      </div>
    </div>

    {error_html}
    <label class="remember">
      <input type="checkbox" id="remember">
      <span>记住密码</span>
    </label>
    <button class="primary" type="submit">登录</button>
    <div class="foot">
      <span class="foot-badge"><span class="dot"></span>服务运行中</span>
      <span class="foot-sep"></span>
      <span>RexHub Server v{__version__}</span>
    </div>
  </form>
  {EYE_SCRIPT}
  {REMEMBER_SCRIPT}
</body></html>"""


def _setup_page(error: str = "") -> str:
    error_html = f'<div class="error">{error}</div>' if error else ""
    return f"""<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="theme-color" content="#EEF3FB">
<title>RexHub 管理台 · 初始化</title><style>{STYLE}</style></head>
<body class="login-body">
  {LOGIN_SCENE}
  <form class="login-card" method="post" action="/admin/setup">
    <div class="login-head">
      <img class="mark" src="/static/brandmark.png" alt="RexHub">
      <span class="login-badge">首次使用</span>
      <h1>创建管理员账号</h1>
      <p>服务端还没有账号，创建后用于 App 登录与管理台</p>
    </div>

    <div class="field">
      <label for="username">账号</label>
      <div class="input-wrap">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="8" r="3.6"/><path d="M4.8 20c.7-3.6 3.6-5.4 7.2-5.4s6.5 1.8 7.2 5.4"/></svg>
        <input id="username" name="username" placeholder="3 个字符以上，不含空格" autocomplete="username" required autofocus>
      </div>
    </div>

    <div class="field">
      <label for="password">密码</label>
      <div class="input-wrap">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><rect x="5" y="10.5" width="14" height="9.5" rx="2.6"/><path d="M8.4 10.5V8a3.6 3.6 0 0 1 7.2 0v2.5"/></svg>
        <input id="password" name="password" type="password" placeholder="至少 8 位" autocomplete="new-password" required>
        <button class="eye" type="button" aria-label="显示密码">
          <svg class="eye-on" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 12S6 5.8 12 5.8 21.5 12 21.5 12 18 18.2 12 18.2 2.5 12 2.5 12Z"/><circle cx="12" cy="12" r="2.9"/></svg>
          <svg class="eye-off" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 4l16 16"/><path d="M9.9 5.1A9.6 9.6 0 0 1 12 4.9c6 0 9.5 7.1 9.5 7.1a17 17 0 0 1-2.6 3.5M6.6 6.8A17.3 17.3 0 0 0 2.5 12s3.5 7.1 9.5 7.1c1.5 0 2.8-.4 4-1"/><path d="M10.2 10.3a2.9 2.9 0 0 0 4 4"/></svg>
        </button>
      </div>
    </div>

    <div class="field">
      <label for="confirm">确认密码</label>
      <div class="input-wrap">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><rect x="5" y="10.5" width="14" height="9.5" rx="2.6"/><path d="M8.4 10.5V8a3.6 3.6 0 0 1 7.2 0v2.5"/></svg>
        <input id="confirm" name="confirm" type="password" placeholder="再次输入密码" autocomplete="new-password" required>
        <button class="eye" type="button" aria-label="显示密码">
          <svg class="eye-on" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 12S6 5.8 12 5.8 21.5 12 21.5 12 18 18.2 12 18.2 2.5 12 2.5 12Z"/><circle cx="12" cy="12" r="2.9"/></svg>
          <svg class="eye-off" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 4l16 16"/><path d="M9.9 5.1A9.6 9.6 0 0 1 12 4.9c6 0 9.5 7.1 9.5 7.1a17 17 0 0 1-2.6 3.5M6.6 6.8A17.3 17.3 0 0 0 2.5 12s3.5 7.1 9.5 7.1c1.5 0 2.8-.4 4-1"/><path d="M10.2 10.3a2.9 2.9 0 0 0 4 4"/></svg>
        </button>
      </div>
    </div>

    {error_html}
    <button class="primary" type="submit">创建并登录</button>
  </form>
  {EYE_SCRIPT}
</body></html>"""


def _admin_page(active: str, title: str, subtitle: str, content: str) -> str:
    username = html.escape(security.account_username())
    initial = html.escape((security.account_username() or "R")[:1].upper())
    nav_parts = []
    for key, label, href in NAV_ITEMS:
        active_attr = ' class="active"' if key == active else ""
        nav_parts.append(f'<a href="{href}"{active_attr}>{ICONS[key]}<span>{label}</span></a>')
    nav = "".join(nav_parts)
    return f"""<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="theme-color" content="#F2F5FA">
<title>RexHub 管理台 · {title}</title><style>{STYLE}</style></head>
<body>
<div class="layout">
  <aside class="sidebar">
    <div class="brand">
      <img class="mark" src="/static/brandmark.png" alt="RexHub">
      <div><h1>RexHub</h1><span>管理台</span></div>
    </div>
    <nav class="nav">
      <div class="nav-label">管理</div>
      {nav}
    </nav>
    <div class="sidebar-foot">
      <div class="version">v{__version__}</div>
    </div>
  </aside>
  <div class="main">
    <div class="admin-topbar">
      <div>
        <h1>{title}</h1>
        <p>{subtitle}</p>
      </div>
      <div class="user-menu" id="user-menu">
        <button class="user-chip" type="button" id="user-chip" aria-haspopup="true" aria-expanded="false">
          <span class="avatar">{initial}</span>{username}
          <svg class="chev" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m6 9 6 6 6-6"/></svg>
        </button>
        <div class="user-dropdown" id="user-dropdown" role="menu">
          <form method="post" action="/admin/logout"><button class="menu-item danger" type="submit" role="menuitem">退出登录</button></form>
        </div>
      </div>
    </div>
    <div class="content">{content}</div>
  </div>
</div>
<script>
  (function () {{
    var menu = document.getElementById('user-menu');
    if (!menu) return;
    var chip = document.getElementById('user-chip');
    var drop = document.getElementById('user-dropdown');
    function close() {{
      drop.classList.remove('open');
      chip.setAttribute('aria-expanded', 'false');
    }}
    chip.addEventListener('click', function (e) {{
      e.stopPropagation();
      var open = drop.classList.toggle('open');
      chip.setAttribute('aria-expanded', open ? 'true' : 'false');
    }});
    document.addEventListener('click', function (e) {{
      if (!menu.contains(e.target)) close();
    }});
    document.addEventListener('keydown', function (e) {{
      if (e.key === 'Escape') close();
    }});
  }})();
</script>
</body></html>"""


DOCKER_SCRIPT = """
<script>
  (function () {
    var list = document.getElementById('dock-list');
    if (!list) return;
    var seg = document.getElementById('dock-filter');
    var refreshBtn = document.getElementById('dock-refresh');
    var mode = 'all';
    var busy = false;

    function esc(v) {
      return String(v == null ? '' : v).replace(/[&<>"']/g, function (c) {
        return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
      });
    }
    var STATE = {
      running: ['运行中', 'on', 'ok'],
      exited: ['已停止', '', 'muted'],
      created: ['未启动', '', 'muted'],
      paused: ['已暂停', 'warn', 'muted'],
      restarting: ['重启中', 'warn', 'muted'],
      dead: ['异常', 'err', 'danger']
    };
    function rowHtml(c) {
      var s = STATE[c.state] || [c.state || '未知', '', 'muted'];
      var tag = c.project ? '<span class="tag muted">' + esc(c.project) + '</span>' : '';
      var ports = (c.ports && c.ports.length)
        ? c.ports.map(function (p) { return '<code>' + esc(p) + '</code>'; }).join('')
        : '<span class="sub">无端口映射</span>';
      var acts;
      if (c.state === 'running') {
        acts = '<button class="ghost sm" type="button" data-act="restart">重启</button>'
             + '<button class="ghost sm" type="button" data-act="stop">停止</button>';
      } else if (c.state === 'paused') {
        acts = '<button class="ghost sm" type="button" data-act="unpause">继续</button>'
             + '<button class="ghost sm" type="button" data-act="stop">停止</button>';
      } else {
        acts = '<button class="ghost sm" type="button" data-act="start">启动</button>';
      }
      return '<div class="row dock-row" data-id="' + esc(c.id) + '" data-state="'
        + (c.state === 'running' ? 'running' : 'stopped') + '">'
        + '<span class="state-dot ' + s[1] + '"></span>'
        + '<div class="row-main"><div class="dock-name"><span class="row-title">' + esc(c.name) + '</span>'
        + tag + '</div><div class="sub mono-sm">' + esc(c.image) + '</div></div>'
        + '<div class="dock-ports">' + ports + '</div>'
        + '<div class="row-actions"><span class="tag ' + s[2] + '">' + s[0] + '</span>' + acts + '</div>'
        + '</div>';
    }
    function emptyHtml(title, msg) {
      return '<div class="empty"><h3>' + esc(title) + '</h3><p>' + esc(msg) + '</p></div>';
    }
    function setText(id, value) {
      var el = document.getElementById(id);
      if (el) el.textContent = String(value == null ? '—' : value);
    }
    function applyFilter() {
      var rows = list.querySelectorAll('.dock-row');
      for (var i = 0; i < rows.length; i++) {
        var state = rows[i].getAttribute('data-state');
        rows[i].style.display = (mode === 'all' || mode === state) ? '' : 'none';
      }
    }
    function paint(data) {
      if (!data) return;
      var s = data.summary || {};
      setText('dock-total', s.total);
      setText('dock-running', s.running);
      setText('dock-stopped', s.stopped);
      setText('dock-projects', s.projects);
      if (!data.ok) {
        list.innerHTML = emptyHtml('未连接到 Docker', data.message || '无法读取 Docker 容器');
        return;
      }
      var rows = data.containers || [];
      list.innerHTML = rows.length
        ? rows.map(rowHtml).join('')
        : emptyHtml('宿主机还没有容器', 'Docker 已连接，当前没有任何容器。');
      applyFilter();
    }
    function load(silent) {
      busy = true;
      if (refreshBtn && !silent) { refreshBtn.disabled = true; refreshBtn.textContent = '刷新中…'; }
      return fetch('/admin/service/docker', { cache: 'no-store' })
        .then(function (r) { return r.json(); })
        .then(function (data) { paint(data); return data; })
        .catch(function () {
          list.innerHTML = emptyHtml('读取失败', '管理台暂时无法获取 Docker 容器列表');
        })
        .then(function (data) {
          busy = false;
          if (refreshBtn) { refreshBtn.disabled = false; refreshBtn.textContent = '刷新'; }
          return data;
        });
    }
    function act(row, btn) {
      if (busy) return;
      busy = true;
      var buttons = row.querySelectorAll('button');
      for (var i = 0; i < buttons.length; i++) buttons[i].disabled = true;
      var label = btn.textContent;
      btn.textContent = '处理中…';
      fetch('/admin/service/docker/' + encodeURIComponent(row.getAttribute('data-id'))
            + '/' + encodeURIComponent(btn.getAttribute('data-act')), {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}'
      }).then(function (r) { return r.json(); }).then(function (data) {
        busy = false;
        paint(data);
        if (!data.ok) alert(data.message || '操作失败');
      }).catch(function () {
        busy = false;
        btn.disabled = false;
        btn.textContent = label;
        alert('操作失败，请稍后重试');
      });
    }
    if (seg) seg.addEventListener('click', function (e) {
      var btn = e.target.closest('button[data-mode]');
      if (!btn) return;
      mode = btn.getAttribute('data-mode');
      var items = seg.querySelectorAll('button');
      for (var i = 0; i < items.length; i++) items[i].classList.remove('on');
      btn.classList.add('on');
      applyFilter();
    });
    list.addEventListener('click', function (e) {
      var btn = e.target.closest('button[data-act]');
      if (!btn) return;
      var row = btn.closest('.dock-row');
      if (row) act(row, btn);
    });
    if (refreshBtn) refreshBtn.addEventListener('click', function () { if (!busy) load(false); });
    setInterval(function () { if (!busy) load(true); }, 15000);
  })();
</script>
"""

DOCK_STATE = {
    "running": ("运行中", "on", "ok"),
    "exited": ("已停止", "", "muted"),
    "created": ("未启动", "", "muted"),
    "paused": ("已暂停", "warn", "muted"),
    "restarting": ("重启中", "warn", "muted"),
    "dead": ("异常", "err", "danger"),
}


def _container_row(item: dict) -> str:
    state = item.get("state") or ""
    text, dot_cls, tag_cls = DOCK_STATE.get(state, (state or "未知", "", "muted"))
    project = (
        f'<span class="tag muted">{html.escape(item["project"])}</span>'
        if item.get("project")
        else ""
    )
    ports = "".join(f"<code>{html.escape(p)}</code>" for p in item.get("ports") or [])
    ports = ports or '<span class="sub">无端口映射</span>'
    if state == "running":
        actions = (
            '<button class="ghost sm" type="button" data-act="restart">重启</button>'
            '<button class="ghost sm" type="button" data-act="stop">停止</button>'
        )
    elif state == "paused":
        actions = (
            '<button class="ghost sm" type="button" data-act="unpause">继续</button>'
            '<button class="ghost sm" type="button" data-act="stop">停止</button>'
        )
    else:
        actions = '<button class="ghost sm" type="button" data-act="start">启动</button>'
    return f"""
    <div class="row dock-row" data-id="{html.escape(item['id'])}" data-state="{'running' if item.get('running') else 'stopped'}">
      <span class="state-dot {dot_cls}"></span>
      <div class="row-main">
        <div class="dock-name"><span class="row-title">{html.escape(item.get('name') or '')}</span>{project}</div>
        <div class="sub mono-sm">{html.escape(item.get('image') or '')}</div>
      </div>
      <div class="dock-ports">{ports}</div>
      <div class="row-actions">
        <span class="tag {tag_cls}">{text}</span>
        {actions}
      </div>
    </div>"""


SERVICE_SCRIPT = """
<script>
  (function () {
    var modal = document.getElementById('svc-modal');
    var form = document.getElementById('svc-form');
    if (!modal || !form) return;
    var titleEl = document.getElementById('svc-title');
    var msg = document.getElementById('svc-msg');
    var delBtn = document.getElementById('svc-delete');
    var saveBtn = document.getElementById('svc-save');
    var f = form.elements;
    var DATA = {};
    try {
      (JSON.parse(document.getElementById('svc-data').textContent || '[]') || []).forEach(function (it) {
        DATA[it.id] = it;
      });
    } catch (e) { DATA = {}; }
    var current = '';

    function open(id) {
      current = id || '';
      var item = DATA[current] || {};
      form.reset();
      f['name'].value = item.name || '';
      f['category'].value = item.category || 'other';
      f['host'].value = item.host || '';
      f['port'].value = item.port || '';
      f['username'].value = item.username || '';
      f['password'].value = '';
      f['database'].value = item.database || '';
      f['api_key'].value = item.api_key || '';
      f['url'].value = item.url || '';
      f['notes'].value = item.notes || '';
      f['password'].placeholder = item.has_password ? '已保存，留空保持不变' : '可选';
      titleEl.textContent = current ? '编辑服务 · ' + (item.name || '') : '新增服务';
      delBtn.hidden = !current;
      msg.textContent = '';
      msg.classList.remove('err');
      modal.classList.add('open');
      modal.setAttribute('aria-hidden', 'false');
      setTimeout(function () { f['name'].focus(); }, 30);
    }
    function close() {
      modal.classList.remove('open');
      modal.setAttribute('aria-hidden', 'true');
    }
    function fail(text) {
      msg.textContent = text || '操作失败';
      msg.classList.add('err');
    }
    function payload() {
      return {
        id: current,
        name: f['name'].value.trim(),
        category: f['category'].value,
        host: f['host'].value.trim(),
        port: f['port'].value.trim(),
        username: f['username'].value.trim(),
        password: f['password'].value,
        database: f['database'].value.trim(),
        api_key: f['api_key'].value.trim(),
        url: f['url'].value.trim(),
        notes: f['notes'].value.trim()
      };
    }

    form.addEventListener('submit', function (e) {
      e.preventDefault();
      msg.textContent = '';
      msg.classList.remove('err');
      saveBtn.disabled = true;
      saveBtn.textContent = '保存中…';
      fetch('/admin/service/save', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload())
      }).then(function (r) { return r.json(); }).then(function (data) {
        if (data.ok) { location.reload(); return; }
        fail(data.message);
        saveBtn.disabled = false;
        saveBtn.textContent = '保存';
      }).catch(function () {
        fail('保存失败，请稍后重试');
        saveBtn.disabled = false;
        saveBtn.textContent = '保存';
      });
    });

    delBtn.addEventListener('click', function () {
      if (!current) return;
      var name = (DATA[current] && DATA[current].name) || '该服务';
      if (!confirm('确定删除「' + name + '」的配置？')) return;
      delBtn.disabled = true;
      fetch('/admin/service/' + encodeURIComponent(current) + '/delete', {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}'
      }).then(function (r) { return r.json(); }).then(function (data) {
        if (data.ok) { location.reload(); return; }
        delBtn.disabled = false;
        fail(data.message);
      }).catch(function () {
        delBtn.disabled = false;
        fail('删除失败，请稍后重试');
      });
    });

    document.addEventListener('click', function (e) {
      var card = e.target.closest('.svc-card');
      if (card) open(card.getAttribute('data-id'));
    });
    document.addEventListener('keydown', function (e) {
      if (e.key !== 'Enter' && e.key !== ' ') return;
      var card = e.target.closest('.svc-card');
      if (!card) return;
      e.preventDefault();
      open(card.getAttribute('data-id'));
    });
    modal.addEventListener('click', function (e) {
      if (e.target.hasAttribute('data-close')) close();
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && modal.classList.contains('open')) close();
    });
  })();
</script>
"""


def _service_card(item: dict, status: dict) -> str:
    online = status.get("online")
    latency = status.get("latency")
    if online:
        dot = "on"
        state_tag = f'<span class="tag ok">在线 · {latency} ms</span>'
    elif online is False:
        dot = "err"
        state_tag = '<span class="tag danger">离线</span>'
    else:
        dot = ""
        state_tag = '<span class="tag muted">未检测</span>'
    notes = item.get("notes") or ""
    notes_html = f'<div class="svc-notes">{html.escape(notes)}</div>' if notes else ""
    port = html.escape(str(item.get("port") or ""))
    category = services_store.category_label(item.get("category") or "other")
    return f"""
    <div class="svc-card" role="button" tabindex="0" data-id="{html.escape(item['id'])}">
      <div class="svc-top">
        <span class="state-dot {dot}"></span>
        <span class="svc-name">{html.escape(item.get('name') or '')}</span>
        <span class="tag muted">{html.escape(category)}</span>
      </div>
      <div class="svc-addr">{html.escape(str(item.get('host') or ''))}<span>:{port}</span></div>
      {notes_html}
      <div class="svc-foot">{state_tag}</div>
    </div>"""


LINK_KINDS = {
    "magnet:": ("磁力", "🧲"),
    "ed2k:": ("ed2k", "🔗"),
}


def _link_meta(link: str) -> tuple[str, str]:
    value = (link or "").lower()
    for prefix, meta in LINK_KINDS.items():
        if value.startswith(prefix):
            return meta
    if value.startswith(("http://", "https://")):
        return "网页", "🌐"
    return "资源", "📄"


def _result_row(result: dict) -> str:
    """通用资源行：资源名称 + 资源链接（单行省略），有提取码时一并显示。"""

    title = html.escape(str(result.get("title") or "").strip() or "未命名资源")
    link = str(result.get("link") or "").strip()
    safe_link = html.escape(link, quote=True)
    kind, icon = _link_meta(link)
    # 外部搜索源（CloudSaver）自带网盘类型，优先用它做标签
    kind = str(result.get("kind") or "").strip() or kind
    password = str(result.get("password") or "").strip()
    pwd_html = (
        f'<span class="res-pwd" title="密码：{html.escape(password, quote=True)}">'
        f"密码 {html.escape(password)}</span>"
        if password
        else ""
    )
    return f"""
    <a class="res-item" href="{safe_link}" title="{safe_link}" target="_blank" rel="noreferrer">
      <span class="res-body">
        <span class="res-name">{title}</span>
        <span class="res-link"><span class="ico">{icon}</span><span class="url">{html.escape(link)}</span></span>
      </span>
      {pwd_html}
      <span class="tag muted res-kind">{kind}</span>
    </a>"""


SEARCH_RESULTS_SCRIPT = """
<script>
  (function () {
    var root = document.getElementById('search-results');
    if (!root) return;
    var q = root.getAttribute('data-q') || '';

    function activate(id) {
      var tabs = root.querySelectorAll('.res-tab');
      for (var i = 0; i < tabs.length; i++) {
        tabs[i].classList.toggle('active', tabs[i].getAttribute('data-tab') === id);
      }
      var panels = root.querySelectorAll('.res-panel');
      for (var j = 0; j < panels.length; j++) {
        panels[j].hidden = panels[j].getAttribute('data-panel') !== id;
      }
    }

    root.addEventListener('click', function (e) {
      var tab = e.target.closest ? e.target.closest('.res-tab') : null;
      if (tab) {
        activate(tab.getAttribute('data-tab'));
        return;
      }
      var btn = e.target.closest ? e.target.closest('.res-more') : null;
      if (!btn || btn.disabled) return;
      var svc = btn.getAttribute('data-svc') || '';
      var list = root.querySelector('[data-list="' + svc + '"]');
      var offset = list ? list.querySelectorAll('.res-item').length : 0;
      btn.disabled = true;
      btn.textContent = '加载中…';
      var url = '/admin/api/search?q=' + encodeURIComponent(q)
        + '&svc=' + encodeURIComponent(svc) + '&offset=' + offset;
      fetch(url, { credentials: 'same-origin' })
        .then(function (r) { return r.json(); })
        .then(function (data) {
          if (!data || !data.ok) throw new Error((data && data.message) || '加载失败');
          if (list && data.html) list.insertAdjacentHTML('beforeend', data.html);
          var tag = root.querySelector('[data-count="' + svc + '"]');
          if (tag && typeof data.shown === 'number') tag.textContent = data.shown + ' 条';
          var totalEl = document.getElementById('res-total');
          if (totalEl) totalEl.textContent = root.querySelectorAll('.res-item').length;
          if (data.has_more) {
            btn.disabled = false;
            btn.textContent = '加载更多';
          } else {
            var wrap = btn.parentNode;
            if (wrap) wrap.hidden = true;
          }
        })
        .catch(function (err) {
          btn.disabled = false;
          btn.textContent = '加载更多';
          alert(err && err.message ? err.message : '加载失败');
        });
    });
  })();
</script>"""


def _result_tab(item: dict, rows: list[dict], error: str, active: bool) -> str:
    """结果页签：一个资源库一个标签，点击切换显示。"""

    name = html.escape(item.get("name") or "")
    svc_id = html.escape(str(item.get("id") or ""), quote=True)
    count = "未完成" if error else f"{len(rows)} 条"
    cls = "res-tab active" if active else "res-tab"
    return (
        f'<button class="{cls}" type="button" role="tab" data-tab="{svc_id}">'
        f'{name}<span class="res-tab-count" data-count="{svc_id}">{count}</span></button>'
    )


def _result_panel(
    item: dict,
    rows: list[dict],
    error: str,
    has_more: bool = False,
    active: bool = False,
) -> str:
    svc_id = html.escape(str(item.get("id") or ""), quote=True)
    if error:
        body = f'<div class="card empty"><p>{html.escape(error)}</p></div>'
    elif not rows:
        body = '<div class="card empty"><p>没有找到匹配的资源。</p></div>'
    else:
        more = (
            f'<div class="res-more-wrap"><button class="ghost res-more" type="button"'
            f' data-svc="{svc_id}">加载更多</button></div>'
            if has_more
            else ""
        )
        body = (
            f'<div class="card flush"><div class="res-list" data-list="{svc_id}">'
            + "".join(_result_row(row) for row in rows)
            + f"</div>{more}</div>"
        )
    return (
        f'<div class="res-panel" data-panel="{svc_id}"'
        f'{" hidden" if not active else ""}>{body}</div>'
    )


SEARCH_FORM_SCRIPT = """
<script>
  (function () {
    var form = document.getElementById('search-form');
    if (!form) return;
    var btn = form.querySelector('button[type="submit"]');
    if (!btn) return;
    var label = btn.textContent;
    var busy = false;
    form.addEventListener('submit', function (e) {
      if (busy) {
        e.preventDefault();
        return;
      }
      busy = true;
      btn.disabled = true;
      btn.classList.add('loading');
      btn.innerHTML = '<span class="spinner"></span>搜索中…';
    });
    window.addEventListener('pageshow', function (e) {
      if (!e.persisted) return;
      busy = false;
      btn.disabled = false;
      btn.classList.remove('loading');
      btn.textContent = label;
    });
  })();
</script>"""


async def _search_page(q: str = "", selected: list[str] | None = None) -> str:
    items = [
        item
        for item in services_store.list_services()
        if resource_search.resolve_provider(item) is not None
    ]
    chosen = set(selected) if selected else {item["id"] for item in items}
    scope = "".join(
        f'<label class="scope-item">'
        f'<input type="checkbox" name="svc" value="{html.escape(item["id"])}"'
        f'{" checked" if item["id"] in chosen else ""}>'
        f'<span>{html.escape(item.get("name") or "")}</span></label>'
        for item in items
    ) or '<span class="scope-empty">还没有可搜索的服务</span>'
    keyword = html.escape(q)

    if q:
        picked = [item for item in items if item["id"] in chosen]
        if picked:
            outcomes = await resource_search.search(picked, q)
            total = sum(len(rows) for _, rows, _, _ in outcomes)
            tabs = "".join(
                _result_tab(item, rows, error, index == 0)
                for index, (item, rows, error, _) in enumerate(outcomes)
            )
            panels = "".join(
                _result_panel(item, rows, error, has_more, index == 0)
                for index, (item, rows, error, has_more) in enumerate(outcomes)
            )
            tabs_html = (
                f'<div class="res-tabs" role="tablist">{tabs}</div>'
                if len(outcomes) > 1
                else ""
            )
            results = (
                f'<div id="search-results" data-q="{keyword}">'
                f'<div class="search-summary">关键词「{keyword}」 · '
                f"来源 {len(picked)} 个 · 当前显示 "
                f'<span id="res-total">{total}</span> 条'
                f"（每库首屏 {resource_search.RESULT_LIMIT} 条，点击「加载更多」继续，"
                f"最多 {resource_search.CANDIDATES} 条）"
                f"</div>{tabs_html}"
                f"{panels}</div>"
                + SEARCH_RESULTS_SCRIPT
            )
        else:
            blocks = '<div class="card empty"><h3>没有选择搜索来源</h3><p>勾选至少一个服务后再搜索。</p></div>'
            results = blocks
    else:
        results = (
            '<div class="card empty"><h3>输入关键词开始搜索</h3>'
            "<p>勾选参与搜索的服务，结果会按来源分块返回。</p></div>"
        )

    content = f"""
<div class="section" style="margin-top:0">
  <div class="section-head">
    <h2>综合资源</h2>
  </div>
  <form id="search-form" method="get" action="/admin/search">
    <div class="search-bar">
      <input name="q" value="{keyword}" maxlength="120" placeholder="输入片名 / 关键词，例如 流浪地球、Project Hail Mary">
      <button class="ghost solid" type="submit">搜索</button>
    </div>
    <div class="search-scope">
      <span class="scope-label">搜索范围</span>
      {scope}
    </div>
  </form>
  {results}
</div>
{SEARCH_FORM_SCRIPT}
"""
    return _admin_page("search", "搜索服务", "跨资源库检索种子与内容", content)


def _service_page(request: Request) -> str:
    items = services_store.list_services()
    probes = services_store.statuses(items)
    section_defs = [("general", "综合资源"), ("movie", "影视资源"), ("girl", "小姐姐资源")]
    blocks = []
    for index, (key, title) in enumerate(section_defs):
        group = [item for item in items if (item.get("section") or "general") == key]
        cards = "".join(_service_card(item, probes.get(item["id"], {})) for item in group)
        grid = f'\n  <div class="svc-grid">{cards}</div>' if cards else ""
        style = ' style="margin-top:0"' if index == 0 else ""
        blocks.append(
            f"""
<div class="section"{style}>
  <div class="section-head">
    <h2>{title}</h2>
  </div>{grid}
</div>"""
        )
    services_sections = "".join(blocks)
    public = []
    for item in items:
        row = {key: value for key, value in item.items() if key != "password"}
        row["has_password"] = bool(item.get("password"))
        public.append(row)
    services_json = json.dumps(public, ensure_ascii=False).replace("</", "<\\/")
    category_options = "".join(
        f'<option value="{html.escape(key)}">{html.escape(label)}</option>'
        for key, label in services_store.CATEGORIES.items()
    )

    data = docker_svc.containers()
    docker_section = ""
    docker_script = ""
    if data.get("ok"):
        summary = data.get("summary") or {}
        rows = "".join(_container_row(item) for item in data.get("containers") or [])
        body = rows or (
            '<div class="empty"><h3>宿主机还没有容器</h3>'
            '<p>Docker 服务已连接，但当前没有任何容器。启动容器后会自动出现在这里。</p></div>'
        )
        host = html.escape(summary.get("host") or docker_svc.DOCKER_HOST)
        docker_section = f"""
<div class="grid" style="margin-top:28px">
  <div class="card stat">
    <div class="stat-ico">{ICONS["stat-container"]}</div>
    <div class="stat-body"><div class="label">容器总数</div><div class="value" id="dock-total">{summary.get("total", 0)}</div></div>
  </div>
  <div class="card stat">
    <div class="stat-ico">{ICONS["stat-run"]}</div>
    <div class="stat-body"><div class="label">运行中</div><div class="value ok" id="dock-running">{summary.get("running", 0)}</div></div>
  </div>
  <div class="card stat">
    <div class="stat-ico">{ICONS["stat-idle"]}</div>
    <div class="stat-body"><div class="label">已停止</div><div class="value" id="dock-stopped">{summary.get("stopped", 0)}</div></div>
  </div>
  <div class="card stat">
    <div class="stat-ico">{ICONS["stat-stack"]}</div>
    <div class="stat-body"><div class="label">Compose 项目</div><div class="value" id="dock-projects">{summary.get("projects", 0)}</div></div>
  </div>
</div>

<div class="section">
  <div class="section-head">
    <h2>Docker 容器</h2>
    <div class="toolbar">
      <div class="seg" id="dock-filter" role="group" aria-label="筛选容器">
        <button type="button" class="on" data-mode="all">全部</button>
        <button type="button" data-mode="running">运行中</button>
        <button type="button" data-mode="stopped">已停止</button>
      </div>
      <button class="ghost" id="dock-refresh" type="button">刷新</button>
    </div>
  </div>
  <div class="card flush" id="dock-list">{body}</div>
  <p class="dock-note" id="dock-note">Docker 地址 <span class="mono-sm">{host}</span> · 启停操作直接作用于宿主机容器 · 每 15 秒自动刷新</p>
</div>"""
        docker_script = DOCKER_SCRIPT
    content = f"""
{services_sections}
{docker_section}

<div class="modal" id="svc-modal" aria-hidden="true">
  <div class="modal-mask" data-close></div>
  <div class="modal-panel" role="dialog" aria-modal="true" aria-labelledby="svc-title">
    <div class="modal-head">
      <h3 id="svc-title">服务配置</h3>
      <button class="modal-x" type="button" data-close aria-label="关闭">×</button>
    </div>
    <form id="svc-form" autocomplete="off">
      <div class="fields">
        <label class="field"><span>服务名称</span><input name="name" maxlength="64" required placeholder="bitmagnet"></label>
        <label class="field"><span>类型</span><select name="category">{category_options}</select></label>
        <label class="field"><span>主机 / IP</span><input name="host" maxlength="128" required placeholder="192.168.2.38"></label>
        <label class="field"><span>端口</span><input name="port" type="number" min="1" max="65535" required placeholder="3333"></label>
        <label class="field"><span>用户名</span><input name="username" maxlength="128" placeholder="可选"></label>
        <label class="field"><span>密码</span><input name="password" type="password" maxlength="200" placeholder="可选"></label>
        <label class="field"><span>数据库名</span><input name="database" maxlength="128" placeholder="可选"></label>
        <label class="field"><span>API Key</span><input name="api_key" maxlength="256" placeholder="可选"></label>
        <label class="field wide"><span>访问地址</span><input name="url" maxlength="300" placeholder="http://192.168.2.38:3333"></label>
        <label class="field wide"><span>备注</span><input name="notes" maxlength="300" placeholder="可选"></label>
      </div>
      <div class="modal-foot">
        <button class="ghost danger" type="button" id="svc-delete" hidden>删除</button>
        <span class="modal-msg" id="svc-msg"></span>
        <button class="ghost" type="button" data-close>取消</button>
        <button class="ghost solid" type="submit" id="svc-save">保存</button>
      </div>
    </form>
  </div>
</div>
<script type="application/json" id="svc-data">{services_json}</script>
{docker_script}
{SERVICE_SCRIPT}
"""
    return _admin_page("service", "服务管理", "聚合管理 NAS 上的服务连接配置", content)


def _drive_page() -> str:
    snap = pan115.snapshot()
    bound = bool(snap["bound"])
    status = snap["status"]

    if not bound:
        state_text, state_cls, state_sub = "未绑定", "muted", "绑定 115 账号后可浏览与直连播放"
    elif status == "ok":
        state_text, state_cls, state_sub = "已绑定", "ok", "授权正常，App 可直接浏览与播放"
    elif status == "invalid":
        state_text, state_cls, state_sub = "授权失效", "danger", snap["message"] or "Cookie 已失效，请重新绑定"
    else:
        state_text, state_cls, state_sub = "待检测", "muted", "点击「立即检测」获取账号状态"

    account = html.escape(snap["username"]) if snap["username"] else "—"
    avatar_url = html.escape(snap.get("avatar") or "")
    avatar_html = (
        f'<img src="{avatar_url}" alt="{account}">'
        if avatar_url
        else (account[:1].upper() if account != "—" else "—")
    )
    if snap.get("vip_active"):
        vip_pill = '<span class="pan-vip vip">超级会员</span>'
        vip_exp = "永久有效" if snap.get("vip_forever") else f"{html.escape(snap.get('vip_expire') or '未知')} 到期"
    elif bound:
        vip_pill, vip_exp = '<span class="pan-vip">非会员</span>', ""
    else:
        vip_pill, vip_exp = "", ""
    space_text = "—"
    percent = 0
    if snap["total"]:
        space_text = f"{pan115.fmt_size(snap['used'])} / {pan115.fmt_size(snap['total'])}"
        percent = min(100, round((snap["used"] or 0) * 100 / snap["total"]))
    checked = (
        time.strftime("%m-%d %H:%M", time.localtime(snap["checked_at"]))
        if snap["checked_at"]
        else "—"
    )

    if bound:
        bound_at = (
            time.strftime("%Y-%m-%d %H:%M", time.localtime(snap["bound_at"]))
            if snap["bound_at"]
            else "—"
        )
        manage = f"""
<div class="section">
  <h2>115 网盘</h2>
  <div class="card flush">
    <div class="row">
      <div class="row-main">
        <div class="row-title">已绑定账号：{account}</div>
        <div class="sub">绑定于 {bound_at} · Cookie 仅保存在服务端，视频流不经过服务端中转</div>
      </div>
      <div class="row-actions">
        <button class="ghost danger" id="btn-unbind" type="button">解除绑定</button>
      </div>
    </div>
  </div>
</div>"""
    else:
        manage = f"""
<div class="section">
  <h2>绑定 115 网盘</h2>
  <div class="pan-grid">
    <div class="card pan-card">
      <h3>扫码登录</h3>
      <p class="help">选择要登录的客户端后生成二维码，用对应 115 App 扫码并在手机上确认，授权会自动保存到服务端。</p>
      <label class="qr-app">扫码端
        <select id="qr-app">{''.join(f'<option value="{html.escape(k)}">{html.escape(v)}</option>' for k, v in pan115.QR_APPS.items())}</select>
      </label>
      <div class="qr-box" id="qr-box"><span class="qr-placeholder">点击下方按钮生成二维码</span></div>
      <button class="ghost solid" id="btn-qr" type="button">生成二维码</button>
      <div class="pan-note" id="qr-note"></div>
    </div>
    <div class="card pan-card">
      <h3>Cookie 登录</h3>
      <p class="help">在浏览器登录 115 后，从开发者工具复制 Cookie，需包含 UID、CID、SEID。</p>
      <textarea id="cookie-input" spellcheck="false" placeholder="UID=...; CID=...; SEID=...; KID=..."></textarea>
      <button class="ghost solid" id="btn-cookie" type="button">验证并保存</button>
      <div class="pan-note" id="cookie-note"></div>
    </div>
  </div>
</div>"""

    content = f"""
<div id="pan-root" data-bound="{1 if bound else 0}" hidden></div>
<div class="grid">
  <div class="card stat">
    <div class="stat-ico brand"><img src="/static/115.png" alt="115 网盘"></div>
    <div class="stat-body">
      <div class="label">授权状态</div>
      <div class="value {state_cls}" id="pan-state">{state_text}</div>
    </div>
  </div>
  <div class="card stat">
    <span class="pan-avatar" id="pan-avatar">{avatar_html}</span>
    <div class="stat-body">
      <div class="label">网盘账号</div>
      <div class="pan-id-row">
        <span class="value small{' muted' if account == '—' else ''}" id="pan-account">{account}</span>
        <span id="pan-vip">{vip_pill}</span>
      </div>
      <div class="pan-vip-exp" id="pan-vip-exp">{vip_exp}</div>
    </div>
  </div>
  <div class="card stat">
    <div class="stat-ico"><img src="/static/pan-storage.svg" alt=""></div>
    <div class="stat-body">
      <div class="label">存储空间</div>
      <div class="value small{' muted' if space_text == '—' else ''}" id="pan-space">{space_text}</div>
      <div class="bar slim"><span id="pan-bar-mini" style="width:{percent}%"></span></div>
    </div>
  </div>
  <div class="card stat">
    <div class="stat-ico"><img src="/static/pan-check.svg" alt=""></div>
    <div class="stat-body">
      <div class="label">最近检测</div>
      <div class="value small" id="pan-checked">{checked}</div>
    </div>
  </div>
</div>

<div class="section">
  <h2>网盘状态监控</h2>
  <div class="card flush">
    <div class="row">
      <div class="row-main">
        <div class="row-title">授权状态</div>
        <div class="sub" id="pan-state-sub">{state_sub}</div>
      </div>
      <div class="row-actions">
        <span class="tag {state_cls}" id="pan-tag">{state_text}</span>
        <button class="ghost solid" id="btn-check" type="button"{" disabled" if not bound else ""}>立即检测</button>
      </div>
    </div>
    <div class="row">
      <div class="row-main">
        <div class="row-title">存储空间</div>
        <div class="bar"><span id="pan-bar" style="width:{percent}%"></span></div>
        <div class="sub" id="pan-space-detail">{space_text}</div>
      </div>
    </div>
    <div class="row">
      <div class="row-title">上次检测</div>
      <span class="sub" id="pan-checked-2">{checked}</span>
    </div>
  </div>
</div>
{manage}
{DRIVE_SCRIPT}
"""
    return _admin_page("drive", "网盘管理", "管理 115 网盘授权与状态监控", content)


def _plugins_page() -> str:
    content = f"""
<div class="grid cols-2">
  <div class="card"><div class="label">已安装</div><div class="value">0</div></div>
  <div class="card"><div class="label">已启用</div><div class="value">0</div></div>
</div>

<div class="section">
  <h2>插件</h2>
  <div class="card">
    <div class="empty">
      <div class="ico">{ICONS["puzzle-lg"]}</div>
      <h3>还没有安装插件</h3>
      <p>插件用于聚合第三方影视数据源与扩展能力，随后续版本开放导入。</p>
    </div>
  </div>
</div>
"""
    return _admin_page("plugins", "插件管理", "管理聚合数据源插件", content)


def _system_page(request: Request) -> str:
    account = security.load_account() or {}
    created_at = account.get("created_at")
    created_text = (
        time.strftime("%Y-%m-%d %H:%M", time.localtime(created_at)) if created_at else "—"
    )
    host = request.url.hostname or "127.0.0.1"
    port = request.url.port or config.PORT
    uptime = _fmt_uptime(time.monotonic() - STARTED_AT)
    pan = pan115.snapshot()
    if not pan["bound"]:
        pan_tag, pan_cls = "未绑定", "muted"
    elif pan["status"] == "ok":
        pan_tag, pan_cls = "已绑定", "ok"
    elif pan["status"] == "invalid":
        pan_tag, pan_cls = "授权失效", "danger"
    else:
        pan_tag, pan_cls = "待检测", "muted"
    content = f"""
<div class="grid">
  <div class="card"><div class="label">服务状态</div><div class="value ok">运行中</div></div>
  <div class="card"><div class="label">运行时长</div><div class="value">{uptime}</div></div>
  <div class="card"><div class="label">监听地址</div><div class="value small">{html.escape(host)}:{port}</div></div>
  <div class="card"><div class="label">管理员账号</div><div class="value">1</div></div>
</div>

<div class="grid cols-2" style="margin-top:16px">
  <div class="card flush">
    <div class="card-head"><h2>账号</h2></div>
    <div class="row"><span class="sub">账号</span><span>{html.escape(security.account_username())}</span></div>
    <div class="row"><span class="sub">角色</span><span class="tag">管理员</span></div>
    <div class="row"><span class="sub">创建时间</span><span>{created_text}</span></div>
  </div>
  <div class="card flush">
    <div class="card-head"><h2>服务</h2></div>
    <div class="row"><span class="sub">版本</span><span>v{__version__}</span></div>
    <div class="row"><span class="sub">监听地址</span><span>{html.escape(host)}:{port}</span></div>
    <div class="row"><span class="sub">数据目录</span><span class="mono-sm">{html.escape(str(config.DATA_DIR))}</span></div>
  </div>
</div>

<div class="section">
  <h2>服务与模块</h2>
  <div class="card flush">
    <div class="row">
      <div><div class="row-title">API 服务</div><div class="sub">/api/health · 账号认证</div></div>
      <span class="tag">正常</span>
    </div>
    <div class="row">
      <div><div class="row-title">115 网盘</div><div class="sub">扫码授权后可浏览与播放</div></div>
      <span class="tag {pan_cls}">{pan_tag}</span>
    </div>
    <div class="row">
      <div><div class="row-title">插件</div><div class="sub">聚合数据源扩展</div></div>
      <span class="tag muted">0 个已启用</span>
    </div>
  </div>
</div>

<div class="section">
  <h2>快捷入口</h2>
  <div class="card flush">
    <a class="row link" href="/docs" target="_blank" rel="noopener">
      <div><div class="row-title">API 文档</div><div class="sub">Swagger UI，可在线调试接口</div></div>
      <span class="tag muted">/docs</span>
    </a>
    <a class="row link" href="/api/health" target="_blank" rel="noopener">
      <div><div class="row-title">健康检查</div><div class="sub">返回服务状态与版本</div></div>
      <span class="tag muted">/api/health</span>
    </a>
  </div>
</div>

<div class="section">
  <h2>会话</h2>
  <div class="card flush">
    <div class="row">
      <div><div class="row-title">退出当前管理台会话</div><div class="sub">清除登录 Cookie，需要重新输入密码</div></div>
      <form method="post" action="/admin/logout"><button class="ghost danger" type="submit">退出登录</button></form>
    </div>
  </div>
</div>
"""
    return _admin_page("system", "系统管理", "服务运行状态、账号与会话配置", content)


LIB_PREVIEW_SCRIPT = """
<script>
(function () {
  var EMOJI_NAMES = ["grinning-face", "red-heart", "star", "fire", "rocket", "party-popper", "artist-palette", "light-bulb", "check-mark-button", "warning", "bell", "calendar"];
  var PAGE_SIZE = 60;
  function iconifyNames(data) {
    var out = [];
    if (!data) { return out; }
    if (data.uncategorized) { out = out.concat(data.uncategorized); }
    if (data.categories) {
      for (var key in data.categories) {
        if (Object.prototype.hasOwnProperty.call(data.categories, key)) { out = out.concat(data.categories[key]); }
      }
    }
    return out;
  }
  var LIBS = [
    { match: ["hd-icons", "xushier"], label: "HD-Icons",
      manifest: "https://gcore.jsdelivr.net/gh/xushier/HD-Icons@main/icons.json",
      parse: function (data) {
        var list = Array.isArray(data) ? data : ((data && data.icons) || []);
        return list.map(function (item) { return item && item.name; }).filter(Boolean);
      },
      sample: ["115-drive-1", "baidu-drive-1", "onedrive-1", "google-drive-1", "quark-1", "alist-1", "nextcloud-1", "seafile-1", "synology-1", "truenas-1", "docker-1", "jellyfin-1"],
      url: function (name) { return "https://gcore.jsdelivr.net/gh/xushier/HD-Icons@main/border-radius/" + name + ".png"; } },
    { match: ["dashboard-icons", "homarr"], label: "Dashboard Icons",
      manifest: "https://gcore.jsdelivr.net/gh/homarr-labs/dashboard-icons@main/tree.json",
      parse: function (data) {
        return ((data && data.svg) || []).map(function (name) { return String(name).replace(/\.svg$/, ""); });
      },
      sample: ["docker", "nextcloud", "plex", "jellyfin", "synology", "truenas", "alist", "immich", "qbittorrent", "portainer", "home-assistant", "google-drive"],
      url: function (name) { return "https://gcore.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/" + name + ".svg"; } },
    { match: ["developer-icons", "xandemon"], label: "Developer Icons",
      manifest: "https://data.jsdelivr.com/v1/packages/gh/xandemon/developer-icons@main?structure=flat",
      parse: function (data) {
        return ((data && data.files) || [])
          .map(function (file) { return file && file.name; })
          .filter(function (name) { return /^\/icons\/[^\/]+\.svg$/.test(name); })
          .map(function (name) { return name.slice(7, -4); });
      },
      sample: ["docker", "python", "swift", "nodejs", "reactjs", "typescript", "go", "java", "php", "ruby", "kotlin"],
      url: function (name) { return "https://gcore.jsdelivr.net/gh/xandemon/developer-icons@main/icons/" + name + ".svg"; } },
    { match: ["flat-color-icons"], label: "Flat Color Icons",
      manifest: "https://api.iconify.design/collection?prefix=flat-color-icons",
      parse: iconifyNames,
      sample: ["home", "search", "settings", "like", "folder", "calendar", "download", "camera", "globe", "lock", "phone", "support"],
      url: function (name) { return "https://api.iconify.design/flat-color-icons/" + name + ".svg"; } },
    { match: ["fluent-emoji-flat"], label: "Fluent Emoji",
      manifest: "https://api.iconify.design/collection?prefix=fluent-emoji-flat",
      parse: iconifyNames,
      sample: EMOJI_NAMES,
      url: function (name) { return "https://api.iconify.design/fluent-emoji-flat/" + name + ".svg"; } },
    { match: ["noto"], label: "Noto Emoji",
      manifest: "https://api.iconify.design/collection?prefix=noto",
      parse: iconifyNames,
      sample: EMOJI_NAMES,
      url: function (name) { return "https://api.iconify.design/noto/" + name + ".svg"; } },
    { match: ["openmoji"], label: "OpenMoji",
      manifest: "https://api.iconify.design/collection?prefix=openmoji",
      parse: iconifyNames,
      sample: EMOJI_NAMES,
      url: function (name) { return "https://api.iconify.design/openmoji/" + name + ".svg"; } },
    { match: ["logos"], label: "Logos",
      manifest: "https://api.iconify.design/collection?prefix=logos",
      parse: iconifyNames,
      sample: ["github-icon", "google-icon", "apple", "figma", "docker-icon", "react", "swift", "vue", "python", "java", "chrome", "nodejs-icon"],
      url: function (name) { return "https://api.iconify.design/logos/" + name + ".svg"; } }
  ];
  function specFor(value) {
    var v = (value || "").toLowerCase();
    for (var i = 0; i < LIBS.length; i++) {
      var keys = LIBS[i].match;
      for (var j = 0; j < keys.length; j++) { if (v.indexOf(keys[j]) !== -1) { return LIBS[i]; } }
    }
    return null;
  }
  var modal = document.getElementById("lib-modal");
  var grid = document.getElementById("lib-grid");
  var sub = document.getElementById("lib-modal-sub");
  var searchInput = document.getElementById("lib-search");
  var moreRow = document.getElementById("lib-more-row");
  var moreBtn = document.getElementById("lib-more");
  var moreCount = document.getElementById("lib-more-count");
  var cache = {};
  var state = { spec: null, names: [], filtered: [], shown: 0, token: 0 };

  function showHint(text) {
    grid.innerHTML = "";
    var hint = document.createElement("span");
    hint.className = "muted";
    hint.textContent = text;
    grid.appendChild(hint);
  }
  function applyFilter() {
    var query = searchInput.value.trim().toLowerCase();
    state.filtered = query
      ? state.names.filter(function (name) { return name.toLowerCase().indexOf(query) !== -1; })
      : state.names.slice();
    state.shown = 0;
    grid.innerHTML = "";
    if (!state.filtered.length) {
      moreRow.hidden = true;
      showHint(state.names.length ? "没有匹配「" + searchInput.value.trim() + "」的图标" : "该图标库没有可预览的图标");
      return;
    }
    renderMore();
  }
  function renderMore() {
    var spec = state.spec;
    if (!spec) { return; }
    var end = Math.min(state.shown + PAGE_SIZE, state.filtered.length);
    var frag = document.createDocumentFragment();
    for (var i = state.shown; i < end; i++) {
      var name = state.filtered[i];
      var cell = document.createElement("div");
      cell.className = "lib-cell";
      var img = document.createElement("img");
      img.src = spec.url(name);
      img.alt = name;
      img.loading = "lazy";
      img.onerror = (function (target) { return function () { target.remove(); }; })(cell);
      var label = document.createElement("span");
      label.textContent = name;
      cell.appendChild(img);
      cell.appendChild(label);
      frag.appendChild(cell);
    }
    grid.appendChild(frag);
    state.shown = end;
    moreRow.hidden = state.shown >= state.filtered.length;
    moreCount.textContent = "共 " + state.filtered.length + " 个，已显示 " + state.shown;
  }
  function setNames(names) {
    state.names = names || [];
    applyFilter();
  }
  function openPreview(value) {
    var url = (value || "").trim();
    var spec = specFor(url);
    var token = ++state.token;
    state.spec = spec;
    state.names = [];
    state.filtered = [];
    state.shown = 0;
    searchInput.value = "";
    moreRow.hidden = true;
    grid.innerHTML = "";
    sub.textContent = spec ? spec.label + " · " + (url || "未填写地址") : (url || "未填写地址");
    modal.classList.add("open");
    if (!spec) {
      showHint(url ? "该图标库暂不支持预览，地址仍会正常保存" : "请先填写图标库地址");
      return;
    }
    if (cache[spec.label]) { setNames(cache[spec.label]); return; }
    if (!spec.manifest) { setNames(spec.sample); return; }
    showHint("正在读取图标列表…");
    fetch(spec.manifest)
      .then(function (response) {
        if (!response.ok) { throw new Error("HTTP " + response.status); }
        return response.json();
      })
      .then(function (data) {
        var names = spec.parse(data);
        if (!names.length) { throw new Error("empty"); }
        cache[spec.label] = names;
        if (token === state.token) { setNames(names); }
      })
      .catch(function () {
        if (token === state.token) { setNames(spec.sample || []); }
      });
  }
  function closePreview() {
    state.token++;
    modal.classList.remove("open");
    grid.innerHTML = "";
    moreRow.hidden = true;
  }
  searchInput.addEventListener("input", function () {
    if (!state.spec) { return; }
    applyFilter();
  });
  moreBtn.addEventListener("click", renderMore);
  modal.addEventListener("click", function (e) {
    if (e.target.hasAttribute("data-close")) { closePreview(); }
  });
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && modal.classList.contains("open")) { closePreview(); }
  });
  function updateCount() {
    document.getElementById("lib-count").textContent =
      document.querySelectorAll("#lib-list .lib-row").length + " 个";
  }
  function bindRow(row) {
    row.querySelector(".lib-preview-btn").addEventListener("click", function () {
      openPreview(row.querySelector(".lib-url").value);
    });
    row.querySelector(".lib-del").addEventListener("click", function () { row.remove(); updateCount(); });
  }
  function createRow(value) {
    var row = document.createElement("div");
    row.className = "lib-row";
    row.innerHTML = '<div class="lib-main"><input class="lib-url" name="urls" spellcheck="false"></div><div class="lib-actions"><button class="lib-preview-btn" type="button">预览</button><button class="lib-del" type="button" aria-label="删除">×</button></div>';
    row.querySelector(".lib-url").value = value || "";
    bindRow(row);
    return row;
  }
  var list = document.getElementById("lib-list");
  Array.prototype.forEach.call(list.querySelectorAll(".lib-row"), bindRow);
  var newInput = document.getElementById("lib-new");
  function add() {
    var value = newInput.value.trim();
    if (!value) { newInput.focus(); return; }
    list.appendChild(createRow(value));
    newInput.value = "";
    updateCount();
  }
  document.getElementById("lib-add").addEventListener("click", add);
  newInput.addEventListener("keydown", function (e) { if (e.key === "Enter") { e.preventDefault(); add(); } });
})();
</script>
"""


def _appearance_page(request: Request) -> str:
    urls = appearance_store.icon_libraries()
    saved = request.query_params.get("saved") == "1"
    error = (request.query_params.get("error") or "").strip()
    if saved:
        notice = '<div class="notice ok">已保存，App 端会自动同步。</div>'
    elif error:
        notice = f'<div class="notice err">{html.escape(error)}</div>'
    else:
        notice = ""
    rows = "".join(
        '<div class="lib-row"><div class="lib-main">'
        f'<input class="lib-url" name="urls" spellcheck="false" value="{html.escape(url, quote=True)}">'
        '</div><div class="lib-actions">'
        '<button class="lib-preview-btn" type="button">预览</button>'
        '<button class="lib-del" type="button" aria-label="删除">×</button>'
        '</div></div>'
        for url in urls
    )
    content = f"""
<div class="section">
  <h2>图标库</h2>
  <div class="card flush">
    <form class="lib-form" method="post" action="/admin/appearance">
      {notice}
      <div class="lib-head">
        <div>
          <div class="row-title">在线图标库</div>
          <div class="sub">一行一个 http/https 链接，最多 {appearance_store.MAX_ICON_LIBRARIES} 个；留空表示不使用在线图标库。点右侧「预览」可搜索并分页浏览该库的全部图标。</div>
        </div>
        <span class="tag" id="lib-count">{len(urls)} 个</span>
      </div>
      <div id="lib-list">{rows}</div>
      <div class="lib-add">
        <input id="lib-new" placeholder="https://github.com/xushier/HD-Icons" autocomplete="off">
        <button class="ghost" type="button" id="lib-add">添加</button>
      </div>
      <div class="form-foot">
        <button class="ghost solid" type="submit">保存配置</button>
        <span class="sub" style="margin:0">保存后 App 端「设置 → 外观 → 图标库」自动同步。</span>
      </div>
    </form>
  </div>
</div>
<div class="modal" id="lib-modal">
  <div class="modal-mask" data-close></div>
  <div class="modal-panel">
    <div class="modal-head">
      <h3>图标预览</h3>
      <button class="modal-x" type="button" data-close aria-label="关闭">×</button>
    </div>
    <div class="lib-tools">
      <input id="lib-search" placeholder="搜索图标名，如 drive / docker / nas" autocomplete="off" spellcheck="false">
      <span class="sub" id="lib-modal-sub"></span>
    </div>
    <div class="lib-grid" id="lib-grid"></div>
    <div class="lib-more" id="lib-more-row" hidden>
      <span class="sub" id="lib-more-count"></span>
      <button class="ghost" type="button" id="lib-more">加载更多</button>
    </div>
  </div>
</div>
{LIB_PREVIEW_SCRIPT}
"""
    return _admin_page("appearance", "外观设置", "图标库等外观配置由服务端统一维护，App 端同步读取", content)


def _page_response(request: Request, builder) -> Response:
    if not security.has_account():
        return HTMLResponse(_setup_page())
    if not _is_authenticated(request):
        return HTMLResponse(_login_page())
    return HTMLResponse(builder())


async def _async_page_response(request: Request, builder) -> Response:
    if not security.has_account():
        return HTMLResponse(_setup_page())
    if not _is_authenticated(request):
        return HTMLResponse(_login_page())
    return HTMLResponse(await builder())


def _session_response(username: str) -> Response:
    token, ttl = security.issue_token(username, scope="admin")
    response = RedirectResponse("/admin", status_code=303)
    response.set_cookie(
        COOKIE_NAME,
        token,
        max_age=ttl,
        path="/",
        httponly=True,
        samesite="lax",
        secure=config.COOKIE_SECURE,
    )
    return response


@router.get("", response_class=HTMLResponse)
async def admin_home(request: Request) -> Response:
    return _page_response(request, lambda: _service_page(request))


@router.get("/search", response_class=HTMLResponse)
async def admin_search(request: Request, q: str = "") -> Response:
    selected = request.query_params.getlist("svc")
    return await _async_page_response(
        request, lambda: _search_page(q.strip()[:120], selected)
    )


@router.get("/api/search")
async def admin_search_more(
    request: Request, q: str = "", svc: str = "", offset: int = 0
) -> Response:
    """搜索分页：按服务返回接下来的一页资源行（HTML 片段）。"""

    if not _is_authenticated(request):
        return JSONResponse({"ok": False, "message": "登录已过期，请重新登录"}, status_code=401)
    keyword = q.strip()[:120]
    if not keyword or not svc:
        return JSONResponse({"ok": False, "message": "缺少搜索参数"}, status_code=400)
    items = [item for item in services_store.list_services() if item.get("id") == svc]
    if not items:
        return JSONResponse({"ok": False, "message": "服务不存在"}, status_code=404)
    offset = max(0, offset)
    item, rows, error, has_more = (
        await resource_search.search(items, keyword, offset=offset)
    )[0]
    if error:
        return JSONResponse({"ok": False, "message": error}, status_code=502)
    return JSONResponse(
        {
            "ok": True,
            "html": "".join(_result_row(row) for row in rows),
            "shown": offset + len(rows),
            "has_more": has_more,
        }
    )


@router.get("/service", response_class=HTMLResponse)
async def admin_service(request: Request) -> Response:
    return _page_response(request, lambda: _service_page(request))


@router.post("/service/save")
async def admin_service_save(request: Request) -> Response:
    if not _is_authenticated(request):
        return JSONResponse({"ok": False, "message": "登录已过期，请重新登录"}, status_code=401)
    try:
        payload = await request.json()
    except Exception:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    try:
        data = await asyncio.to_thread(services_store.save_service, payload)
    except ValueError as exc:
        return JSONResponse({"ok": False, "message": str(exc)}, status_code=400)
    return JSONResponse(data)


@router.post("/service/{sid}/delete")
async def admin_service_delete(request: Request, sid: str) -> Response:
    if not _is_authenticated(request):
        return JSONResponse({"ok": False, "message": "登录已过期，请重新登录"}, status_code=401)
    removed = await asyncio.to_thread(services_store.delete_service, sid)
    if not removed:
        return JSONResponse({"ok": False, "message": "服务不存在或已删除"}, status_code=404)
    return JSONResponse({"ok": True})


@router.get("/service/docker")
async def admin_service_docker(request: Request) -> Response:
    if not _is_authenticated(request):
        return JSONResponse({"ok": False, "message": "登录已过期，请重新登录"}, status_code=401)
    data = await asyncio.to_thread(docker_svc.containers, True)
    return JSONResponse(data)


@router.post("/service/docker/{container_id}/{action}")
async def admin_service_docker_action(
    request: Request, container_id: str, action: str
) -> Response:
    if not _is_authenticated(request):
        return JSONResponse({"ok": False, "message": "登录已过期，请重新登录"}, status_code=401)
    try:
        data = await asyncio.to_thread(docker_svc.act, container_id, action)
    except docker_svc.DockerError as exc:
        return JSONResponse({"ok": False, "message": str(exc)}, status_code=400)
    return JSONResponse(data)


@router.get("/drive", response_class=HTMLResponse)
async def admin_drive(request: Request) -> Response:
    return _page_response(request, _drive_page)


@router.post("/drive/qr")
async def admin_drive_qr(request: Request) -> Response:
    if not _is_authenticated(request):
        return JSONResponse({"ok": False, "message": "登录已过期，请重新登录"}, status_code=401)
    try:
        payload = await request.json()
    except Exception:
        payload = {}
    app = payload.get("app") if isinstance(payload, dict) else ""
    try:
        data = await pan115.create_qr(app if isinstance(app, str) else pan115.DEFAULT_APP)
    except Exception as exc:
        return JSONResponse({"ok": False, "message": str(exc)}, status_code=502)
    return JSONResponse({"ok": True, **data})


@router.get("/drive/qr/status")
async def admin_drive_qr_status(request: Request, uid: str = "") -> Response:
    if not _is_authenticated(request):
        return JSONResponse({"ok": False, "message": "登录已过期"}, status_code=401)
    return JSONResponse(pan115.qr_status(uid))


@router.post("/drive/cookie")
async def admin_drive_cookie(request: Request) -> Response:
    if not _is_authenticated(request):
        return JSONResponse({"ok": False, "message": "登录已过期"}, status_code=401)
    try:
        payload = await request.json()
    except Exception:
        payload = {}
    raw = payload.get("cookie") if isinstance(payload, dict) else ""
    try:
        result = await asyncio.to_thread(pan115.bind_cookie, raw or "")
    except pan115.Pan115Error as exc:
        return JSONResponse({"ok": False, "message": str(exc)}, status_code=400)
    except Exception as exc:
        return JSONResponse({"ok": False, "message": f"绑定失败：{exc}"}, status_code=502)
    return JSONResponse({"ok": True, **result})


@router.post("/drive/check")
async def admin_drive_check(request: Request) -> Response:
    if not _is_authenticated(request):
        return JSONResponse({"ok": False, "message": "登录已过期"}, status_code=401)
    result = await asyncio.to_thread(pan115.check, True)
    return JSONResponse({"ok": True, **result})


@router.post("/drive/unbind")
async def admin_drive_unbind(request: Request) -> Response:
    if not _is_authenticated(request):
        return JSONResponse({"ok": False, "message": "登录已过期"}, status_code=401)
    pan115.unbind()
    return JSONResponse({"ok": True})


@router.get("/plugins", response_class=HTMLResponse)
async def admin_plugins(request: Request) -> Response:
    return _page_response(request, _plugins_page)


@router.get("/system", response_class=HTMLResponse)
async def admin_system(request: Request) -> Response:
    return _page_response(request, lambda: _system_page(request))


@router.get("/appearance", response_class=HTMLResponse)
async def admin_appearance(request: Request) -> Response:
    return _page_response(request, lambda: _appearance_page(request))


@router.post("/appearance")
async def admin_appearance_save(request: Request) -> Response:
    if not _is_authenticated(request):
        return RedirectResponse("/admin", status_code=303)
    form = await request.form()
    urls = [str(value).strip() for value in form.getlist("urls") if str(value).strip()]
    try:
        appearance_store.save_icon_libraries(urls)
    except ValueError as exc:
        return RedirectResponse(f"/admin/appearance?error={quote(str(exc))}", status_code=303)
    return RedirectResponse("/admin/appearance?saved=1", status_code=303)


@router.post("/setup")
async def admin_setup(
    username: str = Form(...), password: str = Form(...), confirm: str = Form(...)
) -> Response:
    if security.has_account():
        return RedirectResponse("/admin", status_code=303)

    username = username.strip()
    if len(username) < 3 or " " in username:
        return HTMLResponse(_setup_page("账号需 3 个字符以上且不含空格"), status_code=400)
    if len(password) < 8:
        return HTMLResponse(_setup_page("密码至少 8 位"), status_code=400)
    if password != confirm:
        return HTMLResponse(_setup_page("两次输入的密码不一致"), status_code=400)

    security.create_account(username, password)
    return _session_response(username)


@router.post("/login")
async def admin_login(request: Request, username: str = Form(...), password: str = Form(...)) -> Response:
    if not security.has_account():
        return RedirectResponse("/admin", status_code=303)

    client_ip = request.client.host if request.client else "unknown"
    throttle_key = f"admin:{client_ip}:{username}"
    locked = security.login_locked_for(throttle_key)
    if locked:
        return HTMLResponse(
            _login_page(f"登录失败次数过多，请 {locked} 秒后再试"), status_code=429
        )

    if not security.verify_credentials(username, password):
        security.record_login_failure(throttle_key)
        return HTMLResponse(_login_page("账号或密码错误"), status_code=401)

    security.clear_login_failures(throttle_key)
    return _session_response(username)


@router.post("/logout")
async def admin_logout() -> RedirectResponse:
    response = RedirectResponse("/admin", status_code=303)
    response.delete_cookie(COOKIE_NAME, path="/")
    return response
