"""RexHub Plugin Framework。

对外只暴露 ``manager`` 门面与会话所需的初始化函数；具体实现按职责拆分：

- ``manifest``      插件协议与校验
- ``store``         仓库/插件存储与旧模块迁移
- ``repositories``  多 GitHub 仓库索引与下载
- ``installer``     安装、更新、回滚、卸载
- ``runtime``       Shared / Isolated / Container 运行时
- ``dispatcher``    能力注册与调度
- ``manager``       统一门面
"""


from app.rexhub.plugin_framework import manager

initialize = manager.initialize

__all__ = ["manager", "initialize"]
