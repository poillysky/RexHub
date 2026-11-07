"""扫库 SQL 执行器与公共 SQL 片段。

统一走 SET LOCAL statement_timeout（前台/构建两档超时），
并集中维护 meta lateral（同 hash 多源的中文优先挑选）与行选列。
"""

from typing import Any

import app.core.pg as pg

from .params import PREFIX_SOURCES_PER_HASH, _active_scan_timeout


def _query_prefix_scan(sql: str, params: list[Any]) -> list[dict[str, Any]]:
    pool = pg.get_pool()
    timeout = _active_scan_timeout()
    with pool.connection() as conn:
        with conn.cursor() as cur:
            cur.execute("BEGIN")
            try:
                cur.execute(f"SET LOCAL statement_timeout = '{timeout}'")
                cur.execute(sql, params)
                rows = list(cur.fetchall()) if cur.description else []
                cur.execute("COMMIT")
                return rows
            except Exception:
                try:
                    cur.execute("ROLLBACK")
                except Exception:
                    pass
                raise


# 中文（含影片名称且无假名）硬优先，再影片名称/女优/单链/多图
_PREFIX_META_LATERAL = f"""
LEFT JOIN LATERAL (
  SELECT title, description, preview_images, board_fid, board_name, ed2k_links
  FROM resource_sources
  WHERE hash = r.hash
  ORDER BY
    CASE
      WHEN (description ILIKE '%%影片名称%%' OR description ILIKE '%%影片名稱%%')
        AND description ~ '[一-龥]'
        AND description !~ '[ぁ-んァ-ン]' THEN 0
      WHEN title ~ '[一-龥]' AND title !~ '[ぁ-んァ-ン]' THEN 1
      WHEN description ILIKE '%%影片名称%%'
        OR description ILIKE '%%影片名稱%%' THEN 2
      ELSE 3
    END,
    CASE
      WHEN description ILIKE '%%出演女优%%'
        OR description ILIKE '%%出演女優%%' THEN 0
      ELSE 1
    END,
    CASE WHEN coalesce(array_length(ed2k_links, 1), 0) <= 1 THEN 0 ELSE 1 END,
    coalesce(array_length(preview_images, 1), 0) DESC,
    created_at DESC
  LIMIT {int(PREFIX_SOURCES_PER_HASH)}
) rs ON true
"""

# 前缀扫库统一选出：含 hash / ed2k，便于合集只认本资源子文件
_PREFIX_ROW_SELECT = """
  r.hash,
  r.filename,
  r.created_at,
  rs.title,
  rs.description,
  rs.preview_images,
  rs.board_fid,
  rs.board_name,
  rs.ed2k_links
"""
