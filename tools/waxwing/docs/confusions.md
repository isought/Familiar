# Things that confuse first-time Waxwing users

- **The URL never changes path.** Everything is `/?…`; "copy link" produces query-string URLs with UUIDs. There are no readable slugs.
- **"Explanation" is overloaded.** The Workspace home stats count *all* entries as "explanations", but strictly an explanation is an imported model. Pages and drawings are not diagrams, and **Import explanation** expects a canonical Waxwing model JSON, not a document.
- **Revision vs version.** Imported models say "Latest import / Earlier import" with a digest; written pages say "Version 3 · Current". Same idea, different words.
- **Notes are pinned to a revision.** "You're reading an older revision. Notes remain attached to this revision." A note written on revision 1 does not appear on revision 2, by design.
- **Cites vs Linked pages** are two different systems on the same page: Cites is derived automatically from Markdown links; Linked pages is a manual list.
- **Confirm current looks like it does nothing.** It saves a new, byte-identical version that records "checked today". It is a human claim, not verification by the app.
- **Home vs Contents.** The **Home** tab disappears entirely when a collection has no home set, so the collection opens on its catalog. "Where did my collection page go?" usually means the home was cleared or the page moved.
- **Disabled controls**: **Search** until text is typed; **Save page** until a title exists; **Add link** until a page is chosen; ▲ ▼ at the ends of a list; placement selects while editing or saving; **Connected repositories** hidden for non-owners ("Repository management is available to workspace owners.").
- **Drafts live in the browser tab.** "Draft kept in this tab · Not saved to workspace", "Restore draft", "Discard draft". Closing the tab can lose them; nothing autosaves to the server.
- **Empty states**: "Your first explanation starts the library.", "This collection is ready for its first explanation.", "Everything has a home." (Inbox), "No pages yet" (tree), "No notes here yet.", "No matching content yet.", "Nothing needs attention.", "No work reports yet.".
- **Errors**: "Sign in to access this workspace." (session expired; the app says "Your session ended… drafts remain available"); 409 conflicts ("This note changed or was removed…", or a stale library prompting a refresh); "The cited item is not in this workspace."; "Another import is being prepared. Try again shortly."; "This preview is local-only." (wrong hostname); "Choose a canonical model JSON smaller than 1.9 MB.".
- **Search ranking notices**: "Local ranking is warming up; search again shortly." / "Keyword ranking" appear when the reranker is absent or cold.
- **Markdown-only fallback**: "This page uses Markdown that the visual editor cannot preserve exactly…" locks the editor into Markdown mode (raw HTML, images, reference links).
- **Session cookie**: browser sessions last 7 days, same-origin only. The app only answers on 127.0.0.1 / localhost.
