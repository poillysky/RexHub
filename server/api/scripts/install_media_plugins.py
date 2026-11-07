"""安装 / 更新三个媒体插件源码到 data/plugins.json。

用法：api/.venv/bin/python api/scripts/install_media_plugins.py

- 读取 api/plugins_src/ 下的 rexhub.tmdb.js / rexhub.douban.js / rexhub.bangumi.js，
  经 plugins_store.save_plugin 幂等 upsert（按插件 id 覆盖源码与解析结果）；
- 分类统一为 video；管理台已填写的 api_key / api_url / 代理等配置原样保留；
- 结束后打印各插件的 id 与 modules 数。
"""

from __future__ import annotations

import sys
from pathlib import Path

APP_DIR = Path(__file__).resolve().parents[1]
if str(APP_DIR) not in sys.path:
    sys.path.insert(0, str(APP_DIR))

from app.rexhub import plugins_store  # noqa: E402

PLUGINS = [
    ("rexhub.tmdb.js", "video"),
    ("rexhub.douban.js", "video"),
    ("rexhub.bangumi.js", "video"),
]


def main() -> int:
    src_dir = APP_DIR / "plugins_src"
    for filename, category in PLUGINS:
        path = src_dir / filename
        try:
            source = path.read_text("utf-8")
        except OSError as exc:
            print(f"[install] 读取 {path} 失败：{exc}", file=sys.stderr)
            return 1
        result = plugins_store.save_plugin(source, category=category)
        print(
            f"[install] {result['id']} 已{'新建' if result['created'] else '更新'}"
            f"（title={result['title']}）"
        )

    print("[install] 当前插件清单（id / modules / category / enabled）：")
    for row in plugins_store.snapshot()["plugins"]:
        print(
            f"  - {row['id']}: modules={row.get('modules')} "
            f"category={row.get('category')} enabled={row.get('enabled')}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
