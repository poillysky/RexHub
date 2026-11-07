# maps — 映射表（按目录分类，各表唯一一份）

```
maps/
  makers/     av-makers 厂牌前缀注册表
  prefixes/   番号形状 / 流水号 / code-read
  scrape/     演员 · 繁简折叠
  regions/    七区元数据
  sites/      色花堂论坛板块树
```

逻辑名由 `app.core.maps_paths.maps_seed(...)` 解析到子目录。

## 目录说明

| 目录 | 文件 | 用途 |
|------|------|------|
| `makers/` | `av-makers.{japan,china,western}.json` | 厂牌前缀注册 |
| `prefixes/` | `code-ranges.json` | 流水号上限种子 |
| | `code-shapes.json` | 番号形状 / 欧美前缀 / skip |
| | `code-read.json` | 扫描 code_read 预设 |
| `scrape/` | `actors.zh-CN.json` | 演员完整表（MDCX 导入；人工也改这张；条目可带 `avatar` 直链） |
| | `tags.variant-fold.zh-CN.json` | 繁简折叠 |
| `regions/` | `regions.json` | 七区 order / meta / aliases |
| `sites/` | `sehuatang-forum.json` | 色花堂论坛板块树 |

**不要**再维护 `data/scrape_maps/` 副本；运行时只读 `maps/`。

## 从 MDCX 导入演员表

源在 `api/_local_refs/mdcx/`（不进 git）：

```bash
cd server/api
.venv/bin/python scripts/build_actor_map_from_mdcx.py
```

直接写回 `maps/scrape/actors.zh-CN.json`。

人工字段（当前为 `avatar` 头像直链）在重导时按**标准名**自动保留，不会被覆盖。

运行时其它覆盖：`data/prefix/code-ranges.json`、`data/prefix/catalog/`。
