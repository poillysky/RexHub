"""addon 名称/简介的中文名称映射：名称归一化与查表。"""

import re

from . import names_zh_1, names_zh_2


def _name_key(name: str) -> str:
    """把 addon 名称归一化为查表键：去掉 "| 平台" 后缀与 [NEW]、emoji 等前缀。"""
    text = re.sub(r"\s*\|\s*.*$", "", str(name or ""))
    text = re.sub(r"^\[[^\]]*\]\s*", "", text)
    text = re.sub(r"^[\W_]+", "", text, flags=re.UNICODE)
    return " ".join(text.lower().split())


# 常用 addon 的中文名称；未收录的仍显示原始名称
_NAME_ZH_RAW = {**names_zh_1._NAME_ZH_RAW, **names_zh_2._NAME_ZH_RAW}
NAME_ZH = {_name_key(name): zh for name, zh in _NAME_ZH_RAW.items()}

# 常用 addon 的一句话中文简介；未收录的退回 manifest 自带描述
_DESC_ZH_RAW = {
    "Anime Kitsu": "Kitsu 动漫目录",
    "AfterCredits": "提示片尾与中途彩蛋",
    "Cast Search": "演员可点击并搜索作品",
    "Content Deep Dive Companion": "为影片补充深度资料",
    "Discussio": "按剧集打开讨论搜索",
    "IMDb Ratings": "显示 IMDb 评分",
    "Radios": "收录九万多个电台",
    "Peario": "与好友同步观影",
    "Stremio Stinger Pro": "提示中段与片尾彩蛋场景",
    "Watch Next": "推荐相似影视",
    "DoesTheDogDie (Jump Scares)": "提示惊吓与敏感内容",
    "Where's The Jump": "标注惊吓点并提供字幕",
    "AIOStatus": "查看网盘会员状态与到期时间",
    "Anthony Bourdain Fans": "安东尼·波登节目合集",
    "Archivio": "查询互联网档案馆片源",
    "Game Cinema": "游戏剧情实况影片",
    "Plexio": "播放 Plex 媒体库",
    "Statusio": "查看网盘会员剩余天数",
    "StreamBridge: Emby to Stremio": "通过 Emby 播放自家媒体",
    "TMDB Collections": "按 TMDB 合集浏览影片",
    "TurkceAltyazi.Org": "土耳其语字幕",
    "Clockrr (Top Right)": "右上角时钟字幕",
    "addic7ed subtitles by dexter21767": "Addic7ed 字幕源",
    "AddMovie for Stremio": "同步到 Notion 片单",
    "AIO Subtitle": "聚合多站字幕",
    "AIO Subtitle PRO": "OpenSubtitles PRO 字幕",
    "AIOCatalogs": "聚合多个片单目录",
    "Animaze": "每周更新的动漫片单",
    "Anime Catalogs": "MyAnimeList 等动漫目录",
    "Anime Seasons (with ratings)": "新番剧集与电影目录",
    "animeo": "AniList 追番进度",
    "Animes' season": "最新动漫季度目录",
    "Auto Subtitle Translate by geanpn": "自动翻译字幕",
    "Auto Subtitle Translate by SonsuzAnime (DeepL)": "DeepL 自动翻译字幕",
    "Buta No Subs Stremio Addon": "日语字幕",
    "Catalog Builder": "自建个性化目录",
    "Christmas Movies": "圣诞主题影视目录",
    "Cinemeta (with ratings)": "Cinemeta 目录并显示评分",
    "Community OpenSubtitles": "OpenSubtitles 社区字幕",
    "Debrid Status by EfNikolas": "检测网盘服务在线状态",
    "Discord Rich Presence Addon": "观看状态同步到 Discord",
    "EfNikolas IP Test": "显示出口 IP 与地区",
    "GTSubs": "谷歌翻译字幕",
    "Heb Subs Premium": "希伯来语字幕",
    "Homocentric": "酷儿题材影视合集",
    "IMDB Catalogs": "IMDb 片单目录",
    "Jimaku Subtitles v2": "Jimaku 日语字幕",
    "Kitsu Tracker": "Kitsu 追番与片单",
    "Ktuvit.me Subtitles": "希伯来语字幕",
    "LegendasDivx.pt": "葡萄牙语字幕",
    "Marvel": "漫威影视合集",
    "MDBList": "MDBList 自定义片单",
    "MSubtitles": "多语言字幕",
    "Mubi Catalog": "Mubi 每日精选片单",
    "MultiSub": "多语字幕翻译",
    "MyShows Lists": "MyShows 片单",
    "Napisy24 Addon": "波兰语字幕",
    "OmniCatalogs": "聚合各平台目录",
    "opensubtitles PRO": "无广告 OpenSubtitles 字幕",
    "OTTCatalog": "流媒体平台影视目录",
    "PGSSUBTITLE V1.0.1": "导入本地 PGS 字幕",
    "podnapisi subtitles by dexter21767": "podnapisi 字幕源",
    "Random Movie": "随机推荐一部电影",
    "Rotten Tomatoes": "烂番茄新鲜认证片单",
    "RPDB Catalogs": "RPDB 新片与热门目录",
    "Simkl Watchlists": "Simkl 观看清单",
    "Streaming Catalogs": "Netflix 等平台热榜",
    "Stremio Community Subtitles": "社区维护字幕",
    "SubDL Subtitles": "SubDL 字幕",
    "SubMaker": "字幕获取与调整",
    "Subs.ro Subtitles": "罗马尼亚语字幕",
    "Subscene subtitles by dexter21767": "Subscene 字幕源",
    "SubSource Subtitles": "SubSource 字幕",
    "Subtis - Beta Pública": "西班牙语字幕",
    "Subtito": "AI 生成字幕",
    "syncribullet": "字幕同步工具",
    "The Movie Database Addon": "TMDB 影片资料",
    "Titlovi.com Subtitles (Community addon by CoRySus)": "Titlovi 字幕",
    "TMDB Alternatives": "补充冷门剧集目录",
    "TMDB Dice": "骰子随机选片",
    "Top Seeded Torrent Catalogs": "热门种子影视目录",
    "Torrent Catalogs": "电影剧集种子目录",
    "Trakt Tv": "Trakt 公开与私人片单",
    "Tu Subtitulo": "西班牙语字幕",
    "Turkce Altyazi(SonsuzAnime)": "土耳其语字幕",
    "UK TV Panel Shows": "英国综艺合集",
    "Watch Calendar": "按日历回顾观看记录",
    "Wizdom Subtitles": "希伯来语字幕",
    "X-Files: Mythology Arc": "X 档案神话剧情线",
    "yifysubtitles subtitles by dexter21767": "YIFY 字幕源",
    "КЮЧЕК": "保加利亚经典影片",
    "כתוביות בעברית": "希伯来语字幕（多源）",
    "SubDL Official Subtitles": "SubDL 官方字幕",
    "Subtitle Sync": "字幕时间轴校准",
    "stremio-addons.net": "在播放器内浏览并安装社区插件",
}
DESC_ZH = {_name_key(name): desc for name, desc in _DESC_ZH_RAW.items()}
