"""统一响应信封：所有 /api 业务端点返回 ``{status, message, data}``。

全仓只有这一份定义；各 routes 模块直接 ``from app.core.envelope import Envelope``。
"""


from typing import Any

from pydantic import BaseModel


class Envelope(BaseModel):
    data: Any = None
    message: str = "ok"
    status: int = 200
