"""色花堂中文标题清洗与判定包。

按职责拆分：
- patterns: 跨子模块共享的静态正则与阈值（进程内单例）
- actors:   末尾女优名剥除（简繁/新旧异体字归一）
- codes:    番号/FC2 代号剥除（lru_cache 按码缓存正则）
- china:    国产片商名剥除
- shells:   AI增强 / 分辨率 / ed2k 技术壳剥除与判定
- fake:     假壳判定（热路径 fast + 全量 is_fake）
- titles:   语言判定（中文/日文）与中文译名段优先
- clean:    主清洗流程 clean_forum_zh_title 及其专用正则

外部请继续从 `app.search.forum_title` 导入，本 `__init__` 显式 re-export。
"""

from app.search.forum_title.clean import clean_forum_zh_title
from app.search.forum_title.fake import (
    is_fake_forum_title,
    is_fake_forum_title_fast,
)
from app.search.forum_title.patterns import (
    _FORUM_META_ZH_JUNK_RE,
    _META_SHELL_SCORE_LEN,
)
from app.search.forum_title.titles import (
    is_indexable_forum_title,
    is_likely_chinese,
    is_likely_japanese,
)


__all__ = [
    "clean_forum_zh_title",
    "is_fake_forum_title",
    "is_fake_forum_title_fast",
    "is_indexable_forum_title",
    "is_likely_chinese",
    "is_likely_japanese",
]
