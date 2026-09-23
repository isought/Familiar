# Common tasks in Waxwing (real labels)

1. **Write a page**: sidebar **New page** → type a **Page title** → write in **Write** (or **Markdown**), check **Preview** → optionally **Linked pages → Choose a page… → Add link** → **Save page** (⌘S works).
2. **Edit a page / make a new version**: open the page → **Edit page** → change → **Save page**. The old text stays under **Saved versions**.
3. **Read an old version**: on a page, open the **Saved versions** dropdown → pick "Version N · …" → it opens read-only → **Read current version** to return.
4. **Link pages**: structured: **Linked pages** in the editor ("Follow current page" or pin a version). Typed: paste `/?page=ID` as an ordinary Markdown link; after saving it shows under **Cites**, and on the target under **Cited by**.
5. **Make a subpage or reorganize**: on a page **New subpage**; or change the **Collection** / **Parent page** selects; reorder with ▲ ▼ in **Contents**.
6. **Make a drawing**: **＋ New drawing** → **Drawing title** → draw → **Save drawing** → later **Edit drawing**.
7. **Capture a relational data model**: run `npm run schema:export …` in the repo → sidebar **Import explanation** → choose the `.model.json` → the ERD opens; select a table or column → add a note. Optionally **Connected repositories → Connect a source → Relational data model** with a snapshot path → **Refresh schema** later.
8. **Compare two revisions**: open the explanation → **What changed?** → choose **Compare against** → read added / changed / removed, **Open before** / **Open after**, and "Pages to revisit".
9. **Search**: type in **Search your workspace**, set the scope (Whole workspace / Inbox / a collection), optionally **Include older revisions**, press **Search**. Results open the exact saved version. **Close search** returns.
10. **Navigate a collection**: sidebar tree or a collection card → lands on **Home** if set → **Contents** for the full numbered catalog.
11. **Keep pages true**: sidebar **Needs attention** → open a page → revise with **Edit page**, or press **Confirm current** if it is still accurate.
12. **Give an agent access**: user-name button → **Account and access** → **Create agent token** → choose Read or Read and write → copy the secret once.
