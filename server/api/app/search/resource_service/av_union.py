"""AV / Bitmagnet 合并结果的地区内存过滤。"""


from typing import Any

from app.core.region_board_allowlist import board_fid_allowed


def _filter_rows_by_region(
    rows: list[dict[str, Any]],
    region: str | None,
    *,
    include_optional: bool = True,
) -> list[dict[str, Any]]:
    """按六区白名单用 board_fid 过滤 AV/Bitmagnet 合并结果。"""
    if not region:
        return rows
    return [
        r
        for r in rows
        if board_fid_allowed(
            r.get("board_fid"), region, include_optional=include_optional
        )
    ]
