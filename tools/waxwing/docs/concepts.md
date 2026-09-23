# Waxwing concepts, in the app's own words

- **Workspace**: the one shared knowledge space of this installation. Invitation-only. Its name is the badge in the header.
- **Library**: the index of everything (collections + entries). The left sidebar *is* the library.
- **Collection**: a named space with a title, an introduction, a curated, orderable table of contents, and optionally a **home**.
  - **Collection home**: an existing page or model chosen to open first when the collection opens. It follows that item's current version. When no home is set, the collection opens on its **Contents** and the Home tab is not shown.
  - **Inbox**: the pseudo-collection for entries that have no collection yet ("Unfiled pages", "Ready to organize").
- **Item**: the stable identity (UUID) of one piece of content. Survives edits, moves and re-imports. `/?item=ID` is a citation address that the app resolves to a page or a model revision.
- **Version**: an immutable saved snapshot of an item. Pages show "Version 3 · Current". A version whose body equals its predecessor shows as **Confirmed**.
- **Revision**: the word used for versions of *imported models* ("Latest import / Earlier import", with an 8-character content digest).
- **Page**: a hand-written Markdown page. Can have **subpages** (one parent at most, inside one collection).
- **Drawing**: a standalone hand-drawn canvas (Excalidraw). Separate from generated diagrams; shapes cannot link to items.
- **Explanation**: an *imported* Waxwing model rendered as an interactive diagram plus inspector. Two flavours: **architecture explanation** (components and relationships) and **relational data model** (an ERD: tables, columns, constraints, indexes, associations). Its content is immutable; people annotate it, they don't edit it.
- **Record**: a selectable thing inside an explanation (a component, relationship, table, column…). Identity = revision + record id.
- **Diagram**: the rendered view of an explanation, shown in a sandboxed frame. "Full screen diagram" is the large variant.
- **Contributor note**: a human note pinned to one exact (revision, record). It does not carry over to a newer revision, by design.
- **Citation**: an ordinary Markdown link whose address is a workspace address (`/?page=…`, `/?item=…&record=…`, `/?revision=…`, `/?collection=work-reports&report=…`). Extracted automatically on save. Shown as **Cites** on the page and **Cited by** on the target. A citation has a status: current, changed (target moved on), pinned (exact version), unresolved.
- **Linked pages**: a *separate*, hand-curated list of related pages set in the editor ("Follow current page" or pin a saved version). Not the same as citations.
- **Needs attention**: the queue of pages whose citations point at content that changed since they were written. **Confirm current** saves a byte-identical new version that records "checked today"; it is a human claim, not verification.
- **Work report**: an agent's append-only account of implementation work: scope, findings with their basis, checks, evidence snapshots. People **Question / Challenge / Acknowledge** individual findings in a **review**. A report can be superseded by a successor.
- **Evidence**: inside an explanation, the source claims the model carries; inside a work report, captured command output with fingerprints.
- **Telemetry embed**: a saved external dashboard URL (e.g. Grafana), grouped by app, optionally attached to an explanation or record.
- **Connected repository**: a saved Git remote + branch + question used to regenerate an explanation, or a schema snapshot path used to refresh a relational model. Owners only.
- **What changed? (delta)**: a comparison between two revisions of one explanation: added / changed / removed records, notes to review, pages to revisit.

How they relate: workspace → collections → items (pages, drawings, explanations) → versions or revisions → records → notes.
Placement (collection, parent, order) is live organization and is independent of content history.
