"""List the workspace library: every collection (space), its home page and page counts."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _waxwing as wx  # noqa: E402


def run() -> dict:
    status, lib = wx.get("/api/library")
    if status != 200 or not isinstance(lib, dict):
        return {"error": wx.auth_hint(status) or f"readLibrary failed ({status})", "detail": wx.clip(lib, 300)}
    entries = lib.get("entries") or lib.get("pages") or lib.get("items") or []
    out = []
    for c in lib.get("collections", []) or []:
        n = sum(1 for e in entries if isinstance(e, dict) and e.get("collectionId") == c.get("id"))
        out.append({"id": c.get("id"), "title": c.get("title"), "description": c.get("description"),
                    "home": (c.get("home") or {}).get("title"), "url": f"/?collection={c.get('id')}", "pages": n})
    return {"libraryVersion": lib.get("version"), "collections": out, "totalEntries": len(entries), "topLevelKeys": sorted(lib.keys())}
