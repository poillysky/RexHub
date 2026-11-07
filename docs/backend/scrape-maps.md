# 映射表约定

- **唯一位置**：[`server/maps/`](../../server/maps/README.md)（演员 / 繁简折叠都在 `scrape/`）
- **禁止**再搞 `data/scrape_maps/` 兜底副本
- 逻辑名：`app.core.maps_paths.maps_seed(...)` / `load_json_map(...)`
- 前缀目录等其它运行时：`server/data/prefix/`（`catalog/`、`code-ranges.json`）

## MDCX 演员表

```bash
cd server/api
.venv/bin/python scripts/build_actor_map_from_mdcx.py
```

| 产物 | 路径 |
|------|------|
| 演员 | `server/maps/scrape/actors.zh-CN.json` |

人工修正直接改 `actors.zh-CN.json`（只维护主表）。
