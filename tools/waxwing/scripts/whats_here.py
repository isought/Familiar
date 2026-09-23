"""Identify what the user is looking at in the Waxwing app from the browser URL, using the live API.

Resolves the URL's query (page, collection, item/record, revision, report, version) to the actual
workspace object: title, where it sits in the hierarchy, its current version, citations status and
a preview of the content. Call this first when the user is in Waxwing.

Args:
    url: Browser URL. Defaults to the current window's URL from the Familiar context.
    full_body: Include the full page Markdown instead of a preview.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _waxwing as wx  # noqa: E402


def _library():
    status, lib = wx.get("/api/library")
    return lib if status == 200 and isinstance(lib, dict) else None


def _collection_title(lib, cid):
    for c in (lib or {}).get("collections", []) or []:
        if c.get("id") == cid:
            return c.get("title")
    return None


def _page(page_id, version, full_body):
    if page_id == "new":
        return {"screen": "Page editor: writing a new page (draft kept in this browser tab until Save page)"}
    if page_id == "new-drawing":
        return {"screen": "Drawing editor: drawing a new canvas (Save drawing stores it)"}
    status, page = wx.get(f"/api/pages/{page_id}", {"version": version})
    if status in (400, 404):
        ds, drawing = wx.get(f"/api/drawings/{page_id}", {"version": version})
        if ds == 200 and isinstance(drawing, dict):
            vs = drawing.get("versions") or []
            return {"screen": "Drawing reader: a standalone hand-drawn canvas" + (f" (saved version {version})" if version else " (current version)"),
                    "title": drawing.get("title"), "versionCount": len(vs) if isinstance(vs, list) else None,
                    "collectionId": drawing.get("collectionId"), "apiPath": f"/api/drawings/{page_id}"}
    if status != 200 or not isinstance(page, dict):
        return {"error": wx.auth_hint(status) or f"readPage failed ({status})", "detail": wx.clip(page, 400)}
    lib = _library()
    body = page.get("body") or {}
    md = body.get("markdown") if isinstance(body, dict) else None
    cites = page.get("citations") or []
    by_status = {}
    for c in cites:
        by_status[c.get("status", "?")] = by_status.get(c.get("status", "?"), 0) + 1
    versions = page.get("versions") or []
    out = {
        "screen": "Page reader" + (f" showing saved version {version}" if version else " (current version)"),
        "title": page.get("title"),
        "collection": _collection_title(lib, page.get("collectionId")) or page.get("collectionId"),
        "ancestors": [a.get("title") for a in page.get("ancestors") or [] if isinstance(a, dict)],
        "children": [c.get("title") for c in page.get("children") or [] if isinstance(c, dict)],
        "currentVersionId": page.get("currentVersionId"),
        "versionCount": len(versions) if isinstance(versions, list) else None,
        "latestActor": (versions[-1].get("actor") if versions and isinstance(versions[-1], dict) else None),
        "linkedPages": [r.get("title") or r.get("itemId") for r in (page.get("links") or (body.get("references") if isinstance(body, dict) else None) or []) if isinstance(r, dict)],
        "citationStatus": by_status,
        "citationsNeedingAttention": [wx.pick(c, "status", "change", "target", "href") for c in cites if c.get("status") == "changed"][:5],
        "body": md if full_body else wx.clip(md or "", 700),
        "apiPath": f"/api/pages/{page_id}",
    }
    return {k: v for k, v in out.items() if v not in (None, [], {})}


def _collection(cid, view):
    lib = _library()
    if not lib:
        status, _ = wx.get("/api/library")
        return {"error": wx.auth_hint(status) or f"readLibrary failed ({status})"}
    special = {
        "inbox": "Inbox: entries that have no collection yet (Ready to organize / Unfiled pages)",
        "attention": "Needs attention: pages whose citations point at content that changed since they were written",
        "telemetry": "Telemetry: saved external dashboards (embeds) grouped by app",
        "repositories": "Connected repositories (owners only): Git sources used to regenerate explanations or refresh schemas",
        "access": "Account and access: sign out, invitations, members, agent tokens, password",
    }
    if cid in special:
        out = {"screen": special[cid]}
        if cid == "attention":
            st, res = wx.get("/api/attention")
            items = res.get("pages") if isinstance(res, dict) else res
            out["pagesNeedingAttention"] = [p.get("title") for p in (items or [])[:10] if isinstance(p, dict)] if st == 200 else wx.auth_hint(st)
        if cid == "inbox":
            entries = [e for e in (lib.get("entries") or []) if isinstance(e, dict) and not e.get("collectionId")]
            out["unfiled"] = [e.get("title") for e in entries][:20]
        return out
    if cid == "work-reports":
        status, reports = wx.get("/api/work-reports")
        items = reports.get("reports") if isinstance(reports, dict) else reports
        return {"screen": "Work reports list: immutable records of implementation work, with evidence and reviews",
                "reportCount": len(items) if isinstance(items, list) else None,
                "recent": [wx.pick(r, "id", "title", "submittedAt", "agent") for r in (items or [])[:5] if isinstance(r, dict)]}
    col = next((c for c in lib.get("collections", []) or [] if c.get("id") == cid), None)
    if not col:
        return {"error": f"No collection with id {cid} in the library", "collections": [c.get("title") for c in lib.get("collections", [])]}
    entries = [e for e in lib.get("entries", []) or lib.get("pages", []) or [] if isinstance(e, dict) and e.get("collectionId") == cid]
    roots = [e for e in entries if not e.get("parentPageId")]
    home = col.get("home") or {}
    out = {
        "screen": "Collection contents (all pages)" if view == "contents" else "Collection home (the page chosen as this space's front page)",
        "collection": col.get("title"),
        "description": col.get("description"),
        "homePage": home.get("title"),
        "pageCount": len(entries) or None,
        "rootPages": [e.get("title") for e in roots][:20],
        "libraryVersion": lib.get("version"),
    }
    if not home:
        out["note"] = "This collection has no home page set; the browser shows its contents or an empty state."
    return {k: v for k, v in out.items() if v not in (None, [], {})}


def _model(item_id, revision_id, record_id):
    rev = revision_id
    lib = _library()
    entry = None
    if lib and item_id:
        entry = next((e for e in (lib.get("entries") or lib.get("items") or []) if isinstance(e, dict) and e.get("id") == item_id), None)
        rev = rev or (entry or {}).get("latestRevisionId")
    if not rev:
        return {"error": "Could not resolve a model revision for this URL", "item": item_id, "entry": wx.clip(entry, 400) if entry else None}
    status, model = wx.get(f"/api/explanations/{rev}")
    if status != 200 or not isinstance(model, dict):
        status, model = wx.get(f"/api/explanations/{rev}/model")
    if status != 200 or not isinstance(model, dict):
        return {"error": wx.auth_hint(status) or f"readExplanation failed ({status})", "detail": wx.clip(model, 400)}
    notes = None
    if record_id:
        ns, nres = wx.get(f"/api/explanations/{rev}/records/{record_id}/notes")
        if ns == 200:
            notes = wx.clip(nres, 600)
    records = model.get("records") or []
    rec = next((r for r in records if isinstance(r, dict) and r.get("id") == record_id), None) if record_id else None
    out = {
        "screen": "Explanation reader: an imported model (architecture explanation or relational data model) shown as a diagram with an inspector" + (" (one record selected)" if record_id else ""),
        "title": model.get("title") or model.get("name") or (entry or {}).get("title"),
        "revisionId": rev,
        "recordCount": len(records) or None,
        "diagrams": [d.get("title") or d.get("id") for d in model.get("diagrams") or [] if isinstance(d, dict)][:10],
        "documentation": wx.clip(model.get("documentation") or model.get("explanation") or "", 700) or None,
        "digest": model.get("digest"),
        "createdAt": model.get("createdAt"),
        "record": wx.clip(rec, 900) if rec else None,
        "recordNotes": notes,
        "topLevelKeys": sorted(model.keys())[:25],
    }
    return {k: v for k, v in out.items() if v not in (None, [], {})}


def _report(report_id):
    status, rep = wx.get(f"/api/work-reports/{report_id}")
    if status != 200 or not isinstance(rep, dict):
        return {"error": wx.auth_hint(status) or f"readWorkReport failed ({status})", "detail": wx.clip(rep, 400)}
    r = rep.get("report") if isinstance(rep.get("report"), dict) else rep
    return {"screen": "Work report reader: an immutable record of implementation work, its evidence and checks",
            "summary": wx.pick(r, "id", "title", "summary", "agent", "submittedAt", "supersedesId", "successorId"),
            "findingCount": len(r.get("findings") or []) if isinstance(r.get("findings"), list) else None,
            "checks": wx.clip(r.get("checks"), 500) if r.get("checks") else None}


def run(url: str = "", full_body: bool = False) -> dict:
    url = url or wx.context().get("url") or ""
    q = wx.parse_url(url)
    if not url:
        return {"error": "No URL available. Is the Waxwing tab focused? Pass url explicitly."}
    if q["_path"].startswith("/api"):
        return {"screen": "API guide page (documentation for agents and terminals), not workspace content", "url": url}
    if q.get("_fragment", "").startswith("invite="):
        return {"screen": "Invitation acceptance: join this workspace using a privately shared link"}
    if q.get("page"):
        return _page(q["page"], q.get("version"), full_body)
    if q.get("report"):
        return _report(q["report"])
    if q.get("revision"):
        return _model(None, q["revision"], q.get("record"))
    if q.get("item"):
        lib = _library()
        entry = next((e for e in ((lib or {}).get("entries") or []) if isinstance(e, dict) and e.get("id") == q["item"]), None)
        if entry and entry.get("latestRevisionId"):
            return _model(q["item"], None, q.get("record"))
        return _page(q["item"], None, full_body)
    if q.get("snapshot"):
        status, snap = wx.get(f"/api/items/{q['snapshot']}/versions/{q.get('version')}")
        return {"screen": "Saved collection introduction / dashboard configuration (read-only saved version)",
                "title": snap.get("title") if isinstance(snap, dict) else None, "detail": wx.clip(snap, 500)}
    if q.get("q"):
        return {"screen": f"Search results overlay for “{q['q']}”" + (" including older revisions" if q.get("history") == "true" else ""),
                "hint": "Results open the exact saved version; Close search returns to the previous screen."}
    if q.get("collection"):
        return _collection(q["collection"], q.get("view"))
    lib = _library()
    if not lib:
        status, _ = wx.get("/api/library")
        return {"screen": "Workspace start page", "error": wx.auth_hint(status) or f"readLibrary failed ({status})"}
    return {"screen": "Workspace start page: the library of collections (spaces) and their home pages",
            "collections": [wx.pick(c, "title", "description") | {"home": (c.get("home") or {}).get("title")} for c in lib.get("collections", []) or []][:20],
            "libraryVersion": lib.get("version")}
