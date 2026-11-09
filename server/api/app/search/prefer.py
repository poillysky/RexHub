"""Prefer Chinese / crack SQL — port of sehua-search chinesePrefer / crackPrefer predicates.

四国板 fid 白名单（region）故意不进 SQL：由 search_resources 在 AV/Bitmagnet
快路径取数后做应用层过滤，避免关掉快路径并触发大量 board_fid OR/LIKE。
"""


SEARCH_NAME_EXPR = (
    "(COALESCE(r.filename, '') || E'\\n' || COALESCE(rs.title, ''))"
)


def chinese_prefer_predicate_sql() -> str:
    return f"""(
    COALESCE(rs.board_name, '') LIKE '%%高清中文字幕%%'
    OR COALESCE(rs.board_fid, '') = '103'
    OR COALESCE(rs.board_fid, '') LIKE '103:%%'
    OR {SEARCH_NAME_EXPR} ~* '-[0-9]{{2,6}}(CX|C)([._[:space:]-]|$)'
    OR r.filename ILIKE '%%-C%%'
    OR COALESCE(rs.title, '') ILIKE '%%-C%%'
    OR (
      (
        r.filename ILIKE '%%字幕%%'
        OR COALESCE(rs.title, '') ILIKE '%%字幕%%'
        OR r.filename ILIKE '%%中文%%'
        OR COALESCE(rs.title, '') ILIKE '%%中文%%'
      )
      AND r.filename NOT ILIKE '%%无字幕%%'
      AND COALESCE(rs.title, '') NOT ILIKE '%%无字幕%%'
    )
  )"""


def crack_prefer_predicate_sql() -> str:
    return f"""(
    COALESCE(rs.board_fid, '') = '103:481'
    OR COALESCE(rs.board_name, '') ~ '无码高清|無碼高清|高清中文字幕.*无码|高清中文字幕.*無碼|无码破解|無碼破解|无码流出|無碼流出'
    OR {SEARCH_NAME_EXPR} ~* '-[0-9]{{2,6}}(CX|UC|U)([._[:space:]-]|$)'
    OR r.filename ILIKE '%%-U%%'
    OR r.filename ILIKE '%%_U%%'
    OR COALESCE(rs.title, '') ILIKE '%%-U%%'
    OR COALESCE(rs.title, '') ILIKE '%%_U%%'
    OR r.filename ILIKE '%%破解%%'
    OR COALESCE(rs.title, '') ILIKE '%%破解%%'
    OR r.filename ILIKE '%%马赛克破坏%%'
    OR COALESCE(rs.title, '') ILIKE '%%马赛克破坏%%'
    OR r.filename ILIKE '%%馬賽克破壞%%'
    OR COALESCE(rs.title, '') ILIKE '%%馬賽克破壞%%'
  )"""


def build_prefer_filter_sql(
    *,
    prefer_chinese: bool,
    prefer_crack: bool,
) -> str:
    """仅中文/破解倾向进 SQL。

    地区白名单由 search_resources 应用层过滤，不拼入 SQL。
    """
    parts: list[str] = []
    if prefer_chinese:
        parts.append(f"AND {chinese_prefer_predicate_sql()}")
    if prefer_crack:
        parts.append(f"AND {crack_prefer_predicate_sql()}")
    return "\n".join(parts)
