# /// script
# dependencies = ["requests>=2.31"]
# ///
"""Fetch a web page (e.g. an internal wiki article) and return its visible text.

Uses the machine's network, so internal pages work when the user is on VPN.

Args:
    url: Page URL.
    max_chars: Truncate the text to this many characters.
"""
import re

import requests


def run(url: str, max_chars: int = 6000) -> dict:
    r = requests.get(url, timeout=15)
    text = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", r.text, flags=re.S | re.I)
    text = re.sub(r"<[^>]+>", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return {"status": r.status_code, "text": text[:max_chars], "truncated": len(text) > max_chars}
