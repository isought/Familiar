"""Read what arrived in your mailbox recently, over IMAP, without changing anything.

Returns the messages that arrived in the last `since_hours` hours, newest first: sender, subject, time, whether it
is read, a short preview, and for Gmail the tab it landed in and Gmail's own Important marker. The mailbox is opened
read-only and every fetch is a PEEK, so nothing is ever marked read, moved or deleted.
"""
import email
import email.policy
import email.utils
import html
import imaplib
import math
import os
import re
from datetime import datetime, timedelta, timezone
from urllib.parse import quote as urlquote

HOSTS = {
    "gmail.com": "imap.gmail.com", "googlemail.com": "imap.gmail.com",
    "icloud.com": "imap.mail.me.com", "me.com": "imap.mail.me.com", "mac.com": "imap.mail.me.com",
    "yahoo.com": "imap.mail.yahoo.com", "ymail.com": "imap.mail.yahoo.com",
    "aol.com": "imap.aol.com",
    "fastmail.com": "imap.fastmail.com", "fastmail.fm": "imap.fastmail.com",
    "zoho.com": "imap.zoho.com",
    "outlook.com": "outlook.office365.com", "hotmail.com": "outlook.office365.com", "live.com": "outlook.office365.com",
}
GMAIL_TABS = ["primary", "social", "promotions", "updates", "forums"]
APP_PASSWORD_HELP = ("Use an app password, not the normal password: for Gmail, myaccount.google.com/apppasswords "
                     "(needs 2-Step Verification); for iCloud, account.apple.com → App-Specific Passwords.")
PREVIEW_BYTES = 16_384   # enough for the headers and the start of the text
BATCH = 50


class ServerRefused(Exception):
    """The server answered NO (busy, throttled): the read failed, which is not the same as an empty inbox."""


def run(since_hours: int = 24, mailbox: str = "INBOX", limit: int = 200) -> dict:
    """List the messages that arrived recently, newest first.

    Args:
        since_hours: how far back to look, in hours (1 to 168).
        mailbox: which mailbox to read (INBOX by default).
        limit: at most this many messages (1 to 500).
    """
    address = os.environ.get("MAIL_ADDRESS", "").strip()
    password = os.environ.get("MAIL_APP_PASSWORD", "").strip().replace(" ", "")
    if not address or not password:
        return {"error": "Mail isn't connected yet: add MAIL_ADDRESS and MAIL_APP_PASSWORD in Noteling Settings. "
                         + APP_PASSWORD_HELP}
    domain = address.rsplit("@", 1)[-1].lower()
    host = os.environ.get("MAIL_IMAP_HOST", "").strip() or HOSTS.get(domain)
    if not host:
        return {"error": f"Noteling doesn't know the mail server for {domain} yet."}
    since_hours = max(1, min(int(since_hours), 168))
    limit = max(1, min(int(limit), 500))
    cutoff = datetime.now(timezone.utc) - timedelta(hours=since_hours)

    try:
        conn = imaplib.IMAP4_SSL(host, 993, timeout=30)
    except OSError as e:
        return {"error": f"Couldn't reach {host} ({e}). Check your connection."}
    try:
        return read(conn, host, address, password, mailbox, cutoff, since_hours, limit)
    except ServerRefused as e:
        return {"error": f"{host} couldn't read {mailbox} right now ({e}). Try again in a few minutes."}
    finally:
        try:
            conn.logout()
        except Exception:  # noqa: BLE001
            pass


def read(conn, host, address, password, mailbox, cutoff, since_hours, limit):
    """Signs in, then lists what arrived since the cutoff. A NO from the server raises ServerRefused."""
    try:
        conn.login(address, password)
    except imaplib.IMAP4.error:
        return {"error": f"{host} turned down the sign-in for {address}. Check MAIL_ADDRESS and "
                         f"MAIL_APP_PASSWORD in Settings. " + APP_PASSWORD_HELP}
    status, _ = conn.select(quote(mailbox), readonly=True)   # EXAMINE: flags can't change
    if status != "OK":
        return {"error": f"There's no mailbox called {mailbox} on {host}."}
    gmail = "X-GM-EXT-1" in conn.capabilities

    # SINCE only knows whole days, so search a day wider and cut on each message's arrival time.
    day = (cutoff - timedelta(days=1)).strftime("%d-%b-%Y")
    status, data = conn.uid("SEARCH", None, "SINCE", day)
    if status != "OK":
        raise ServerRefused(f"search: {detail(data)}")
    candidates = data[0].split() if data and data[0] else []
    arrivals = {}
    for batch in chunks(candidates, 200):
        for meta, _ in fetch(conn, batch, "(UID INTERNALDATE)"):
            uid, when = field(meta, rb"UID (\d+)"), arrival(meta)
            if uid and when and when >= cutoff:
                arrivals[uid] = when
    newest = sorted(arrivals, key=arrivals.get, reverse=True)[:limit]

    tabs = gmail_tabs(conn, since_hours) if gmail else {}
    parts = "(UID FLAGS" + (" X-GM-LABELS" if gmail else "") + f" BODY.PEEK[]<0.{PREVIEW_BYTES}>)"
    items = []
    for batch in chunks(newest, BATCH):
        for meta, raw in fetch(conn, batch, parts):
            uid = field(meta, rb"UID (\d+)")
            if uid in arrivals:
                items.append(describe(uid, meta, raw, arrivals[uid], tabs, gmail, address))
    items.sort(key=lambda item: item["received"], reverse=True)
    return {"account": address, "server": host, "mailbox": mailbox, "since": cutoff.isoformat(timespec="seconds"),
            "arrived": len(arrivals), "returned": len(items), "truncated": len(arrivals) > len(items),
            "items": items}


def describe(uid, meta, raw, when, tabs, gmail, address=""):
    msg = email.message_from_bytes(raw or b"", policy=email.policy.default)
    flags = set(tokens(field(meta, rb"FLAGS \(([^)]*)\)") or b""))
    labels = set(tokens(field(meta, rb"X-GM-LABELS \(([^)]*)\)") or b""))
    name, addr = email.utils.parseaddr(header(msg, "From"))
    message_id = header(msg, "Message-ID").strip("<> ")
    bulk = bool(header(msg, "List-Unsubscribe") or header(msg, "List-Id")) \
        or header(msg, "Precedence").lower() in ("bulk", "list", "junk")
    return {
        "key": message_id or f"uid:{uid.decode()}",
        "title": header(msg, "Subject") or "(no subject)",
        "from": f"{name} <{addr}>" if name and addr else (addr or name),
        "received": when.isoformat(),
        "unread": "\\Seen" not in flags,
        "starred": "\\Flagged" in flags,
        "tab": tabs.get(uid, ""),
        "important": "\\Important" in labels,
        "bulk": bulk,
        "preview": preview(msg),
        "url": gmail_link(address, message_id) if gmail and message_id else "",
    }


def gmail_link(address, message_id):
    """Opens the message in the signed-in account it came from; Message-IDs often contain + = / that must be encoded."""
    account = urlquote(address, safe="@") if address else "0"
    return f"https://mail.google.com/mail/u/{account}/#search/{urlquote('rfc822msgid:' + message_id, safe='')}"


def gmail_tabs(conn, since_hours):
    days = math.ceil(since_hours / 24) + 1
    tabs = {}
    for tab in GMAIL_TABS:
        status, data = conn.uid("SEARCH", "X-GM-RAW", f'"category:{tab} newer_than:{days}d"')
        if status == "OK" and data and data[0]:
            for uid in data[0].split():
                tabs.setdefault(uid, tab)
    return tabs


def fetch(conn, uids, parts):
    """(metadata, literal) per message, in the shapes imaplib returns.

    Without a literal every message is one bytes item (b'1 (UID 7 INTERNALDATE "...")'). With one, a message is a
    (head, literal) tuple followed by the rest of its items (b' FLAGS (\\Seen))') or just b')'. Only that rest joins the
    message before it; anything starting "<n> (" is the next message.
    """
    if not uids:
        return []
    status, data = conn.uid("FETCH", b",".join(uids).decode(), parts)
    if status != "OK":
        raise ServerRefused(f"fetch: {detail(data)}")
    out, after_literal = [], False
    for item in data or []:
        if isinstance(item, tuple):
            out.append([item[0], item[1]])
            after_literal = True
            continue
        if not isinstance(item, bytes):
            continue
        text = item.strip()
        starts_message = re.match(rb"^\d+ \(", text) is not None
        if after_literal and not starts_message:
            if text != b")":
                out[-1][0] += b" " + text
            after_literal = False
        elif starts_message:
            out.append([text, b""])
            after_literal = False
    return [(meta, raw) for meta, raw in out]


def detail(data):
    text = b" ".join(part for part in (data or []) if isinstance(part, bytes)).decode(errors="replace").strip()
    return text[:200] or "no reason given"


def field(meta, pattern):
    m = re.search(pattern, meta or b"")
    return m.group(1) if m else None


def arrival(meta):
    text = field(meta, rb'INTERNALDATE "([^"]+)"')
    try:
        return datetime.strptime(text.decode(), "%d-%b-%Y %H:%M:%S %z") if text else None
    except ValueError:
        return None


def tokens(raw):
    """Atoms and quoted strings of a parenthesized list. Gmail sends labels quoted, with backslashes escaped."""
    out = []
    for quoted, bare in re.findall(rb'"((?:[^"\\]|\\.)*)"|(\S+)', raw):
        value = re.sub(rb"\\(.)", rb"\1", quoted) if quoted else bare
        out.append(value.decode(errors="replace"))
    return out


def header(msg, name):
    try:
        value = msg.get(name)
        return " ".join(str(value).split()) if value is not None else ""
    except Exception:  # noqa: BLE001 - a malformed header shouldn't lose the message
        return ""


def preview(msg):
    try:
        part = msg.get_body(preferencelist=("plain", "html"))
        text = part.get_content() if part is not None else ""
        if part is not None and part.get_content_type() == "text/html":
            text = html.unescape(re.sub(r"(?s)<(script|style).*?</\1>|<[^>]+>", " ", text))
    except Exception:  # noqa: BLE001 - the fetch stops mid-message, so the last part may not decode
        text = ""
    text = " ".join(text.split())
    return text[:300] + ("…" if len(text) > 300 else "")


def quote(mailbox):
    return mailbox if mailbox.upper() == "INBOX" or not re.search(r'[\s"]', mailbox) else '"' + mailbox.replace('"', '\\"') + '"'


def chunks(values, size):
    return [values[i:i + size] for i in range(0, len(values), size)]
