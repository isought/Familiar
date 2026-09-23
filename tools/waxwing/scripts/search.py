"""Search the Waxwing workspace (pages, models, saved history) and return where each result lives.

Args:
    q: Search words.
    collection: Optional collection id to limit the search.
    history: Also search earlier saved versions.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _waxwing as wx  # noqa: E402


def run(q: str, collection: str = "", history: bool = False) -> dict:
    status, res = wx.get("/api/search", {"q": q, "collection": collection, "history": "true" if history else None})
    if status != 200:
        return {"error": wx.auth_hint(status) or f"search failed ({status})", "detail": wx.clip(res, 300)}
    results = res.get("results") if isinstance(res, dict) else res
    trimmed = []
    for r in (results or [])[:15]:
        if isinstance(r, dict):
            trimmed.append(wx.pick(r, "label", "title", "source", "kind", "url", "collectionId", "itemId", "sourceVersionId", "digest") | {"snippet": wx.clip(r.get("snippet") or r.get("excerpt") or "", 200)})
    return {"count": len(results) if isinstance(results, list) else None, "results": trimmed}
