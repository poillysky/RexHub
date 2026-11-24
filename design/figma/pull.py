#!/usr/bin/env python3
"""把 Figma 文件拉到本地：结构 JSON + 画板截图。

只用标准库，不需要装依赖。走 Figma REST API，免费版账号同样可用
（Dev Mode MCP 需要付费，REST API 不需要）。

用法：
  python3 design/figma/pull.py <文件链接或 key>              # 拉结构并打印画板清单
  python3 design/figma/pull.py <链接> --depth 6              # 指定遍历深度（默认 4）
  python3 design/figma/pull.py <链接> --render 1-2,3-4       # 渲染指定画板为 PNG
  python3 design/figma/pull.py <链接> --render-all           # 渲染全部顶层画板
  python3 design/figma/pull.py <链接> --node 1-2             # 只拉某个子树

Token 读取顺序：
  1. 环境变量 FIGMA_TOKEN
  2. ~/.config/rexhub/figma_token
  3. 同目录 figma_token（已在 .gitignore 里）

产物落在 design/figma/out/：<key>.json 与 png/<画板名>.png
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://api.figma.com/v1"
HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
TOKEN_FILES = [Path.home() / ".config" / "rexhub" / "figma_token", HERE / "figma_token"]

TOKEN_HELP = """没有找到 Figma token。两种方式二选一：

A. 存到文件（推荐，一次搞定）
   mkdir -p ~/.config/rexhub
   echo '你的token' > ~/.config/rexhub/figma_token
   chmod 600 ~/.config/rexhub/figma_token

B. 临时塞进环境变量
   export FIGMA_TOKEN=你的token

token 在 Figma 桌面版生成：左上角头像 → Settings → Security →
Personal access tokens → Generate new token，权限勾 File content 的 Read only。"""


def parse_key(target: str) -> str:
    """从链接或裸 key 里取出文件 key。"""
    m = re.search(r"/(?:file|design|board|proto)/([A-Za-z0-9]{10,})", target)
    if m:
        return m.group(1)
    if re.fullmatch(r"[A-Za-z0-9]{10,}", target):
        return target
    sys.exit(f"看不懂这个链接或 key：{target}")


def parse_nodes(target: str) -> list[str]:
    """从链接里取出 node-id，1-2 统一转成 1:2。"""
    q = urllib.parse.urlparse(target).query
    raw = urllib.parse.parse_qs(q).get("node-id", [])
    return [n.replace("-", ":") for n in raw]


def read_token() -> str:
    tok = os.environ.get("FIGMA_TOKEN", "").strip()
    if tok:
        return tok
    for path in TOKEN_FILES:
        try:
            tok = path.read_text(encoding="utf-8").strip()
            if tok:
                return tok
        except OSError:
            continue
    sys.exit(TOKEN_HELP)


def open_with_retry(req: urllib.request.Request, timeout: int, attempts: int = 3):
    """TLS 偶发中断（EOF occurred in violation of protocol）重试几次再放弃。"""
    last = None
    for i in range(attempts):
        try:
            return urllib.request.urlopen(req, timeout=timeout)
        except urllib.error.HTTPError:
            raise
        except (urllib.error.URLError, OSError) as exc:
            last = exc
            if i < attempts - 1:
                time.sleep(1.5 * (i + 1))
    raise last


def get(path: str, params: dict | None = None, token: str = "") -> dict:
    url = f"{API}{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"X-Figma-Token": token})
    try:
        with open_with_retry(req, 90) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")[:400]
        sys.exit(f"请求失败（HTTP {exc.code}）：{body}")
    except urllib.error.URLError as exc:
        sys.exit(f"网络不通：{exc.reason}")


def download(url: str, dest: Path) -> int:
    req = urllib.request.Request(url)
    with open_with_retry(req, 180) as resp:
        data = resp.read()
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(data)
    return len(data)


def safe_name(name: str) -> str:
    name = re.sub(r"[\\/:*?\"<>|]+", "_", name).strip() or "frame"
    return name[:60]


def walk(node: dict, depth: int, max_depth: int, acc: list, level: int = 0) -> None:
    """按层级收集画板/组件，用于打印清单。"""
    acc.append((level, node))
    if level >= max_depth:
        return
    for child in node.get("children", []) or []:
        walk(child, depth, max_depth, acc, level + 1)


def summarize(doc: dict, max_depth: int = 3) -> None:
    rows: list[tuple[int, dict]] = []
    walk(doc, 0, max_depth, rows)
    for level, node in rows:
        if node is doc and level == 0:
            print(f"文件：{doc.get('name')}  修改于 {doc.get('lastModified', '')[:19]}")
            print()
            continue
        kind = node.get("type", "?")
        if kind not in {"PAGE", "FRAME", "COMPONENT", "COMPONENT_SET", "SECTION", "INSTANCE"}:
            continue
        box = node.get("absoluteBoundingBox") or {}
        size = ""
        if box:
            size = f"  {int(box.get('width', 0))}×{int(box.get('height', 0))}"
        indent = "  " * level
        print(f"{indent}{kind:<13} {node.get('name', '')}{size}   [{node.get('id')}]")


def main() -> None:
    ap = argparse.ArgumentParser(description="拉取 Figma 文件结构与画板截图")
    ap.add_argument("target", help="Figma 文件链接或 file key")
    ap.add_argument("--depth", type=int, default=4, help="遍历深度，默认 4")
    ap.add_argument("--node", action="append", default=[], help="只拉指定节点，可重复")
    ap.add_argument("--render", default="", help="渲染指定节点，逗号分隔，如 1-2,3-4")
    ap.add_argument("--render-all", action="store_true", help="渲染全部顶层画板")
    ap.add_argument("--scale", type=float, default=2.0, help="导出倍数，默认 2")
    ap.add_argument("--format", default="png", choices=["png", "jpg", "svg"], help="导出格式")
    ap.add_argument("--quiet", action="store_true", help="不打印画板清单")
    args = ap.parse_args()

    token = read_token()
    key = parse_key(args.target)
    node_ids = parse_nodes(args.target) + [n.replace("-", ":") for n in args.node]

    OUT.mkdir(parents=True, exist_ok=True)

    if node_ids:
        data = get(f"/files/{key}/nodes", {"ids": ",".join(node_ids), "depth": args.depth}, token)
        payload = {"nodes": data.get("nodes", {})}
    else:
        payload = get(f"/files/{key}", {"depth": args.depth}, token)

    stamp = time.strftime("%Y%m%d-%H%M%S")
    json_path = OUT / f"{key}-{stamp}.json"
    json_path.write_text(json.dumps(payload, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"结构已存：{json_path}")

    doc = payload.get("document") or next(
        (n.get("document") for n in payload.get("nodes", {}).values() if n), None
    )
    if doc and not args.quiet:
        print()
        summarize(doc, max_depth=3)

    targets: list[str] = []
    if args.render:
        targets = [t.strip().replace("-", ":") for t in args.render.split(",") if t.strip()]
    elif args.render_all and doc:
        targets = [
            c["id"]
            for page in doc.get("children", [])
            for c in page.get("children", [])
            if c.get("type") in {"FRAME", "COMPONENT", "SECTION"}
        ]

    if not targets:
        return

    print()
    images = get(
        f"/images/{key}",
        {"ids": ",".join(targets), "format": args.format, "scale": args.scale},
        token,
    ).get("images", {})

    names = {}
    if doc:
        stack = [doc]
        while stack:
            cur = stack.pop()
            names[cur.get("id")] = cur.get("name", "")
            stack.extend(cur.get("children", []) or [])

    for nid, url in images.items():
        if not url:
            print(f"跳过 {nid}：Figma 没有返回图片（节点可能为空或不可见）")
            continue
        dest = OUT / "png" / f"{safe_name(names.get(nid, nid))}-{nid.replace(':', '-')}.{args.format}"
        size = download(url, dest)
        print(f"已渲染：{dest.name}  {size // 1024} KB")

    print(f"\n产物目录：{OUT}")


if __name__ == "__main__":
    main()
