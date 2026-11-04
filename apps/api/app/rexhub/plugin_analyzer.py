"""ForwardWidget 源码静态解析。

用 esprima 建立真实 AST，提取插件声明结构：WidgetMetadata、每个模块的
functionName/参数、函数内发起的上游请求（URL、方法、参数）与返回字段。
只做静态分析，不执行代码；REXENC / FWENC 密文无法解析。
"""

from __future__ import annotations

from typing import Any, Iterator

import esprima
from esprima import nodes

MAX_MODULES = 100
MAX_PARAMS = 50
MAX_REQUESTS = 20
MAX_ENDPOINTS = 50

REQUEST_CALLEES = {
    "fetch",
    "request",
    "got",
    "ajax",
    "httpGet",
    "httpPost",
    "Widget.http.get",
    "Widget.http.post",
    "Widget.http.request",
}


def _walk(node: nodes.Node) -> Iterator[nodes.Node]:
    stack = [node]
    while stack:
        current = stack.pop()
        if not isinstance(current, nodes.Node):
            continue
        yield current
        for value in vars(current).values():
            if isinstance(value, list):
                stack.extend(item for item in value if isinstance(item, nodes.Node))
            elif isinstance(value, nodes.Node):
                stack.append(value)


def _prop_name(prop: nodes.Node) -> str:
    key = getattr(prop, "key", None)
    if key is None:
        return ""
    return str(getattr(key, "name", None) or getattr(key, "value", None) or "")


def _literal(node: nodes.Node | None) -> Any:
    """只还原字面量；表达式（函数调用、拼接）返回 None。"""
    if node is None:
        return None
    if isinstance(node, nodes.Literal):
        return node.value
    if isinstance(node, nodes.TemplateLiteral):
        if getattr(node, "expressions", None):
            return None
        return "".join(str((quasi.value or {}).get("cooked") or "") for quasi in node.quasis)
    if isinstance(node, nodes.ArrayExpression):
        return [_literal(item) for item in node.elements]
    if isinstance(node, nodes.ObjectExpression):
        return {_prop_name(prop): _literal(prop.value) for prop in node.properties}
    if isinstance(node, nodes.UnaryExpression) and node.operator == "-":
        value = _literal(node.argument)
        return -value if isinstance(value, (int, float)) else None
    return None


def _object(node: nodes.Node | None) -> dict[str, Any]:
    value = _literal(node)
    return value if isinstance(value, dict) else {}


def _params(node: nodes.Node | None) -> list[dict[str, Any]]:
    if isinstance(node, nodes.CallExpression):
        return [{"name": "", "title": "", "type": f"expr:{_callee_path(node.callee)}", "default": None}]
    if not isinstance(node, nodes.ArrayExpression):
        return []
    rows: list[dict[str, Any]] = []
    for element in node.elements[:MAX_PARAMS]:
        item = _literal(element)
        if isinstance(item, dict):
            rows.append(
                {
                    "name": str(item.get("name") or ""),
                    "title": str(item.get("title") or ""),
                    "type": str(item.get("type") or ""),
                    "default": item.get("value"),
                }
            )
        elif isinstance(element, nodes.CallExpression):
            callee = element.callee
            name = getattr(callee, "name", "") or getattr(getattr(callee, "property", None), "name", "")
            rows.append({"name": "", "title": "", "type": f"expr:{name}", "default": None})
    return rows


def _callee_name(node: nodes.Node) -> str:
    if isinstance(node, nodes.Identifier):
        return node.name
    if isinstance(node, (nodes.StaticMemberExpression, nodes.ComputedMemberExpression)):
        prop = getattr(node, "property", None)
        return str(getattr(prop, "name", None) or getattr(prop, "value", None) or "")
    return ""


def _callee_path(node: nodes.Node) -> str:
    """还原 Widget.http.get / fetch 这类完整调用路径。"""
    if isinstance(node, nodes.Identifier):
        return node.name
    if isinstance(node, nodes.StaticMemberExpression):
        base = _callee_path(node.object)
        prop = str(getattr(node.property, "name", "") or "")
        return f"{base}.{prop}" if base else prop
    return _callee_name(node)


def _url_literals(body: nodes.Node, functions: dict[str, nodes.Node] | None = None, depth: int = 1) -> list[str]:
    """函数内出现的接口路径字面量（URL 常由变量拼接，取片段辅助定位）。"""
    seen: list[str] = []
    helpers: list[str] = []
    for node in _walk(body):
        if isinstance(node, nodes.Literal) and isinstance(node.value, str):
            value = node.value
            if value.startswith(("/", "http://", "https://")) and len(value) <= 200 and value not in seen:
                seen.append(value)
        elif isinstance(node, nodes.CallExpression) and isinstance(node.callee, nodes.Identifier):
            if node.callee.name in (functions or {}):
                helpers.append(node.callee.name)
    if depth > 0 and functions:
        for helper in dict.fromkeys(helpers):
            for value in _url_literals(functions[helper], functions, depth - 1):
                if value not in seen:
                    seen.append(value)
    return seen[:MAX_ENDPOINTS]


def _requests(body: nodes.Node, functions: dict[str, nodes.Node] | None = None, depth: int = 2) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    helpers: list[str] = []
    for node in _walk(body):
        if not isinstance(node, nodes.CallExpression):
            continue
        name = _callee_path(node.callee)
        if name not in REQUEST_CALLEES:
            if isinstance(node.callee, nodes.Identifier) and node.callee.name in (functions or {}):
                helpers.append(node.callee.name)
            continue
        args = getattr(node, "arguments", []) or []
        url = _literal(args[0]) if args else None
        options = _object(args[1]) if len(args) > 1 else {}
        headers = options.get("headers") if isinstance(options.get("headers"), dict) else {}
        payload = options.get("body") or options.get("data") or options.get("params")
        rows.append(
            {
                "callee": name,
                "url": url if isinstance(url, str) else "",
                "method": str(options.get("method") or "GET"),
                "headers": sorted(headers) if isinstance(headers, dict) else [],
                "params": sorted(payload) if isinstance(payload, dict) else [],
            }
        )
        if len(rows) >= MAX_REQUESTS:
            break
    if depth > 0 and functions:
        for helper in dict.fromkeys(helpers):
            rows.extend(_requests(functions[helper], functions, depth - 1))
    return rows[:MAX_REQUESTS]


def _returns(body: nodes.Node) -> list[str]:
    keys: list[str] = []
    for node in _walk(body):
        if isinstance(node, nodes.ReturnStatement) and isinstance(node.argument, nodes.ObjectExpression):
            for prop in node.argument.properties:
                name = _prop_name(prop)
                if name and name not in keys:
                    keys.append(name)
    return keys[:MAX_PARAMS]


def _is_function(node: nodes.Node) -> bool:
    return isinstance(
        node,
        (
            nodes.FunctionExpression,
            nodes.ArrowFunctionExpression,
            nodes.AsyncFunctionExpression,
            nodes.AsyncArrowFunctionExpression,
        ),
    )


def _functions(tree: nodes.Node) -> dict[str, nodes.Node]:
    found: dict[str, nodes.Node] = {}
    for node in _walk(tree):
        if isinstance(node, (nodes.FunctionDeclaration, nodes.AsyncFunctionDeclaration)) and node.id is not None:
            found.setdefault(node.id.name, node)
        elif isinstance(node, nodes.VariableDeclarator) and _is_function(node.init):
            if isinstance(node.id, nodes.Identifier):
                found.setdefault(node.id.name, node.init)
        elif isinstance(node, nodes.AssignmentExpression) and _is_function(node.right):
            name = _callee_name(node.left)
            if name:
                found.setdefault(name, node.right)
    return found


def _metadata(tree: nodes.Node) -> dict[str, Any] | None:
    for node in _walk(tree):
        target = None
        if isinstance(node, nodes.VariableDeclarator) and isinstance(node.id, nodes.Identifier) and node.id.name == "WidgetMetadata":
            target = node.init
        elif isinstance(node, nodes.AssignmentExpression) and _callee_name(node.left) == "WidgetMetadata":
            target = node.right
        if isinstance(target, nodes.ObjectExpression):
            return {prop.key.name if isinstance(prop.key, nodes.Identifier) else str(getattr(prop.key, "value", "")): prop.value for prop in target.properties}
    return None


def analyze(source: str) -> dict[str, Any]:
    text = (source or "").strip()
    if not text:
        return {"ok": False, "encrypted": False, "error": "源码为空"}
    if text[:16].upper().startswith(("FWENC", "REXENC")):
        return {"ok": False, "encrypted": True, "error": "模块已加密（REXENC），需明文源码才能解析"}

    try:
        tree = esprima.parseScript(text)
    except Exception as exc:  # noqa: BLE001 - 语法错误统一转成可展示信息
        return {"ok": False, "encrypted": False, "error": f"语法解析失败：{exc}"}

    meta = _metadata(tree)
    if meta is None:
        return {"ok": False, "encrypted": False, "error": "未找到 WidgetMetadata 定义"}

    modules: list[dict[str, Any]] = []
    modules_node = meta.get("modules")
    if isinstance(modules_node, nodes.ArrayExpression):
        for element in modules_node.elements[:MAX_MODULES]:
            if not isinstance(element, nodes.ObjectExpression):
                continue
            item = _object(element)
            modules.append(
                {
                    "id": str(item.get("id") or ""),
                    "title": str(item.get("title") or ""),
                    "type": str(item.get("type") or ""),
                    "mediaType": str(item.get("mediaType") or ""),
                    "function": str(item.get("functionName") or ""),
                    "params": _params(next((p.value for p in element.properties if _prop_name(p) == "params"), None)),
                }
            )

    functions = _functions(tree)
    calls: dict[str, dict[str, Any]] = {}

    search: dict[str, Any] | None = None
    search_node = meta.get("search")
    if isinstance(search_node, nodes.ObjectExpression):
        item = _object(search_node)
        search = {
            "title": str(item.get("title") or ""),
            "function": str(item.get("functionName") or ""),
            "params": _params(next((p.value for p in search_node.properties if _prop_name(p) == "params"), None)),
        }

    for module in modules + ([search] if search else []):
        name = module["function"]
        body = functions.get(name)
        if not name or body is None or name in calls:
            continue
        calls[name] = {
            "requests": _requests(body, functions),
            "returns": _returns(body),
            "endpoints": _url_literals(body, functions),
        }

    endpoints = sorted(
        {
            row["url"]
            for item in calls.values()
            for row in item["requests"]
            if row["url"]
        }
        | {path for item in calls.values() for path in item["endpoints"]}
    )[:MAX_ENDPOINTS]
    return {
        "ok": True,
        "encrypted": False,
        "metadata": {
            "id": str(_literal(meta.get("id")) or ""),
            "title": str(_literal(meta.get("title")) or ""),
            "version": str(_literal(meta.get("version")) or ""),
            "author": str(_literal(meta.get("author")) or ""),
            "description": str(_literal(meta.get("description")) or ""),
            "global_params": [
                {"name": str((row or {}).get("name") or ""), "default": (row or {}).get("value")}
                for row in (_literal(meta.get("globalParams")) or [])
                if isinstance(row, dict)
            ][:20],
        },
        "modules": modules,
        "search": search,
        "functions": calls,
        "endpoints": endpoints,
    }
