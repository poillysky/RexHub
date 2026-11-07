-- 色花资源库搜索加速（在资源库 Postgres 上执行一次）
-- 解决：SONS / SSIS 等短前缀在「时间=不限」时 ILIKE 全表扫极慢
--
-- 用法（局域网 DSN 对应库）:
--   psql "$DSN" -f config/sql/search_indexes.sql

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- filename / title 模糊匹配
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ed2k_resources_filename_trgm
  ON ed2k_resources USING gin (filename gin_trgm_ops);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_resource_sources_title_trgm
  ON resource_sources USING gin (title gin_trgm_ops);

-- 中文检索：本库 lc_ctype=C，pg_trgm 对中文提不出三元组（similarity 恒 0），
-- 中文 ILIKE 只能全表扫（74 万行 ~1.2s/次）。
-- 改为对连续中文取二元组数组建 GIN，查询用 `@>` 精确命中索引。
-- 正则里避免直接写中文（该连接执行含中文的 SQL 文本会解析失败），用 chr() 拼区间。
CREATE OR REPLACE FUNCTION cjk_bigrams(txt text)
RETURNS text[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $fn$
  WITH s AS (
    SELECT regexp_replace(txt, '[^' || chr(19968) || '-' || chr(40959) || ']', '', 'g') AS t
  )
  SELECT COALESCE(array_agg(DISTINCT substr(t, i, 2)), '{}'::text[])
  FROM s, generate_series(1, greatest(char_length(t) - 1, 0)) AS i
$fn$;

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ed2k_filename_cjk_bigrams
  ON ed2k_resources USING gin (cjk_bigrams(filename));

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_resource_sources_title_cjk_bigrams
  ON resource_sources USING gin (cjk_bigrams(title));

-- 中文正文命中：search_string 已含文件名+标题+正文，一次定位所有中文匹配
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ed2k_search_string_cjk_bigrams
  ON ed2k_resources USING gin (cjk_bigrams(search_string));

-- 默认排序：按时间倒序取最新
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ed2k_resources_created_at_desc
  ON ed2k_resources (created_at DESC);
