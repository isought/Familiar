"""Shared helper for the Waxwing tool pack (not a tool itself: underscore prefix)."""
import json
import os
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_URL = "http://127.0.0.1:4310"


def context() -> dict:
    try:
        return json.loads(os.environ.get("FAMILIAR_CONTEXT", "{}"))
    except Exception:
        return {}


def _read_token_file() -> dict:
    """token file in the pack dir: either the bare token, or KEY=VALUE lines."""
    out = {}
    tool_dir = os.environ.get("FAMILIAR_TOOL_DIR") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(tool_dir, "token")
    if not os.path.exists(path):
        return out
    text = open(path, encoding="utf-8").read().strip()
    if "=" not in text.splitlines()[0]:
        out["WAXWING_API_TOKEN"] = text.splitlines()[0].strip()
        return out
    for line in text.splitlines():
        if "=" in line and not line.strip().startswith("#"):
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def settings():
    f = _read_token_file()
    token = os.environ.get("WAXWING_API_TOKEN") or f.get("WAXWING_API_TOKEN")
    base = os.environ.get("WAXWING_URL") or f.get("WAXWING_URL")
    if not base:
        url = context().get("url") or ""
        p = urllib.parse.urlparse(url)
        base = f"{p.scheme}://{p.netloc}" if p.scheme and p.netloc and ":4310" in p.netloc else DEFAULT_URL
    return base.rstrip("/"), token


def get(path: str, params=None):
    base, token = settings()
    url = base + path
    if params:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode({k: v for k, v in params.items() if v not in (None, "")})
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            body = r.read().decode("utf-8", "replace")
            return r.status, (json.loads(body) if body.strip().startswith(("{", "[")) else body)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        try:
            body = json.loads(body)
        except Exception:
            pass
        return e.code, body
    except Exception as e:  # connection refused etc.
        return 0, f"{type(e).__name__}: {e}"


def auth_hint(status: int):
    if status in (401, 403):
        return ("Waxwing API rejected the request (%d). Create a read token in the app: sign in, open "
                "'Account and access', create a named agent token, then paste it into Familiar Settings "
                "(right-click the bubble → Settings…) as WAXWING_API_TOKEN." % status)
    if status == 0:
        return "Could not reach the Waxwing app. Is it running at %s ?" % settings()[0]
    return None


def parse_url(url: str) -> dict:
    p = urllib.parse.urlparse(url or "")
    q = {k: v[0] for k, v in urllib.parse.parse_qs(p.query).items()}
    q["_path"] = p.path
    q["_fragment"] = p.fragment
    return q


def clip(s, n=600):
    s = s if isinstance(s, str) else json.dumps(s, default=str)
    return s if len(s) <= n else s[:n] + "…"


def pick(d: dict, *keys):
    return {k: d.get(k) for k in keys if isinstance(d, dict) and k in d}
