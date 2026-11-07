# 目录结构约定

## 总览（合理）

```
RexHub/
├── server/                  # NAS 部署单元 = Docker 构建上下文
│   ├── maps/                # 映射种子（唯一进 git 的 JSON 表）
│   ├── web/                 # Next.js PWA :3020
│   ├── api/                 # FastAPI :8787（容器内 8020）
│   │   ├── app/             # 业务（按域分包）
│   │   │   ├── main.py
│   │   │   ├── core/ auth/ ai/ p115/ prefix/
│   │   │   └── rexhub/ search/ translate/
│   │   ├── scripts/         # 运维脚本（进 git；legacy/ 归档旧脚本）
│   │   └── _local_refs/     # 本机参考（不进 git）· mdcx/
│   ├── config/              # app.json · app.local* · sql/ 参考 DDL
│   ├── data/                # 运行时缓存 / 映射覆盖（见 data/README）
│   ├── docker/              # 镜像内脚本；Dockerfile/compose 在 server 根
│   ├── backups/             # 本机备份：db/ + workspace/（勿提交）
│   └── Dockerfile · docker-compose.yml · package.json
├── ios/                     # SwiftUI 工程
├── docs/
└── README.md
```

程序里的 `ROOT` = `server/`（部署根）。  
**映射种子** → `server/maps/{makers,prefixes,scrape,regions,sites}/`；**运行时覆盖** → `server/data/`。

| 目录 | 说明 |
|--------|------|
| `server/config/` | 默认 settings + 本机覆盖；`sql/` 仅参考，见 [`server/config/README.md`](../../server/config/README.md) |
| `server/docker/` | supervisord / entrypoint；构建入口在 `server/`，见 [`server/docker/README.md`](../../server/docker/README.md) |
| `server/backups/` | `db/` 库导出 · `workspace/` 整理归档 |
| `.agents` / `.refs` / `.workbuddy` | 本机工具（gitignore，不整理） |
## `server/maps`（映射种子）

见 [`server/maps/README.md`](../../server/maps/README.md)、[scrape-maps.md](./scrape-maps.md)。

## `server/api/app` 分包

| 包 | 内容 |
|----|------|
| `core/` | db · maps_paths · pg · bootstrap · settings · http · region … |
| `auth/` | 登录鉴权 |
| `ai/` | 助手 / 对话 / 嵌入配置 |
| `p115/` | 115 网盘 |
| `prefix/` | 前缀目录 / harvest |
| `rexhub/` | 资源搜索数据源（含外部 Postgres 库接入） |
| `search/` | 资源搜索 · sehua/bitmagnet · 收藏 · 论坛 |
| `translate/` | 翻译 |

入口仍为 [`server/api/app/main.py`](../../server/api/app/main.py)。

## 进 git / 不进 git

**进 git**：`server/**`（含 `server/maps/` 演员/繁简折叠/番号形状表）、脚本、`docs/**`、`server/config/app.json`、根 README / Docker。

**不进 git**：`server/data/prefix/`、`server/data/cache/`、`server/data/mirrors/`、`server/data/meta/`、`server/data/debug/`、`server/api/_local_refs/`、`server/api/_gap_reports/`、`server/data/`（禁止再出现根级 `data/`）、`server/backups/` 等。  
（已废弃：`data/scrape_maps/` 演员·标签·标题双份；旧扁平名 `prefix_catalog` / `cover-cache` / `scrap_facets_snap` / `_debug`。）

## 禁止

- 不要在仓库外路径批量整理/删除
- 不要删 `media/`、`data/meta`、`data/prefix/catalog`、Postgres
- 不要把探针结果再塞回 `server/api/app/`
- 不要在多处复制同名映射 JSON

## `server/web`

```
src/app · features/ · components/ · shell/ · lib/
```

按 Tab/业务域分包。主要负担是超大 `app-ui.css`。

**包管理器：只用 npm**（与根 `start-dev.ps1`、CI `npm ci` 一致）。  
保留 `package-lock.json`，不要再生成 `pnpm-lock.yaml`。若本地 `node_modules` 里仍有 `.pnpm/`，在 `server/web` 下删掉 `node_modules` 后执行 `npm ci` 重装。

共享映射 JSON 由 `npm run sync-maps`（`predev`/`prebuild`）从 `server/maps` 复制到 `server/web/maps/`（gitignore，Turbopack 可读）。

## `server/api` 临时文件

- 运维/一次性脚本：常用留在 `server/api/scripts/`，历史脚本在 `server/api/scripts/legacy/`
- 探针与临时烟测（`_tmp_*.py`、`_gap_reports/`）勿放在 `server/api/` 包根；本机用完即删，或放 gitignore 的 `_local_refs/`
