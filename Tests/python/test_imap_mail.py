"""Runs tools/imap-mail/scripts/today.py against a fake IMAP server that answers in imaplib's real shapes.

No network: imaplib.IMAP4_SSL is replaced. Run with `python3 Tests/python/test_imap_mail.py`; exits non-zero on failure.
"""
import importlib.util
import os
import pathlib
import sys
from datetime import datetime, timedelta, timezone

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("today", ROOT / "tools/imap-mail/scripts/today.py")
today = importlib.util.module_from_spec(spec)
spec.loader.exec_module(today)


def stamp(hours_ago):
    return (datetime.now(timezone.utc) - timedelta(hours=hours_ago)).strftime("%d-%b-%Y %H:%M:%S +0000")


def message(subject, sender="Avery <avery@example.test>", msg_id="CAMx2+uF8=q3/x@mail.gmail.com"):
    return (f"From: {sender}\r\nSubject: {subject}\r\nMessage-ID: <{msg_id}>\r\n"
            "Content-Type: text/plain; charset=utf-8\r\n\r\nCan you confirm the delivery date?").encode()


class FakeIMAP:
    """Answers like imaplib: bytes items without literals, (head, literal) tuples plus trailing items with them."""
    capabilities = ("IMAP4REV1", "X-GM-EXT-1")

    def __init__(self, refuse=None):
        self.refuse = refuse or set()
        self.flag_changes = []

    def login(self, user, password):
        return "OK", [b"Logged in"]

    def select(self, mailbox, readonly=False):
        assert readonly, "the inbox must be opened read-only"
        return "OK", [b"3"]

    def logout(self):
        return "BYE", [b""]

    def uid(self, command, *args):
        if command == "STORE":
            self.flag_changes.append(args)
        if command == "SEARCH":
            if "search" in self.refuse:
                return "NO", [b"[UNAVAILABLE] Temporary System Error"]
            if args[0] == "X-GM-RAW":
                return "OK", [b"102" if "promotions" in args[1] else b""]
            return "OK", [b"101 102 103 104"]
        assert command == "FETCH", command
        parts = args[1]
        assert "BODY[" not in parts or "BODY.PEEK[" in parts, "bodies must be fetched with PEEK"
        if "BODY.PEEK" not in parts:   # (UID INTERNALDATE): one bytes item per message, no literal
            return "OK", [f'{i} (UID {uid} INTERNALDATE "{stamp(h)}")'.encode()
                          for i, (uid, h) in enumerate([(101, 1), (102, 2), (103, 3), (104, 90)], 1)]
        if "fetch" in self.refuse:
            return "NO", [b"[THROTTLED] Too many requests"]
        body1, body2, body3 = message("Delivery date?"), message("50% off", "Shop <deals@example.test>", "sale@example.test"), message("Lunch")
        return "OK", [
            (b'1 (UID 101 X-GM-LABELS ("\\\\Important" "\\\\Inbox") FLAGS (\\Seen) BODY[]<0> {%d}' % len(body1), body1), b")",
            (b'2 (UID 102 BODY[]<0> {%d}' % len(body2), body2), b' FLAGS () X-GM-LABELS ("\\\\Inbox"))',   # items after the literal
            (b'3 (UID 103 FLAGS (\\Flagged) BODY[]<0> {%d}' % len(body3), body3), b")",
        ]


def run_with(fake):
    today.imaplib.IMAP4_SSL = lambda *args, **kwargs: fake
    os.environ["MAIL_ADDRESS"], os.environ["MAIL_APP_PASSWORD"] = "me@gmail.com", "abcd efgh ijkl mnop"
    return today.run(since_hours=24)


failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


fake = FakeIMAP()
result = run_with(fake)
check("error" not in result, f"unexpected error: {result.get('error')}")
check(result.get("arrived") == 3, f"arrived should count the 3 recent messages, got {result.get('arrived')}")
items = {item["title"]: item for item in result.get("items", [])}
check(set(items) == {"Delivery date?", "50% off", "Lunch"}, f"titles: {sorted(items)}")
check(items.get("Delivery date?", {}).get("important") is True, "Gmail's quoted \\Important label")
check(items.get("Delivery date?", {}).get("unread") is False, "\\Seen means read")
check(items.get("50% off", {}).get("unread") is True, "flags sent after the literal still belong to their message")
check(items.get("50% off", {}).get("tab") == "promotions", "Gmail tab from X-GM-RAW")
check(items.get("Lunch", {}).get("starred") is True, "\\Flagged means starred")
url = items.get("Delivery date?", {}).get("url", "")
check(url == "https://mail.google.com/mail/u/me@gmail.com/#search/rfc822msgid%3ACAMx2%2BuF8%3Dq3%2Fx%40mail.gmail.com",
      f"deep link encodes + = / @ and opens the right account: {url}")
check(not fake.flag_changes, "nothing may change flags")

for refused in ("search", "fetch"):
    result = run_with(FakeIMAP(refuse={refused}))
    check("couldn't read INBOX right now" in result.get("error", ""), f"a NO on {refused} must be an error, not an empty inbox: {result}")

os.environ.pop("MAIL_APP_PASSWORD")
check("isn't connected yet" in today.run().get("error", ""), "missing app password")

if failures:
    print("\n".join("FAIL: " + f for f in failures))
    sys.exit(1)
print("imap-mail script: all checks passed")
