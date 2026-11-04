"""Stremio addon 仓库：官方仓库与第三方仓库的统一接入。

数据保存在 data/addons.json（0600）：

  {
    "repositories": [{url,title,fetched_at,error,count}],
    "addons": [{slug,id,transport,manifest_url,manifest,repository,
                enabled,added_at,updated_at,error}]
  }

仓库地址支持 Stremio 生态常见的几种格式：官方 addonscollection.json 的
[{transportUrl,manifest}]、addon manifest URL 字符串数组、manifest 数组，
以及包着 addons 列表的对象。接入后由 /stremio/{slug}/... 重新分发。
"""

from __future__ import annotations

import functools
import hashlib
import json
import os
import re
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from typing import Any
from urllib.parse import quote, urlparse

from app.rexhub import config, network_store

ADDONS_PATH = config.DATA_DIR / "addons.json"

OFFICIAL_REPOSITORY = "https://api.strem.io/addonscollection.json"
REPOSITORY_PRESETS = (
    ("Stremio 官方仓库", OFFICIAL_REPOSITORY),
)


def _name_key(name: str) -> str:
    """把 addon 名称归一化为查表键：去掉 "| 平台" 后缀与 [NEW]、emoji 等前缀。"""
    text = re.sub(r"\s*\|\s*.*$", "", str(name or ""))
    text = re.sub(r"^\[[^\]]*\]\s*", "", text)
    text = re.sub(r"^[\W_]+", "", text, flags=re.UNICODE)
    return " ".join(text.lower().split())


# 常用 addon 的中文名称；未收录的仍显示原始名称
_NAME_ZH_RAW = {
    "Anime Kitsu": "动漫库",
    "AfterCredits": "片尾彩蛋",
    "Cast Search": "演员搜索",
    "Content Deep Dive Companion": "内容深度探索",
    "Discussio": "剧集讨论",
    "IMDb Ratings": "IMDb 评分",
    "Radios": "全球电台",
    "Peario": "同步观影",
    "Stremio Stinger Pro": "彩蛋片段提示",
    "Watch Next": "相似推荐",
    "DoesTheDogDie (Jump Scares)": "惊吓提示",
    "Where's The Jump": "惊吓点位",
    "AIOStatus": "账户状态",
    "Anthony Bourdain Fans": "安东尼·波登专区",
    "Archivio": "互联网档案馆",
    "Game Cinema": "游戏电影",
    "Plexio": "Plex 播放",
    "Statusio": "服务状态",
    "StreamBridge: Emby to Stremio": "Emby 播放桥",
    "TMDB Collections": "TMDB 合集",
    "TurkceAltyazi.Org": "土耳其字幕",
    "Clockrr (Top Right)": "时钟字幕",
    "addic7ed subtitles by dexter21767": "Addic7ed 字幕",
    "AddMovie for Stremio": "Notion 片单",
    "AIO Subtitle": "AIO 字幕",
    "AIO Subtitle PRO": "AIO 字幕 PRO",
    "AIOCatalogs": "AIO 目录",
    "Animaze": "动漫精选",
    "Anime Catalogs": "动漫目录",
    "Anime Seasons (with ratings)": "新番季度",
    "animeo": "AniList 追番",
    "Animes' season": "新番季节",
    "Auto Subtitle Translate by geanpn": "字幕自动翻译",
    "Auto Subtitle Translate by SonsuzAnime (DeepL)": "字幕自动翻译 DeepL",
    "Buta No Subs Stremio Addon": "日语字幕",
    "Catalog Builder": "目录构建器",
    "Christmas Movies": "圣诞电影",
    "Cinemeta (with ratings)": "评分版",
    "Community OpenSubtitles": "OpenSubtitles 社区字幕",
    "Debrid Status by EfNikolas": "网盘状态",
    "Discord Rich Presence Addon": "Discord 状态",
    "EfNikolas IP Test": "IP 检测",
    "GTSubs": "谷歌翻译字幕",
    "Heb Subs Premium": "希伯来字幕",
    "Homocentric": "酷儿影视",
    "IMDB Catalogs": "IMDb 目录",
    "Jimaku Subtitles v2": "Jimaku 字幕",
    "Kitsu Tracker": "追番同步",
    "Ktuvit.me Subtitles": "Ktuvit 字幕",
    "LegendasDivx.pt": "葡语字幕",
    "Marvel": "漫威",
    "MDBList": "MDBList 片单",
    "MSubtitles": "MSubtitles 字幕",
    "Mubi Catalog": "Mubi 片单",
    "MultiSub": "多语字幕",
    "MyShows Lists": "MyShows 片单",
    "Napisy24 Addon": "波兰语字幕",
    "OmniCatalogs": "全能目录",
    "opensubtitles PRO": "OpenSubtitles PRO",
    "OTTCatalog": "流媒体目录",
    "PGSSUBTITLE V1.0.1": "PGS 字幕",
    "podnapisi subtitles by dexter21767": "Podnapisi 字幕",
    "Random Movie": "随机电影",
    "Rotten Tomatoes": "烂番茄",
    "RPDB Catalogs": "RPDB 目录",
    "Simkl Watchlists": "Simkl 片单",
    "Streaming Catalogs": "流媒体热榜",
    "Stremio Community Subtitles": "社区字幕",
    "SubDL Subtitles": "SubDL 字幕",
    "SubMaker": "字幕工坊",
    "Subs.ro Subtitles": "Subs.ro 字幕",
    "Subscene subtitles by dexter21767": "Subscene 字幕",
    "SubSource Subtitles": "SubSource 字幕",
    "Subtis - Beta Pública": "Subtis 字幕",
    "Subtito": "Subtito 字幕",
    "syncribullet": "字幕同步",
    "The Movie Database Addon": "TMDB 数据库",
    "Titlovi.com Subtitles (Community addon by CoRySus)": "Titlovi 字幕",
    "TMDB Alternatives": "TMDB 备选片源",
    "TMDB Dice": "随机选片",
    "Top Seeded Torrent Catalogs": "热门种子",
    "Torrent Catalogs": "种子目录",
    "Trakt Tv": "Trakt 片单",
    "Tu Subtitulo": "西语字幕",
    "Turkce Altyazi(SonsuzAnime)": "土耳其字幕 SonsuzAnime",
    "UK TV Panel Shows": "英国综艺",
    "Watch Calendar": "观看日历",
    "Wizdom Subtitles": "Wizdom 字幕",
    "X-Files: Mythology Arc": "X 档案神话线",
    "yifysubtitles subtitles by dexter21767": "YIFY 字幕",
    "КЮЧЕК": "保加利亚经典",
    "כתוביות בעברית": "希伯来字幕",
    "SubDL Official Subtitles": "SubDL 官方字幕",
    "Subtitle Sync": "字幕同步校准",
    "stremio-addons.net": "社区插件目录",
    "aftercredits": "片尾彩蛋",
    "cast search": "演员搜索",
    "content deep dive companion": "内容深度探索",
    "discussio": "剧集讨论",
    "imdb ratings": "IMDb 评分",
    "radios": "全球电台",
    "peario": "同步观影",
    "stremio stinger pro": "彩蛋片段提示",
    "watch next": "相似推荐",
    "doesthedogdie (jump scares)": "惊吓提示",
    "where's the jump": "惊吓点位",
    "aiostatus": "账户状态",
    "anthony bourdain fans": "安东尼·波登专区",
    "archivio": "互联网档案馆",
    "game cinema": "游戏电影",
    "plexio": "Plex 播放",
    "statusio": "服务状态",
    "streambridge: emby to stremio": "Emby 播放桥",
    "tmdb collections": "TMDB 合集",
    "omni index": "全能索引",
    "ntc tv": "NTC 直播",
    "abyssus": "深渊播放",
    "zeus": "宙斯聚合",
    "plaviolive": "Plavio 直播",
    "israeli tv": "以色列电视",
    "ult addon": "ULT 综合",
    "stremy": "Stremy 播放",
    "superstream": "超级播放",
    "praias tugas": "葡萄牙海滩直播",
    "tvi player": "TVI 播放器",
    "sic": "SIC 葡萄牙台",
    "tvs de portugal": "葡萄牙电视台",
    "webstreamrmbg": "WebStreamr 播放",
    "acuanime": "AcuAnime 动漫",
    "matchletter · watch together": "同步观影社交",
    "bg live tv": "保加利亚直播",
    "g-tv": "G-TV 直播",
    "onair": "Onair 直播",
    "woo": "Woo 直播",
    "g-tube": "G-Tube 视频",
    "watch order": "观看顺序",
    "absolute cinema": "绝对影院",
    "internet archive movies & shows": "互联网档案馆影视",
    "nada tv hls": "NADA 直播",
    "nightknight cinema": "夜骑士影院",
    "سینماگرافی": "波斯电影志",
    "open movies": "开放电影",
    "3d movies": "3D 电影",
    "pencarimovie": "马来影片搜索",
    "skylinewebcams": "全球街景摄像头",
    "fireplace": "壁炉氛围",
    "shadzop anime": "Shadzop 动漫",
    "ltan - anime": "LTAN 动漫",
    "to be continued...?": "未完待续",
    "popcorn noise": "爆米花推荐",
    "pimpbunny": "PimpBunny 片源",
    "pleiadesstream torrents": "昴星团种子",
    "pleiadesstream": "昴星团播放",
    "reddate yt": "Reddate 油管",
    "omnistream": "全能播放（多音轨）",
    "kick streams & videos": "Kick 直播与视频",
    "watchlane": "油管频道播放",
    "streamgram": "Telegram 影音",
    "adult addon": "成人内容",
    "rtp play": "RTP 葡萄牙台",
    "streamunion": "StreamUnion 聚合",
    "ruído · pt": "Ruído 葡萄牙",
    "minha iptv": "我的 IPTV",
    "cinesenseai": "AI 影视推荐",
    "easynews + torrentclaw combo": "Easynews 与 TorrentClaw 组合",
    "streamvault iptv": "StreamVault 直播",
    "latanime": "拉美动漫",
    "streamplay (arvio edition)": "StreamPlay 播放",
    "plaviohd": "Plavio 高清",
    "cinemeta of audiobooks": "有声书目录",
    "shadzop h_anime": "Shadzop 成人动漫",
    "daebak korean drama": "韩剧 Daebak",
    "addex": "Addex 索引",
    "ole miss": "Ole Miss 体育",
    "hoạt hình 3d trung quốc": "中国 3D 动画",
    "stremio local debrid": "本地缓存播放",
    "iracemaflix": "Iracema 巴西影视",
    "mediathekview de (erweitert)": "德国公共台回看",
    "tvplay ipfs": "IPFS 直播",
    "gundam": "高达专区",
    "veyra": "Veyra 播放",
    "cvnflix streams": "CVNFLIX 播放",
    "wlatino": "拉美影视",
    "top posters addon wrapper": "海报增强",
    "muvindo": "印尼影视",
    "fayatv": "FayaTV 直播",
    "specter": "SPECTER 播放",
    "freedom media": "自由媒体",
    "deepflix": "DeepFlix 影视",
    "dc universe": "DC 宇宙",
    "marvel": "漫威",
    "cncverse bridge": "CNCVerse 桥接",
    "sports replay": "体育回放",
    "iptv": "IPTV 直播",
    "lat-add": "拉美直连",
    "uploadedpremiumlink": "网盘直链播放",
    "heroes": "英雄特摄",
    "kkphim": "KKPhim 越南影视",
    "watchario": "Watchario 影视",
    "k20 • tm & lt": "K20 越南配音",
    "newsio": "新闻聚合",
    "mindgeek": "成人内容聚合",
    "unioflix": "UnioFlix 影视",
    "aiolivetv": "全能直播",
    "banglaplex": "孟加拉影视",
    "adult anime & shorts": "成人动漫短片",
    "tubi movies": "Tubi 电影",
    "wrestling & ufc — eventos (wwe, aew, tna, ufc)": "摔角与 UFC 赛事",
    "torrentio": "种子聚合",
    "notxo": "Notxo 影视",
    "hyper": "Hyper 播放",
    "whoniverse": "神秘博士宇宙",
    "formulio": "F1 赛事",
    "easynews+": "Easynews 增强",
    "stremthru torz": "StremThru 种子",
    "tenies.space live tv & sports": "TENIES 直播与体育",
    "stravo ii": "Stravo 二版",
    "w bandes-annonces vf": "法语预告片",
    "tv legal france": "法国合法电视",
    "tvmio": "TVMio 直播",
    "anixio": "动漫播放",
    "anthology — canlı tv": "土耳其直播",
    "nexus": "Nexus 聚合",
    "persian streams": "波斯语播放源",
    "adult video hd": "成人高清",
    "m3u mux": "M3U 直播源",
    "tvvio": "Tvvio 直播",
    "pipe": "Pipe 播放",
    "viptorrent": "贵宾种子",
    "k20 - anime": "K20 动漫",
    "m_rulz scraper (telugu)": "MovieRulz 泰卢固片源",
    "cinehack torbox": "CineHack TorBox 片源",
    "cartoon aziz": "Aziz 卡通",
    "bidooo arabic catalog": "阿拉伯影视",
    "midnight": "Midnight 影视",
    "pinoy movies": "菲律宾电影",
    "novastream": "新星播放",
    "comet creepso": "彗星 Creepso",
    "frenchio": "法语影视",
    "ember": "Ember 推荐",
    "nova streams": "新星播放源",
    "metegol": "MeteGol 体育",
    "torfuse": "TorFuse 种子",
    "k20 phim tổng hợp": "K20 综合影视",
    "tv browser": "电视浏览器",
    "cauldron": "大锅聚合",
    "megasource": "巨量片源",
    "dragons rising hebrew + english": "龙之崛起（希伯来语）",
    "nuvio live sports": "Nuvio 体育直播",
    "toastflix": "Toast 影视",
    "grab": "Grab 抓取",
    "febbox addon": "FebBox 播放",
    "iptv bridge": "IPTV 桥接",
    "ororo.tv": "ororo 美剧",
    "magyar tv": "匈牙利电视",
    "linkañol": "西语链接源",
    "lelibrary": "影视库",
    "ltstream": "LT 播放",
    "audionerr": "音频与有声书",
    "latinobrid": "拉美桥",
    "naitor": "naiTor 种子",
    "webshare": "Webshare 网盘",
    "better stream": "增强播放",
    "eclipsia": "Eclipsia 影视",
    "vietnamese sexy girl stream": "越南写真视频",
    "jkanime tv nativo": "JK 动漫台",
    "better metadata": "增强元数据",
    "showbox": "Showbox 影视",
    "fenix tv": "凤凰电视",
    "chya tv": "库尔德配音",
    "one pace 4k": "海贼王 One Pace 4K",
    "advanced hindi streams pro": "印地语片源 Pro",
    "tpb 4k porn": "海盗湾成人 4K",
    "animee": "Animee 动漫",
    "twojlimit": "波兰网盘播放",
    "nopremium": "免会员网盘播放",
    "tuga tv": "葡萄牙电视",
    "binge brakes": "追剧休息提醒",
    "rapideo": "Rapideo 网盘",
    "king vod": "影视之王",
    "liteaio": "轻量全能",
    "ghostvod engine": "幽灵片源引擎",
    "sitcom surprise": "情景喜剧随机",
    "penguplay": "企鹅播放",
    "desiflix": "印度影视",
    "torbox librarian": "TorBox 书库",
    "addon latam": "拉美影视",
    "sk/cz torrents": "斯洛伐克/捷克种子",
    "lumio stream": "Lumio 播放",
    "magneto": "磁力播放",
    "youtube recaps": "油管解说",
    "all iptv": "全网 IPTV",
    "sensitivity notes": "内容敏感提示",
    "stravo": "Stravo 播放",
    "filtorrent": "过滤种子",
    "flix-streams free": "免费影视源",
    "iptv catchup (m3u/epg)": "IPTV 回看",
    "bamabin": "Bamabin 影视",
    "nebula sports": "星云体育",
    "scary.network horror live tv": "恐怖直播台",
    "animo": "阿拉伯动漫",
    "avamovie": "Ava 影视",
    "betor v3 oficial": "BeTor 巴西种子",
    "progreso latino": "拉美影视",
    "maximum sports": "极限体育",
    "sports streams": "体育直播源",
    "stremtv us": "美国电视",
    "sportvibe": "体育氛围",
    "motorsport hub": "赛车中心",
    "adult stremio addon": "成人插件",
    "persian satellite & iptv": "波斯卫星与直播",
    "kast alldebrid": "Kast 网盘聚合",
    "torrin": "Torrin 种子",
    "magnetio": "磁力播放",
    "meu futebol": "我的足球",
    "pezzhub profile manager": "PEZZHUB 配置管理",
    "till": "TILL 播放",
    "muvibox": "Muvibox 影视",
    "supreme": "Supreme 播放",
    "moviebox": "MovieBox 影视",
    "akashi tv (free)": "赤司电视",
    "123av": "123av 影视",
    "kod": "KOD 播放",
    "pezzhub aio": "PEZZHUB 全能",
    "m3u iptv": "M3U 直播",
    "vela flow": "船帆播放",
    "cotonet": "Cotonet 影视",
    "رحلة في الذاكرة": "记忆之旅",
    "sootio": "云端搜索",
    "disney arabic dub": "迪士尼阿拉伯配音",
    "stremio stream store": "播放源商店",
    "porn tube": "成人视频",
    "thebeginning": "起点播放",
    "cin": "CIN 影视",
    "yukistreams": "Yuki 播放",
    "cvnstream": "CVN 播放",
    "torrentclaw": "种子抓取",
    "torrent♦️dz": "阿尔及利亚种子",
    "israel tv": "以色列电视",
    "filmora": "Filmora 影视",
    "watcho": "WATCHO 影视",
    "flixoo": "FLIXOO 影视",
    "astral flow": "星界播放",
    "nexio nagare": "Nexio 流",
    "xxxclub + real-debrid": "成人俱乐部 + RD",
    "dz-movie": "阿尔及利亚电影",
    "aioratings": "全能评分",
    "nexio torii": "Nexio 鸟居",
    "frostview tv": "霜景电视",
    "dcbi addon": "DCBI 影视",
    "mediafusion": "媒体融合",
    "imdb.su addon": "IMDb.su 播放",
    "comet": "彗星播放",
    "eh! iptv": "Eh! 直播",
    "tenies.site": "TENIES 影视",
    "froststream": "霜流",
    "guindex": "Gu 索引",
    "🎬 by murph streams ⚡": "Murph 片源",
    "scary only — horror by subgenre": "纯恐怖（按子类型）",
    "stremiolabar بقالة جيهيو": "阿拉伯影视杂货铺",
    "watchnow": "立即观看",
    "watchflix": "WatchFlix 影视",
    "romania iptv": "罗马尼亚直播",
    "🎬 pulp watch": "低俗影视",
    "esafetv": "安全电视",
    "norge-hub": "挪威中心",
    "zamunda bg": "Zamunda 保加利亚",
    "indian regional catalog": "印度地方影视",
    "animesub+": "动漫字幕播放",
    "nova channels": "新星频道",
    "still: a minecraft series": "我的世界剧集",
    "plotcard": "剧情卡片",
    "aradeb": "阿拉伯影视",
    "podium": "领奖台体育",
    "nebulastreams": "星云播放",
    "aniscraper": "动漫抓取",
    "anime filler checker": "动漫原创集检测",
    "basedon": "原著改编",
    "made by": "制作方",
    "song scene": "歌曲场景",
    "amatsu": "Amatsu 动漫",
    "ultrapelis": "拉美影视",
    "mytrakt sync": "Trakt 同步",
    "stremverse": "影视宇宙",
    "streamfusionreborn": "融合播放重生版",
    "animesdigital": "动漫数字",
    "bludv (stream)": "蓝光影视",
    "khmerdub": "高棉语配音",
    "🎌 anitube.news (v3.4.2 pro)": "动漫台新闻",
    "addtorr": "添加种子",
    "yomi": "Yomi 影视",
    "kids filmes e series de animacao pt-pt addon stremio": "葡萄牙少儿动画",
    "animvault": "动漫宝库",
    "tmdb streaming es": "西语流媒体",
    "limontorrents": "柠檬种子",
    "filmes, series e novelas portuguesas addon stremio": "葡萄牙影视剧",
    "nexotv": "Nexo 电视",
    "seedr cloud storage": "Seedr 云盘",
    "selectavision": "Selecta 影视",
    "hdhub": "高清中心",
    "anilibria": "动漫图书馆",
    "oceny filmweb": "Filmweb 评分",
    "flix-music": "影视音乐",
    "40th project": "四十号计划",
    "live channels pt": "葡萄牙直播频道",
    "aniliststream": "AniList 播放",
    "stremthru newz": "StremThru 新闻组",
    "streamx": "StreamX 播放",
    "inmax": "InMax 印度影视",
    "torrent to weblink": "种子转直链",
    "iptv addon by savi": "Savi 直播",
    "canales deportivos": "西语体育台",
    "fenixflix": "凤凰影视",
    "epg - tv": "节目单电视",
    "marquee": "片单轮播",
    "streamar by dexter21767": "阿根廷播放",
    "flix-streams": "影视源",
    "anime vortex": "动漫漩涡",
    "bg music channels": "保加利亚音乐台",
    "dontorrent": "Don 种子",
    "kinopoisk рейтинг": "俄罗斯影评",
    "watchhub": "观看中心",
    "sosactv2": "Sosac 电视",
    "yastream": "YaStream 播放",
    "muviblox": "印尼影视",
    "torrenthan 🇮🇹": "意大利种子",
    "flick whisper": "低语影视",
    "bgtorrents": "保加利亚种子",
    "meteor": "流星播放",
    "animes br": "巴西动漫",
    "embed subfilter": "内嵌字幕过滤",
    "stremio status": "Stremio 状态",
    "audiobookbay": "有声书湾",
    "asian club": "亚洲俱乐部",
    "vidfast pro": "极速视频 Pro",
    "sid vod playlist": "SID 点播片单",
    "cometnet": "彗星网络",
    "indian fm radio hd": "印度电台高清",
    "easyanime": "轻松动漫",
    "intelligent debrid search": "智能网盘搜索",
    "del kdrama series/movies": "韩剧专区",
    "one pace - complete series": "海贼王 One Pace 全集",
    "poltronaplay": "沙发影院",
    "crunch": "Crunch 播放",
    "ro sport live": "罗马尼亚体育直播",
    "romanian tv": "罗马尼亚电视",
    "heartio": "心动影视",
    "hentaistream": "成人动漫",
    "xxxclub": "成人俱乐部",
    "webradio": "网络电台",
    "nodebrid": "无网盘播放",
    "greflix": "希腊影视",
    "arabcity": "阿拉伯城",
    "📫 itsout!": "已上线",
    "trakt sync & rate": "Trakt 同步与评分",
    "akwam": "阿拉伯影视",
    "zamunda torrents": "Zamunda 种子",
    "anime world india addon": "印度动漫世界",
    "streailer": "预告片",
    "notorrent": "免种子播放",
    "youtube trailers": "油管预告片",
    "leviathan": "利维坦",
    "shared debrid notifier": "网盘共享提醒",
    "🎥 archive.org": "互联网档案馆",
    "nzb": "NZB 下载",
    "launcherio": "启动器",
    "nzbhydra 2": "NZB 聚合",
    "ccloud": "CCloud 网盘",
    "primer latino": "拉美首选",
    "pluto tv": "Pluto 电视",
    "ilcorsaroviola": "意大利海盗",
    "sm addon": "SM 影视",
    "digimoviez": "数字影视",
    "streamsppv": "PPV 直播",
    "stremthru store": "StremThru 片库",
    "jackettio": "Jackett 聚合",
    "easynews++": "Easynews 增强",
    "animepahe": "AnimePahe 动漫",
    "overseerr requests": "Overseerr 点播",
    "indtorrents": "印度种子",
    "stashdb - easynews": "StashDB 成人片库",
    "zelka & zamunda addon": "Zelka 与 Zamunda",
    "watchio.live tv": "Watchio 直播",
    "mico-leão dublado 🇧🇷": "巴西配音影视",
    "one pace addon": "One Pace 插件",
    "📺 tv en direct": "法国直播",
    "webtor.io": "Webtor 播放",
    "badradio": "坏电台",
    "premiumize library": "Premiumize 片库",
    "m3u/epg tv addon": "M3U 与节目单",
    "moviesindetail: open link": "影视详情直链",
    "dragonball addon": "龙珠专区",
    "seedsphere (private)": "种子星球",
    "tvvoo": "TvVoo 直播",
    "youtubio": "油管播放",
    "zmb": "ZMB 影视",
    "au iptv (brisbane)": "澳洲直播",
    "streamvix": "StreamViX 播放",
    "hellspy": "地狱种子",
    "películas de cinecalidad": "西语高清电影",
    "minha tv": "我的电视",
    "georgia tv: live channels": "格鲁吉亚电视",
    "fkstream | torrent": "FK 种子播放",
    "🎯 ratings aggregator": "评分聚合",
    "rtve": "西班牙广播电视台",
    "hianime streams": "HiAnime 动漫",
    "torrentsdb": "种子数据库",
    "animes": "西语动漫",
    "webshare.cz": "Webshare 网盘（捷克）",
    "more like this": "相似推荐",
    "streamfusion": "融合播放",
    "iran provider": "伊朗片源",
    "reflux": "回流播放",
    "age ratings": "年龄分级",
    "fshare": "Fshare 网盘",
    "greek tv": "希腊电视",
    "my cine": "我的影院",
    "xtremio": "Xtremio 配置",
    "skyflix": "天空影视",
    "ratings": "评分聚合",
    "docchi.pl addon": "Docchi 动漫",
    "cricket streams": "板球直播",
    "ytztvio": "Ytz 电视",
    "autoembed strem": "自动内嵌播放",
    "einthusantv": "Einthusan 印度电影",
    "israel tv for stremio": "以色列电视",
    "cometfr": "彗星法语版",
    "streamasia": "亚洲剧集",
    "usa tv": "美国电视",
    "stremify": "Stremify 播放",
    "argentina tv": "阿根廷电视",
    "dizipal": "土耳其影视",
    "dubbing indonesia": "印尼配音",
    "canal ricos addon": "Ricos 频道",
    "onlyporn": "成人专区",
    "stremio iptv by dexter21767": "Stremio IPTV 直播",
    "knightcrawler": "骑士爬虫",
    "kinopub": "KinoPub 影视",
    "animecix": "土耳其动漫",
    "maine news": "缅因新闻",
    "debrid search": "网盘搜索",
    "hanime": "成人动漫",
    "easynews": "Easynews 下载",
    "consumet": "Consumet 聚合",
    "peerflix": "Peerflix 播放",
    "thepiratebay catalog": "海盗湾目录",
    "cinetorrent": "影院种子",
    "napflix": "Napflix 影视",
    "orion": "猎户座播放",
    "brazuca torrents": "巴西种子",
    "thepiratebay+": "海盗湾增强",
    "ftv channels": "FTV 频道",
    "anime kitsu": "动漫库",
    "turkcealtyazi.org": "土耳其字幕",
    "clockrr (top right)": "右上角时钟字幕",
    "aio subtitle": "AIO 字幕",
    "aio subtitle pro": "AIO 字幕 PRO",
    "auto subtitle translate by geanpn": "字幕自动翻译",
    "auto subtitle translate by sonsuzanime (deepl)": "字幕自动翻译 DeepL",
    "buta no subs stremio addon": "日语字幕",
    "community opensubtitles": "OpenSubtitles 社区字幕",
    "discord rich presence addon": "Discord 状态",
    "gtsubs": "谷歌翻译字幕",
    "heb subs premium": "希伯来字幕 Premium",
    "jimaku subtitles v2": "Jimaku 字幕",
    "kitsu tracker": "追番同步",
    "ktuvit.me subtitles": "Ktuvit 字幕",
    "legendasdivx.pt": "葡语字幕",
    "msubtitles": "MSubtitles 字幕",
    "multisub": "多语字幕",
    "napisy24 addon": "波兰语字幕",
    "opensubtitles pro": "OpenSubtitles 无广告字幕",
    "pgssubtitle v1.0.1": "PGS 字幕",
    "stremio community subtitles": "社区字幕",
    "subdl subtitles": "SubDL 字幕",
    "submaker": "字幕工坊",
    "subs.ro subtitles": "Subs.ro 字幕",
    "subscene subtitles by dexter21767": "Subscene 字幕",
    "subsource subtitles": "SubSource 字幕",
    "subtis - beta pública": "Subtis 字幕",
    "subtito": "AI 生成字幕",
    "titlovi.com subtitles (community addon by corysus)": "Titlovi 字幕",
    "tu subtitulo": "西语字幕",
    "turkce altyazi(sonsuzanime)": "土耳其字幕 SonsuzAnime",
    "wizdom subtitles": "Wizdom 字幕",
    "subdl official subtitles": "SubDL 官方字幕",
    "subtitle sync": "字幕同步校准",
    "ultimate smart subs (uss)": "智能字幕增强",
    "rosettasubs": "Rosetta 字幕",
    "hispasubs": "西语字幕",
    "tr altyazı": "土耳其字幕",
    "demo titlovi.com official": "Titlovi 官方字幕",
    "legendasbr": "巴西葡语字幕",
    "subpool by diavelin": "SubPool 字幕池",
    "türkçe altyazı+ (film, dizi, anime & one pace)": "土耳其字幕+",
    "🍿 subtitles: extended": "扩展字幕",
    "forced sub (it)": "意大利强制字幕",
    "thesubtitledb": "字幕数据库",
    "chinese subtitles (zimuku & subhd)": "中文字幕（字幕库/SubHD）",
    "subsync": "字幕同步",
    "tugasubs": "葡萄牙字幕",
    "subtitle scout": "字幕侦察",
    "persian subtitles": "波斯语字幕",
    "ترجمة عربية مجمّعة (subdl + subsource)": "阿拉伯语字幕聚合",
    "wyzie subs": "Wyzie 字幕",
    "kontyx subtitles": "KONTYX 字幕",
    "subtranslate": "字幕翻译",
    "hebrew opensubtitles": "希伯来 OpenSubtitles",
    "syncsubs": "SyncSubs 同步",
    "subtitle translator": "字幕翻译器",
    "auto-subs": "自动字幕翻译",
    "subalchemy": "字幕炼金",
    "anysubs": "AnySubs 双语",
    "altyazidb subtitles": "AltyaziDB 字幕",
    "anisync": "动漫字幕同步",
    "double subtitles": "双字幕",
    "idk subs": "希伯来 AI 字幕",
    "opensubtitles v3": "OpenSubtitles 新版字幕",
    "dz-arabic": "阿尔及利亚阿拉伯字幕",
    "bgsubs": "保加利亚字幕",
    "hebrew subtitle bridge": "希伯来字幕桥",
    "animesub.info subtitles": "AnimeSub 字幕",
    "napiprojekt addon": "波兰 NapiProjekt 字幕",
    "subtitle search engine": "字幕搜索引擎",
    "altyazitr": "土耳其字幕 TR",
    "one pace türkçe altyazı": "One Pace 土耳其字幕",
    "subtitle fixer pro": "字幕修复 Pro",
    "sublatino - dav1ron": "拉美西语字幕",
    "universal subtitle translator": "通用字幕翻译",
    "one pace pt-br subs": "One Pace 巴西字幕",
    "dualsubs (default)": "双语字幕",
    "pipocas.tv legendas": "Pipocas 葡语字幕",
    "nhảmsubtitle ai": "越南语 AI 字幕",
    "wyzie ar sub": "Wyzie 阿拉伯字幕",
    "arabic auto-sync subtitles": "阿拉伯语自动同步字幕",
    "bulgarian subtitles": "保加利亚字幕",
    "dual subtitles": "双语字幕",
    "subhero v2": "SubHero 字幕 v2",
    "subsense": "SubSense 字幕",
    "jimaku subtitles": "Jimaku 字幕",
    "medialib": "媒体库",
    "mal-stremio addon": "MyAnimeList 同步",
    "subtítulos subdivx": "Subdivx 西语字幕",
    "strelingo - dual language subtitles": "Strelingo 双语字幕",
    "subhero": "SubHero 字幕",
    "aio substitle": "AIO 字幕",
    "opensubtitles.org subtitles by dexter21767": "OpenSubtitles.org 字幕",
    "addmovie for stremio": "Notion 片单",
    "aiocatalogs": "AIO 目录",
    "animaze": "动漫精选",
    "anime catalogs": "动漫目录",
    "anime seasons (with ratings)": "新番季度",
    "animes' season": "新番季节",
    "catalog builder": "目录构建器",
    "christmas movies": "圣诞电影",
    "cinemeta (with ratings)": "评分版 Cinemeta",
    "debrid status by efnikolas": "网盘状态",
    "efnikolas ip test": "IP 检测",
    "imdb catalogs": "IMDb 目录",
    "mdblist": "MDBList 片单",
    "mubi catalog": "Mubi 片单",
    "myshows lists": "MyShows 片单",
    "omnicatalogs": "全能目录",
    "ottcatalog": "流媒体目录",
    "random movie": "随机电影",
    "rotten tomatoes": "烂番茄",
    "rpdb catalogs": "RPDB 目录",
    "simkl watchlists": "Simkl 片单",
    "streaming catalogs": "流媒体热榜",
    "the movie database addon": "TMDB 数据库",
    "tmdb alternatives": "TMDB 备选目录",
    "tmdb dice": "随机选片",
    "top seeded torrent catalogs": "热门种子",
    "torrent catalogs": "种子目录",
    "uk tv panel shows": "英国综艺",
    "watch calendar": "观看日历",
    "x-files: mythology arc": "X 档案神话线",
    "halloween movies": "万圣节电影",
    "curated daily trending": "每日热门精选",
    "springfield 3000": "辛普森 3000",
    "marvel addon for stremio": "漫威目录",
    "marvel chronological": "漫威时间线",
    "balkanio": "巴尔干影视",
    "horror": "恐怖片",
    "stremio stats": "Stremio 统计",
    "simkl watch next": "Simkl 续看",
    "pmeta": "Plavio 目录",
    "watch atlas": "观影地图",
    "halloween after dark": "万圣节暗夜",
    "rwind": "Rwind 播放",
    "now showing": "正在上映",
    "sverigehub": "瑞典中心",
    "pictorium": "影视图册",
    "cnative": "原生频道",
    "r/movieleaks": "Reddit 电影泄露",
    "synchronous: publicmetadb": "公共元数据库",
    "story order": "剧情顺序",
    "top 10 portugal (filmes & séries)": "葡萄牙 Top 10",
    "aiolists": "AIO 片单",
    "tvdb search": "TVDB 搜索",
    "french stream (public)": "法语影视",
    "dragon ball es - cronología": "龙珠西语时间线",
    "eight+": "Eight+ 目录",
    "film festivals 2": "电影节片单",
    "arabcinemeta": "阿拉伯影视元数据",
    "cast list": "演员表",
    "seenr": "观影记录",
    "movie roulette": "电影轮盘",
    "streamlists · test": "流媒体片单（测试）",
    "cineledger": "影史账本",
    "custom watch order": "自定义观看顺序",
    "101catalogs": "101 目录",
    "movie leaks": "电影泄露",
    "imdb popular": "IMDb 热门",
    "cz dabing & streaming": "捷克配音流媒体",
    "cinema time machine": "电影时光机",
    "ec mdblist": "MDBList 翻译",
    "dubbedanimefeed": "配音动漫源",
    "global catalogs": "全球目录",
    "brit catalogs": "英国影视目录",
    "cagelog": "凯奇作品日志",
    "killer bean": "杀手豆",
    "multiboxd": "多盒目录",
    "kisskh catalog": "KissKH 亚洲剧",
    "raccoonmendations": "浣熊推荐",
    "waypoint": "航点推荐",
    "🎲 tv show shuffle": "剧集随机播放",
    "flixai": "AI 影视目录",
    "ai streams v2": "AI 播放源 v2",
    "nautilus": "鹦鹉螺片单",
    "streaming catalogs plus": "流媒体热榜 Plus",
    "imax movies catalog": "IMAX 电影目录",
    "filmweb watchlist": "Filmweb 片单",
    "mot9+": "mot9+ 直播",
    "cinemaratona br 🎬": "巴西电影马拉松",
    "goodtaste": "好品味推荐",
    "gemini ai recommender": "Gemini AI 推荐",
    "cinemacove": "海湾影院",
    "stremboxd": "Letterboxd 影评",
    "berserk": "剑风传奇",
    "k-drama crush": "韩剧心动",
    "animestream": "动漫播放",
    "james bond 007 collection (official)": "007 合集",
    "pixileaf's watchly": "Pixileaf 片单",
    "asian-tv": "亚洲电视",
    "err filmiaasta 2025": "爱沙尼亚 2025 片单",
    "animeworld catalog": "动漫世界目录",
    "bharat binge": "印度追剧",
    "sitcom catalogs": "情景喜剧目录",
    "christmas sitcom marathon": "圣诞情景喜剧连播",
    "watchly": "Watchly 片单",
    "douban": "豆瓣",
    "stremio loved": "Stremio 收藏",
    "stremio liked": "Stremio 点赞",
    "🎉 holiday movies & shows": "节日影视",
    "cine español": "西班牙电影",
    "the sieve - series": "筛子剧集",
    "the sieve": "筛子片单",
    "tvgardenio": "电视花园",
    "kids (g/pg, tv-y/tv-g)": "少儿影视",
    "librario": "图书目录",
    "stremthru list": "StremThru 片单",
    "toast translator": "Toast 翻译",
    "tmdb filters: horror, action, comedy, science fiction": "TMDB 分类筛选",
    "top streaming": "流媒体排行",
    "playlistio": "片单播放",
    "indo": "印尼片单",
    "indiastreams": "印度影视",
    "filmweb.pl watchlist addon": "Filmweb.pl 片单",
    "nickelodeon": "尼克儿童",
    "viva max": "Viva Max 影视",
    "cartoon network": "卡通频道",
    "star wars universe": "星球大战宇宙",
    "stremlist": "Strem 片单",
    "ai search": "AI 搜索",
    "filmwhisper": "电影低语",
    "stremio-serializd": "Serializd 剧集",
    "sagas and marathons": "系列与连播",
    "letterboxed": "Letterboxd",
    "music concerts": "音乐会",
    "torrentfreaks top-10 by krazykayaker": "TorrentFreak 十佳",
    "trakt tv": "Trakt 片单",
    "кючек": "保加利亚经典",
    "nauta live tv": "Nauta 直播",
    "handycard - trakt assistido": "Trakt 助手卡片",
    "homocentric": "酷儿影视",
    "cinemata remover": "Cinemata 移除器",
    "compass aiostreams": "Compass 全能播放",
    "movieleaks — noiro.tv": "电影泄露 Noiro",
    "indian cinema": "印度电影",
    "aio metadata": "全能元数据",
    "bestcine": "最佳影院",
    "pelis": "西语影视",
    "nyaa anime br": "Nyaa 巴西动漫",
    "gemini ai": "Gemini AI 翻译",
    "aiostreams": "AIOStreams 全能播放",
    "lowdefpirate aio": "低码率海盗全能",
    "pvtkrr": "PVTKRR 私有源",
    "bingecat ai assistant": "追剧猫 AI 助手",
    "trakt beat": "Trakt 节拍",
    "stremcodes": "StremCodes 影视",
    "🎲 zufalls-entdecker (tmdb)": "TMDB 随机发现",
    "tmdb discover+": "TMDB 发现+",
    "stremthru wrap": "StremThru 整合",
    "aiostreams stable": "AIOStreams 稳定版",
    "aiostreams nightly": "AIOStreams 每日版",
    "letterboxd": "Letterboxd 影评",
    "omnistream 🌍 (multi-audio + anime)": "全能播放（多音轨+动漫）",
    "watchlane: your youtube channels": "油管频道播放",
    "streamunion · noam sasson": "StreamUnion 聚合",
    "minha iptv • canaisbr02": "我的 IPTV 巴西频道",
    "subtitles: extended": "扩展字幕",
    "muvindo: pemersatu bangsa +62": "印尼影视",
    "toastflix🥪": "Toast 影视",
    "torbox librarian 📚": "TorBox 书库",
    "persian satellite & iptv [suspended]": "波斯卫星与直播（已暂停）",
    "tv show shuffle": "剧集随机播放",
    "dz-movie🔗": "阿尔及利亚电影",
    "by murph streams ⚡": "Murph 片源",
    "pulp watch": "低俗影视",
    "anitube.news (v3.4.2 pro)": "动漫台新闻",
    "zufalls-entdecker (tmdb)": "TMDB 随机发现",
    "itsout!": "已上线",
    "archive.org": "互联网档案馆",
    "holiday movies & shows": "节日影视",
    "tv en direct": "法国直播",
    "fkstream": "FK 种子播放",
    "ratings aggregator": "评分聚合",
}
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


def display_name(manifest: dict | None, fallback: str = "") -> str:
    """addon 展示名：优先中文译名，其次 manifest 原名。"""
    name = str((manifest or {}).get("name") or fallback or "")
    return NAME_ZH.get(_name_key(name), name)


def display_description(manifest: dict | None, fallback: str = "") -> str:
    """addon 一句话简介：优先中文，其次 manifest 描述。"""
    name = str((manifest or {}).get("name") or fallback or "")
    return DESC_ZH.get(_name_key(name), str((manifest or {}).get("description") or "").strip())


FETCH_TIMEOUT = 20
MAX_REPO_BYTES = 8 * 1024 * 1024
MAX_MANIFEST_BYTES = 1024 * 1024
MAX_PROXY_BYTES = 8 * 1024 * 1024
MAX_ADDONS_PER_REPO = 1000
USER_AGENT = "RexHub-Stremio/1.0"

_IO_LOCK = threading.RLock()


class UpstreamError(Exception):
    """上游 addon 请求失败，路由层转成 502。"""


def _locked(func):
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        with _IO_LOCK:
            return func(*args, **kwargs)

    return wrapper


def _empty() -> dict[str, Any]:
    return {"repositories": [], "addons": []}


def _read() -> dict[str, Any]:
    try:
        data = json.loads(ADDONS_PATH.read_text("utf-8"))
    except (OSError, ValueError):
        return _empty()
    if not isinstance(data, dict):
        return _empty()
    repos = [
        item
        for item in data.get("repositories") or []
        if isinstance(item, dict) and item.get("url")
    ]
    addons = [
        item
        for item in data.get("addons") or []
        if isinstance(item, dict) and item.get("slug") and isinstance(item.get("manifest"), dict)
    ]
    return {"repositories": repos, "addons": addons}


def _write(data: dict[str, Any]) -> None:
    config.ensure_data_dir()
    with _IO_LOCK:
        tmp = ADDONS_PATH.with_name(
            f"{ADDONS_PATH.name}.{os.getpid()}.{threading.get_ident()}.tmp"
        )
        try:
            tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), "utf-8")
            os.chmod(tmp, 0o600)
            tmp.replace(ADDONS_PATH)
        finally:
            tmp.unlink(missing_ok=True)


def _text(value: object, limit: int = 300) -> str:
    return str(value or "").strip()[:limit]


def _http_url(value: str) -> str:
    target = (value or "").strip()
    parsed = urlparse(target)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("请填写 http(s) 开头的完整地址")
    return target


def normalize_transport(url: str) -> str:
    """把 manifest 地址归一到 transport 基址（去掉 /manifest.json）。"""
    target = _http_url(url).rstrip("/")
    if target.lower().endswith("/manifest.json"):
        target = target[: -len("/manifest.json")]
    return target.rstrip("/")


def manifest_url(transport: str) -> str:
    return f"{transport.rstrip('/')}/manifest.json"


def _fetch_json(url: str, limit: int) -> object:
    request = urllib.request.Request(
        network_store.rewrite_github(url),
        headers={"User-Agent": USER_AGENT, "Accept": "application/json, */*"},
    )
    try:
        try:
            with network_store.open_url(request, FETCH_TIMEOUT, "plugins") as response:
                raw = response.read(limit + 1)
        except urllib.error.HTTPError:
            raise
        except (urllib.error.URLError, TimeoutError, OSError):
            if not network_store.proxy_in_use("plugins"):
                raise
            # 部分站点经代理会 TLS 握手失败，直连重试一次
            with network_store.open_direct(request, FETCH_TIMEOUT) as response:
                raw = response.read(limit + 1)
    except urllib.error.HTTPError as exc:
        raise ValueError(f"地址返回 HTTP {exc.code}") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise ValueError("无法访问地址，请检查网络或代理") from exc
    if len(raw) > limit:
        raise ValueError("返回内容超过大小限制")
    head = raw[:200].lstrip().lower()
    if head.startswith((b"<!doctype", b"<html")):
        raise ValueError("该地址是网页而不是 addon 数据，请填写仓库 JSON 或 addon 的 manifest.json 地址")
    try:
        return json.loads(raw.decode("utf-8", "replace"))
    except ValueError as exc:
        raise ValueError("返回内容不是合法 JSON") from exc


def _manifest_of(value: object) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None
    manifest = value.get("manifest")
    if isinstance(manifest, dict):
        return manifest
    if value.get("id") and (value.get("resources") or value.get("types")):
        return value
    return None


def _entries(doc: object) -> list:
    if isinstance(doc, list):
        return doc
    if isinstance(doc, dict):
        for key in ("addons", "items"):
            items = doc.get(key)
            if isinstance(items, list):
                return items
        if doc.get("transportUrl") or _manifest_of(doc):
            return [doc]
    raise ValueError("仓库格式不正确：需要 addon 列表或单个 manifest")


def _entry_targets(doc: object) -> list[tuple[str, dict[str, Any] | None, str]]:
    """整理成 (transport, manifest 或 None, 错误) 列表，manifest 缺失的稍后拉取。"""
    rows: list[tuple[str, dict[str, Any] | None, str]] = []
    for entry in _entries(doc)[:MAX_ADDONS_PER_REPO]:
        if isinstance(entry, str):
            url = entry.strip()
            if not url:
                continue
            try:
                rows.append((normalize_transport(url), None, ""))
            except ValueError as exc:
                rows.append(("", None, str(exc)))
            continue
        if not isinstance(entry, dict):
            continue
        manifest = _manifest_of(entry)
        raw_url = _text(entry.get("transportUrl") or entry.get("url"), 600)
        if not raw_url:
            rows.append(("", manifest, "缺少 transportUrl"))
            continue
        try:
            transport = normalize_transport(raw_url)
        except ValueError as exc:
            rows.append(("", manifest, str(exc)))
            continue
        rows.append((transport, manifest, ""))
    return rows


def _load_entries(doc: object) -> list[tuple[str, dict[str, Any], str]]:
    """补齐缺失的 manifest，返回 (transport, manifest, 错误)。"""
    targets = _entry_targets(doc)
    missing = [item for item in targets if item[1] is None and item[0]]

    fetched: dict[str, tuple[dict[str, Any] | None, str]] = {}

    def one(transport: str) -> None:
        try:
            manifest = _manifest_of(_fetch_json(manifest_url(transport), MAX_MANIFEST_BYTES))
        except ValueError as exc:
            fetched[transport] = (None, str(exc))
            return
        fetched[transport] = (manifest, "" if manifest else "manifest 格式不正确")

    if missing:
        with ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(one, [item[0] for item in missing]))

    result: list[tuple[str, dict[str, Any], str]] = []
    seen: set[str] = set()
    for transport, manifest, error in targets:
        if not transport:
            continue
        if manifest is None:
            manifest, fetch_error = fetched.get(transport, (None, error or "manifest 获取失败"))
            error = fetch_error
        if manifest is None:
            continue
        addon_id = _text(manifest.get("id"), 200)
        if not addon_id:
            continue
        if addon_id in seen:
            continue
        seen.add(addon_id)
        result.append((transport, manifest, error))
    return result


def _slug_base(addon_id: str) -> str:
    base = re.sub(r"[^A-Za-z0-9._-]", "_", addon_id).strip("._-")[:80]
    return base or "addon"


def _assign_slug(addon_id: str, transport: str, addons: list[dict], keep: str = "") -> str:
    if keep:
        return keep
    used = {str(row.get("slug")) for row in addons if row.get("transport") != transport}
    base = _slug_base(addon_id)
    if base not in used:
        return base
    suffix = hashlib.sha1(transport.encode("utf-8")).hexdigest()[:6]
    candidate = f"{base}-{suffix}"
    index = 2
    while candidate in used:
        candidate = f"{base}-{suffix}-{index}"
        index += 1
    return candidate


def _repo_title(url: str, title: str) -> str:
    picked = (title or "").strip()
    if picked:
        return picked[:200]
    for name, preset in REPOSITORY_PRESETS:
        if preset == url:
            return name
    return urlparse(url).netloc or url


@_locked
def _upsert_repository(
    url: str, title: str, entries: list[tuple[str, dict[str, Any], str]], error: str
) -> dict[str, Any]:
    data = _read()
    now = int(time.time())
    others = [row for row in data["addons"] if row.get("repository") != url]
    kept = {str(row.get("transport")): row for row in data["addons"] if row.get("repository") == url}

    fresh: list[dict[str, Any]] = []
    for transport, manifest, entry_error in entries:
        old = kept.get(transport) or {}
        addon_id = _text(manifest.get("id"), 200)
        fresh.append(
            {
                "slug": _assign_slug(addon_id, transport, others + fresh, str(old.get("slug") or "")),
                "id": addon_id,
                "transport": transport,
                "manifest_url": manifest_url(transport),
                "manifest": manifest,
                "repository": url,
                "enabled": bool(old.get("enabled", True)),
                "added_at": int(old.get("added_at") or now),
                "updated_at": now,
                "error": entry_error,
            }
        )

    data["addons"] = others + fresh
    repo = next((row for row in data["repositories"] if row.get("url") == url), None)
    if repo is None:
        repo = {"url": url, "created_at": now}
        data["repositories"].append(repo)
    repo.update(
        {
            "title": _repo_title(url, title),
            "fetched_at": now,
            "error": error,
            "count": len(fresh),
        }
    )
    _write(data)
    return {"url": url, "title": repo["title"], "count": len(fresh), "error": error}


def add_repository(url: str, title: str = "") -> dict[str, Any]:
    target = _http_url(url).rstrip("/")
    if target.lower().endswith("/manifest.json"):
        # 单个 manifest 地址：按单个 addon 接入
        addon = add_addon(target)
        return {
            "url": addon["transport"],
            "title": str(title or addon["manifest"].get("name") or addon["id"]),
            "count": 1,
        }
    with _IO_LOCK:
        exists = any(row.get("url") == target for row in _read()["repositories"])
    if exists:
        return refresh_repository(target)
    try:
        doc = _fetch_json(target, MAX_REPO_BYTES)
    except ValueError as exc:
        raise ValueError(str(exc)) from exc
    if isinstance(doc, dict) and not (
        isinstance(doc.get("addons"), list)
        or isinstance(doc.get("items"), list)
        or doc.get("transportUrl")
    ):
        manifest = _manifest_of(doc)
        if manifest is not None:
            # 直接粘贴单个 manifest 地址时，按单个 addon 接入
            addon = add_addon(target)
            return {
                "url": addon["transport"],
                "title": str(title or manifest.get("name") or addon["id"]),
                "count": 1,
            }
    entries = _load_entries(doc)
    if not entries:
        raise ValueError("仓库里没有可用的 addon")
    return _upsert_repository(target, title, entries, "")


def refresh_repository(url: str) -> dict[str, Any]:
    target = _http_url(url).rstrip("/")
    data = _read()
    repo = next((row for row in data["repositories"] if row.get("url") == target), None)
    if repo is None:
        raise ValueError("仓库不存在")
    try:
        doc = _fetch_json(target, MAX_REPO_BYTES)
        entries = _load_entries(doc)
    except ValueError as exc:
        repo = dict(repo)
        repo.update({"error": str(exc), "fetched_at": int(time.time())})
        with _IO_LOCK:
            latest = _read()
            for index, row in enumerate(latest["repositories"]):
                if row.get("url") == target:
                    latest["repositories"][index] = {**row, **repo}
            _write(latest)
        raise ValueError(str(exc)) from exc
    if not entries:
        raise ValueError("仓库里没有可用的 addon")
    return _upsert_repository(target, str(repo.get("title") or ""), entries, "")


@_locked
def delete_repository(url: str) -> bool:
    target = _http_url(url).rstrip("/")
    data = _read()
    remain = [row for row in data["repositories"] if row.get("url") != target]
    if len(remain) == len(data["repositories"]):
        return False
    data["repositories"] = remain
    data["addons"] = [row for row in data["addons"] if row.get("repository") != target]
    _write(data)
    return True


def add_addon(url: str) -> dict[str, Any]:
    transport = normalize_transport(url)
    manifest = _manifest_of(_fetch_json(manifest_url(transport), MAX_MANIFEST_BYTES))
    if manifest is None:
        raise ValueError("该地址返回的不是 addon manifest")
    addon_id = _text(manifest.get("id"), 200)
    if not addon_id:
        raise ValueError("manifest 缺少 id")
    with _IO_LOCK:
        data = _read()
        old = next((row for row in data["addons"] if row.get("transport") == transport), None)
        now = int(time.time())
        row = {
            "slug": _assign_slug(
                addon_id, transport, data["addons"], str((old or {}).get("slug") or "")
            ),
            "id": addon_id,
            "transport": transport,
            "manifest_url": manifest_url(transport),
            "manifest": manifest,
            "repository": (old or {}).get("repository") or "",
            "enabled": bool((old or {}).get("enabled", True)),
            "added_at": int((old or {}).get("added_at") or now),
            "updated_at": now,
            "error": "",
        }
        if old is None:
            data["addons"].append(row)
        else:
            data["addons"] = [
                row if item.get("transport") == transport else item for item in data["addons"]
            ]
        _write(data)
        return row


def refresh_addon(slug: str) -> dict[str, Any]:
    row = find_any(slug)
    if row is None:
        raise ValueError("addon 不存在")
    transport = str(row.get("transport") or "")
    manifest = _manifest_of(_fetch_json(manifest_url(transport), MAX_MANIFEST_BYTES))
    if manifest is None:
        raise ValueError("manifest 格式不正确")
    with _IO_LOCK:
        data = _read()
        for item in data["addons"]:
            if item.get("slug") == slug:
                item.update({"manifest": manifest, "updated_at": int(time.time()), "error": ""})
        _write(data)
    return find_any(slug) or row


def test_addon(slug: str) -> dict[str, Any]:
    """探测 addon 是否可用：拉取 manifest，再试一次它的首个目录。"""
    row = find_any(slug)
    if row is None:
        raise ValueError("addon 不存在")
    transport = str(row.get("transport") or "")
    started = time.monotonic()

    def elapsed() -> int:
        return int((time.monotonic() - started) * 1000)

    try:
        manifest = _manifest_of(_fetch_json(manifest_url(transport), MAX_MANIFEST_BYTES))
    except ValueError as exc:
        return {"ok": False, "ms": elapsed(), "message": f"manifest 请求失败：{exc}"}
    if manifest is None:
        return {"ok": False, "ms": elapsed(), "message": "manifest 格式不正确"}

    catalog = next(
        (
            item
            for item in manifest.get("catalogs") or []
            if isinstance(item, dict)
            and item.get("type")
            and item.get("id")
            and not item.get("extraRequired")
        ),
        None,
    )
    if catalog:
        path = (
            f"catalog/{quote(str(catalog['type']), safe='')}"
            f"/{quote(str(catalog['id']), safe='')}.json"
        )
        try:
            status, _ = proxy_get(row, path)
        except UpstreamError as exc:
            return {"ok": False, "ms": elapsed(), "message": f"目录请求失败：{exc}"}
        if status >= 400:
            return {"ok": False, "ms": elapsed(), "message": f"目录返回 HTTP {status}"}

    detail = "manifest 正常"
    if catalog:
        detail += " · 目录可访问"
    return {"ok": True, "ms": elapsed(), "message": detail}


@_locked
def set_addon_enabled(slug: str, enabled: bool) -> bool:
    data = _read()
    row = next((item for item in data["addons"] if item.get("slug") == slug), None)
    if row is None:
        return False
    row["enabled"] = enabled
    row["updated_at"] = int(time.time())
    _write(data)
    return True


@_locked
def delete_addon(slug: str) -> bool:
    data = _read()
    remain = [item for item in data["addons"] if item.get("slug") != slug]
    if len(remain) == len(data["addons"]):
        return False
    data["addons"] = remain
    _write(data)
    return True


def find_any(slug: str) -> dict[str, Any] | None:
    return next((row for row in _read()["addons"] if row.get("slug") == slug), None)


def find_by_slug(slug: str) -> dict[str, Any] | None:
    row = find_any(slug)
    if row is None or not row.get("enabled", True):
        return None
    return row


def snapshot() -> dict[str, Any]:
    data = _read()
    return {
        "repositories": data["repositories"],
        "addons": data["addons"],
        "stats": {
            "repositories": len(data["repositories"]),
            "addons": len(data["addons"]),
            "enabled": sum(1 for row in data["addons"] if row.get("enabled", True)),
        },
    }


def proxy_get(row: dict[str, Any], path: str, query: str = "") -> tuple[int, object]:
    """把 /stremio/{slug}/{path} 转发到 addon 的 transport 地址。"""
    clean = (path or "").lstrip("/")
    if not clean or clean.startswith("//") or ".." in clean or "://" in clean:
        raise UpstreamError("非法的 addon 路径")
    if not clean.endswith(".json"):
        raise UpstreamError("addon 路径必须以 .json 结尾")
    base = str(row.get("transport") or "").rstrip("/")
    url = f"{base}/{clean}"
    if query:
        url = f"{url}?{query}"
    request = urllib.request.Request(
        url,
        headers={"User-Agent": USER_AGENT, "Accept": "application/json, */*"},
    )
    try:
        try:
            with network_store.open_url(request, FETCH_TIMEOUT, "plugins") as response:
                status = int(getattr(response, "status", None) or response.getcode() or 200)
                raw = response.read(MAX_PROXY_BYTES + 1)
        except urllib.error.HTTPError:
            raise
        except (urllib.error.URLError, TimeoutError, OSError):
            if not network_store.proxy_in_use("plugins"):
                raise
            # 代理握手失败时直连重试
            with network_store.open_direct(request, FETCH_TIMEOUT) as response:
                status = int(getattr(response, "status", None) or response.getcode() or 200)
                raw = response.read(MAX_PROXY_BYTES + 1)
    except urllib.error.HTTPError as exc:
        status = int(exc.code)
        raw = exc.read(MAX_PROXY_BYTES + 1)
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise UpstreamError("无法连接 addon 上游") from exc
    if len(raw) > MAX_PROXY_BYTES:
        raise UpstreamError("上游返回内容过大")
    try:
        return status, json.loads(raw.decode("utf-8", "replace"))
    except ValueError as exc:
        raise UpstreamError("上游返回的不是合法 JSON") from exc
