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

按职责拆分为以下子模块，公共 API 由本 __init__ 显式 re-export，
`from app.rexhub import addons_store` 的用法保持不变：

- storage:      data/addons.json 的持久化读写与进程内写锁
- urls:         addon 地址校验与 transport / manifest 地址互转
- fetch:        上游 HTTP 拉取（仓库 / manifest / 代理转发）与限额
- manifest:     仓库文档解析、字段提取、slug 分配与 manifest 并发补拉
- translations: addon 名称/简介的中文名称映射
- catalog:      仓库的添加、刷新、删除
- addons:       单个 addon 的接入、刷新、启停、探测与查询
"""

from . import (  # noqa: F401
    addons,
    catalog,
    fetch,
    manifest,
    names_zh_1,
    names_zh_2,
    storage,
    translations,
    urls,
)
from .addons import (
    add_addon,
    delete_addon,
    find_any,
    find_by_slug,
    refresh_addon,
    set_addon_enabled,
    snapshot,
    test_addon,
)
from .catalog import (
    OFFICIAL_REPOSITORY,
    REPOSITORY_PRESETS,
    add_repository,
    delete_repository,
    refresh_repository,
)
from .fetch import (
    FETCH_TIMEOUT,
    MAX_MANIFEST_BYTES,
    MAX_PROXY_BYTES,
    MAX_REPO_BYTES,
    USER_AGENT,
    UpstreamError,
    proxy_get,
)
from .manifest import MAX_ADDONS_PER_REPO
from .storage import ADDONS_PATH
from .translations import DESC_ZH, NAME_ZH
from .urls import manifest_url, normalize_transport
