"""番号键归一适配：统一委托 search_av.std_code_key（四位国产、丢分集）。"""


def _std_code_key(code: str, *, pad: int = 3) -> str:
    """统一番号键（委托 search_av.std_code_key：四位国产、丢分集）。"""
    from app.search.av import std_code_key

    return std_code_key(code, pad=pad)
