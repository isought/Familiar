---
name: Waxwing App
description: The Waxwing workspace app (a Confluence replacement): collections, pages, drawings, imported explanations and data models, citations, work reports. Runs locally at 127.0.0.1:4310.
match:
  urls: [127.0.0.1:4310, localhost:4310]
  titles: [Waxwing]
requires: [WAXWING_API_TOKEN]
---
Waxwing is the place people and agents use to understand their systems and work. One workspace per install,
one browser route: every screen is `/?…` with query parameters, and every id is a UUID (no readable slugs).

How to help someone here:
- On a wand pick, call `waxwing__whats_here` first. It resolves the current URL to the real object (page,
  collection, model revision, record, work report) through the app's API, so you can name it exactly and say
  where it sits, which version is shown and whether anything cites it or has drifted.
- Then explain the clicked element using docs/screens.md (real button labels) and docs/concepts.md
  (the app's own words: page, version, revision, record, citation, linked page, collection home).
- Use `waxwing__search` when they are looking for something, `waxwing__library` for an overview of spaces,
  `waxwing__attention` for "what may no longer be true".
- If a script returns a 401 hint, tell them: create a read token in Waxwing under **Account and access**, then paste it in Familiar Settings (right-click the bubble → Settings…) as WAXWING_API_TOKEN. Then stop.
- Common surprises are listed in docs/confusions.md; check it before answering "why is this disabled/empty".
