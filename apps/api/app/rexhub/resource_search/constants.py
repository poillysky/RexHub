"""检索调优常量：候选池扩容、语句超时与候选缓存容量。"""


RESULT_LIMIT = 50  # 每页条数
PAGE_CANDIDATES = 500  # 单个库单次检索的初始候选池
MAX_CANDIDATES = 3000  # 单个库单关键词最多保留的候选，再多的部分标记为未取全
CANDIDATE_GROWTH = 2  # 翻页超出候选池时按倍数扩容
MAX_TOKENS = 4  # 关键词最多拆几个词参与匹配
CONNECT_TIMEOUT = 3.0
# 结果页会在超时后静默续搜，服务端给足一次扫描的时间，尽量一次跑完
STATEMENT_TIMEOUT_MS = 20000
# bitmagnet 库有数百万条英文标题，中文关键词只能全表扫描，给更长的超时并允许退化返回
BITMAGNET_TIMEOUT_MS = 20000
CACHE_TTL = 300  # 候选池缓存秒数：翻页与重复搜索直接复用
CACHE_MAX = 64
