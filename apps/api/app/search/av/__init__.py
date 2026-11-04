"""AV maker-code 检索域包 — port of sehua-search makerCodeMatch.ts（regex-only）。

按职责拆分：
- prefixes: 前缀表与规范映射（别名归一、欧美集合、形态判定）
- parse:    番号解析（FC2/date6/欧美日戳/std 等 → ParsedMakerCode）
- patterns: 查询构建（ILIKE 模式 / 边界正则 / SQL 续写拒绝 / 行过滤）
- extract:  从文件名/标题文本抽取规范番号
- keys:     番号统一键与排序键

外部请继续从 `app.search.av` 导入，本 `__init__` 显式 re-export 全部公共名。
"""

from app.search.av.extract import _clamp_std_code_digits, extract_maker_codes
from app.search.av.keys import code_sort_key, std_code_key
from app.search.av.parse import (
    ParsedMakerCode,
    is_av_code_keyword,
    is_uncensored_maker_code,
    maker_code_parts,
    normalize_maker_code,
    parse_maker_code,
)
from app.search.av.patterns import (
    apply_av_code_boundary_filter,
    build_av_code_boundary_re,
    build_av_code_continuation_reject,
    build_av_code_ilike_patterns,
)
from app.search.av.prefixes import (
    DATE6_PREFIX_LABEL,
    PREFIX_CANONICAL,
    PREFIX_SHAPE,
    WESTERN_STUDIO_PREFIXES,
    canonical_prefix,
    is_western_studio_prefix,
    prefix_aliases,
    prefixes_equivalent,
    resolve_maker_shape,
)

__all__ = [
    "DATE6_PREFIX_LABEL",
    "PREFIX_CANONICAL",
    "PREFIX_SHAPE",
    "WESTERN_STUDIO_PREFIXES",
    "ParsedMakerCode",
    "apply_av_code_boundary_filter",
    "build_av_code_boundary_re",
    "build_av_code_continuation_reject",
    "build_av_code_ilike_patterns",
    "canonical_prefix",
    "code_sort_key",
    "extract_maker_codes",
    "is_av_code_keyword",
    "is_uncensored_maker_code",
    "is_western_studio_prefix",
    "maker_code_parts",
    "normalize_maker_code",
    "parse_maker_code",
    "prefix_aliases",
    "prefixes_equivalent",
    "resolve_maker_shape",
    "std_code_key",
]
