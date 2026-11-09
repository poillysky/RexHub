# `data/` — 本机运行时（默认不进 git）

按用途分层；真相源映射在 `maps/`，片库在 `media/`。

```
data/
  meta.db               # SQLite 元库：账号 / 会话 / 设置 / 种子文件缓存
  rexhub/               # 原 RexHub Server 的 JSON 存储（已迁入）
    account.json        # 管理台/App 账号
    secret.key          # Bearer token 签名密钥
    plugins.json        # 已安装的 ForwardWidget 插件
    addons.json         # Stremio 插件缓存
    services.json       # 资源服务配置
    network.json        # 网络/代理设置
    progress.json       # 播放进度
    widgets/            # 插件源码副本（按 id）
    p115cache/          # 115 网盘缓存
  meta/                 # cf-clearance 等会话态
  prefix/
    catalog/            # 七区前缀→番号目录（catalog.json）
    code-ranges.json    # 前缀流水号上限缓存
  presets/              # 本机预设（如 openai）
  debug/                # 脚本报告 / 探针输出
```

`data/rexhub/` 的路径可用环境变量 `REXHUB_DATA_DIR` 覆盖（默认 `<仓库根>/data/rexhub`）。

从 MDCX 导入演员/标签/标题（写入 `maps/scrape/`，不是这里）：

```bash
cd api && .venv/bin/python scripts/build_actor_map_from_mdcx.py
```

片库见 [`media/README.md`](../media/README.md)；约定见 [`docs/backend/local-runtime.md`](../docs/backend/local-runtime.md)。
