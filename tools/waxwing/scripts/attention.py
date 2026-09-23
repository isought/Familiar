"""List pages whose citations point at content that changed since they were written (the 'keep docs true' queue)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _waxwing as wx  # noqa: E402


def run() -> dict:
    status, res = wx.get("/api/attention")
    if status != 200:
        return {"error": wx.auth_hint(status) or f"readAttention failed ({status})", "detail": wx.clip(res, 300)}
    items = res.get("pages") if isinstance(res, dict) else res
    return {"count": len(items) if isinstance(items, list) else None,
            "pages": [wx.pick(p, "title", "itemId", "url") | {"changed": len(p.get("citations") or [])} for p in (items or [])[:15] if isinstance(p, dict)],
            "raw": wx.clip(res, 800) if not isinstance(items, list) else None}
