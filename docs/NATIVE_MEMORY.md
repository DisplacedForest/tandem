# Native memory

Vera's personal memory is an optional feature in the Mac app. It starts off for existing and new installations. When it is off, Vera performs no memory retrieval, embedding, proposal generation, maintenance, or memory request assembly.

Approved memory is stored only on this Mac, in the same SQLite database as native conversation history. The app does not synchronize it to vera-api, an account, or another device. Generating proposals and embeddings is different: it sends the current turn and your existing memories to the configured model endpoint. Settings, Memory names that endpoint's host and says whether it's on this Mac or remote. Model-generated changes are proposals. They do not create, update, merge, suppress, expire, prune, or delete approved memory until the user reviews and accepts them.

## Library

The Memory area organizes readable records into four sections:

* **You** contains profile details and response preferences.
* **Topics** contains recurring interests.
* **Areas** contains projects, goals, plans, and sustained domains.
* **People** contains durable relationship context.

Each row shows a name, concise summary, and last-updated date. The detail view shows readable durable details and provides edit, delete, and source controls. Embeddings, similarity scores, and retrieval metadata are not shown in the primary library.

Each record also has an internal category and bank. Banks scope recall without replacing the four user-facing sections. A record is either durable or episodic. Episodic records require an absolute expiry date and stop appearing in recall immediately after that date. An automatic groom then removes an approved episodic record once its expiry date is strictly before the current date in the user's calendar: a record expiring today survives until tomorrow, and durable records and records without an expiry are never touched.

## Chat behavior

With embeddings unset, native chat searches approved memory locally using SQLite FTS5. It selects at most eight records within a 2,800-byte evidence budget, ranked by lexical relevance with stable ties. No embedding or extraction call is needed for this recall. Selected bank scope, approval, expiry, and source availability are checked again after model admission, before each native HTTP request. A changed memory context stops the turn visibly instead of sending a stale snapshot. Lexical retrieval can miss paraphrases that share no terms.

An explicitly configured embeddings model retains semantic recall at the active OpenAI-compatible endpoint. Its limits are:

* 8 selected records per turn
* about 700 memory-context tokens per turn
* cosine similarity of at least 0.2
* semantic duplicate comparison at 0.9 similarity
* reviewable consolidation suggestions at 0.94 similarity within a bank
* deterministic ties by newest update and then stable record identifier
* selected bank scope, with `all` as the inclusive scope
* 1,000 approved records before a capacity-review proposal appears

The saved system prompt stays first. A clearly delimited block of approved, unexpired, unsuppressed memory follows it, then completed local conversation history. The block says that memory is untrusted background context, not instructions. Pending, deleted, dismissed, suppressed, expired, irrelevant, malformed, and failed-retrieval records are excluded.

If a configured embeddings service fails, or local retrieval fails, Vera sends the ordinary chat request without memory and shows an understandable local status. Leaving extraction unconfigured disables suggestions, but approved records remain available to local recall. Native streaming, endpoint selection, conversation history, the saved system prompt, the tool loop, Apple Reminders, and tool preferences continue to work.

After an eligible completed turn, the optional extraction model receives only bounded user and assistant turn text plus a bounded summary of existing approved memory. It returns structured create, update, merge, suppress, expire, or delete proposals, and it can also suggest evidence-backed records (counts and changes to them, care, facts, corrections, and retractions) taken from the user's own words. Empty, private, excluded, failed, interrupted, or tool-only turns do not create proposals. A conversation can be excluded from memory suggestions from its sidebar menu.

Search past chats, Generate proposals from completed chats, and Sensitive information are separate settings. Turning off a switch, or memory as a whole, stops work already underway. A past-chat scan stops at the next turn, and a reply that just finished isn't reviewed. The scan button in Memory never turns Search past chats on by itself.

The past-chat search control reads at most 48 recent messages from each of 12 local conversations, stops after 12 eligible completed turns or 48,000 text bytes, and creates reviewable proposals with direct source-conversation links. Text that matches credential, token, password, private-key, or action-token patterns is never sent to memory services and never stored, whatever the settings say.

The Sensitive information setting covers the wider set: settings text, code, hidden reasoning, and similar content. Never remember (the default) skips those turns completely. Suggest for review only lets them produce suggestions marked "Contains sensitive text:" in the review queue. Nothing is saved until you accept it. Accepting one keeps its source so it can be recalled. Switching back to Never remember stops recall of those records without deleting them.

## Behavior and boundaries

Native memory covers these capabilities:

| Capability | Native behavior |
|---|---|
| User-specific facts | Concise records with readable details and safe source references |
| Categories and banks | Typed categories and internal bank scope |
| Semantic recall | OpenAI-compatible embeddings with deterministic local ranking |
| Text and semantic duplicate handling | Exact proposals are skipped, similar content becomes an update proposal, and extracted creates reconcile to updates |
| Correction and deletion | User edits are immediate, model suggestions wait for review, and deletion immediately prevents later recall |
| Durable and episodic facts | Episodic records require an absolute expiry date and are excluded after it |
| Consolidation and bounded storage | Merge, consolidation, and capacity actions are reviewable proposals; past-expiry episodic records are groomed automatically |
| Clear status | Off, setup required, indexing, ready, pending review, unavailable, maintenance needed, and failed states |

The design deliberately holds these boundaries:

* Approved memory has no server runtime dependencies and is stored only on this Mac. Optional extraction and embeddings use the configured model endpoint.
* The only automatic removal is the expiry groom, and every removal writes an inspectable audit entry.
* Credentials, authorization headers, and action tokens are never stored as memory. Provider settings, function code, and hidden reasoning never appear in a memory's text. Under Suggest for review only, an accepted memory may keep a source message that contains them.
* Maintenance runs only while the app is active and memory is enabled.
* Optional service failure never blocks ordinary native chat.
* The novice surface does not expose ranking thresholds, embeddings, scores, clusters, or pruning controls.

## Review and maintenance

The review queue supports accept and dismiss for all proposal types. Accepted creates become approved records and are immediately available to lexical recall. Embeddings are prepared only when a model is explicitly configured. Accepted updates and merges replace only the records named in the visible proposal. User edits invalidate the old embedding and reindex the approved text. Delete and suppress decisions remove the record from recall immediately.

Maintenance never performs network work when memory is off or the optional memory service is unavailable. Records expiring today and capacity pressure create proposals; they do not delete or prune records on their own.

The expiry groom is separate from proposal-driven maintenance. It runs at app launch and every 24 hours while the app stays running, only while memory is enabled, entirely against the local store. Each pass deletes approved episodic records whose expiry date is strictly before the current date, writes an audit entry for every removal through the memory change trail, and dismisses pending proposals whose target record no longer exists, so the review queue never dangles even when an earlier pass was interrupted. A pass with nothing to do is silent. A pass that removes or dismisses anything shows an outcome line on the Memory status card that clears itself after a short while; a failure stays visible until the next pass. Passes are idempotent, and a dry run reports the exact candidates without deleting anything.

At 1,000 approved records, the local repository rejects another approved create until the user accepts an actionable cleanup or consolidation proposal. The proposal names and links the exact records it would replace or remove.

## Evidence and corrections

Each approved save preserves a version of the readable memory and, when available, its source message text and content hash. Model-suggested corrections use the source message attached to the accepted proposal. Existing history is not rewritten. Older versions are available for inspection, but only current approved facts enter recall. Plans remain qualified as plans; storing text does not prove an action happened.

Answers carry numbered memory sources. Opening one uses the existing editable Memory detail sheet, identifies the version used in that answer, and shows later corrections separately. Removing a memory clears its saved revision payloads and lexical entry and retains a tombstone so delayed writes cannot recreate that identity. Conversation history is retained unless separately deleted. Deleting or excluding a source conversation, or editing/deleting its source message, removes archived source text and prevents source-dependent recall. Already delivered answers and their text remain conversation history; removal cannot retract data already sent to a configured model. This is logical deletion, not a forensic disk-erasure guarantee.

Recall spans eligible approved records in the selected bank on this Mac. It does not search every historical message or attachment automatically. The existing past-chat control continues to produce reviewable proposals. Source snapshots are added only for saved approved records; documents, attachment versions, and live inventory synchronization remain separate integration work. The existing Python TaskStore remains authoritative for task lifecycle and permissions.

The native regression command `Vera --memory-evidence-selftest` uses synthetic fixtures and injected transports to check migration, cross-chat correction, planned care, reopen, citations, source exclusion and removal, and delayed work. It makes no model calls and does not measure local-model answer quality.

## Shared runtime context

The native persistent-workspace connection receives the same `ChatStore` used by focused chats. It uses that store's approved-memory retrieval, selected bank, enabled setting, optional embeddings service, source eligibility and revision checks. Provider and conversation type do not create another memory identity. Pi is an internal execution adapter, not another assistant.

The host binds each foreground query to its assistant, conversation and message. Worker context is bound to the existing Python TaskStore task after the exact current decision is approved. An explicit retry decision starts a new context generation under the same task identity; duplicate approval delivery keeps its original context. Cancellation revokes that task's context. During an approval handoff, model preparation waits up to three seconds for the host to confirm the decision and install its generation; it cannot use the prior attempt's context during that gap. The adapter cannot choose another bank or load the memory database itself.

Bounded context uses the native policy and memory assembler. Its fingerprint participates in broker and provider replay accounting. Closure, cancellation, expiry and memory eligibility are rechecked after asynchronous preparation, after admission, before provider dispatch and before a new result is accepted. Changed context requires a fresh explicit request or approved worker retry. Existing completed replies can be replayed without another provider call and keep their original source references.

Only memory identifiers and revision references are saved for runtime citations, in the existing native SQLite store. They are recorded before dispatch so a restart between answer persistence and UI delivery can recover the original references. The native answer view opens the same Memory detail sheet used by focused chats. Removing memory does not reconstruct its deleted text from these references.

`Vera --shared-runtime-memory-selftest` checks shared identity across focused, persistent and worker requests, bounded provider-independent context, scope rejection, memory off, revocation, accounting replay, retry generations and citation recovery. The provider wiring fixture additionally runs the actual SDK, HTTP bridge and TaskStore with synthetic provider responses. Optional semantic recall still uses the configured native embeddings service; those existing service calls are separate from the Pi completion ledger. Tests inject services and make no paid calls.

This source integration does not activate an installed runtime. The adapter's limited tool catalog, file handling and conversation journal still need application-wide integration and capability parity. Its fixed provider fixture and synthetic model-switch checks do not establish that every provider supports every capability, or measure model answer quality.

## Evidence-backed records

In Memory, **Record from evidence** creates a proposal from a saved user message. Choose a subject, its memory library, the record type, and when the fact was true or the event happened. Counts, additions, removals, facts, and care plans or completions are separate record types. A correction can replace earlier evidence for the same subject and property. The review shows the proposed value, effective date, attribution, original message, and any evidence it replaces. Nothing changes the approved state until Accept record succeeds.

These records use the same local database and approved-memory retrieval as ordinary memory. Stock counts are calculated from a confirmed baseline and applicable changes. Purchases and mentions alone do not establish current ownership. Conflicting counts, ambiguous ordering, missing evidence, and contradictory care statements remain uncertain. Planned, recommended, and possible care do not become completed actions. Event time and the time evidence was learned remain distinct, so later corrections can revise historical understanding without rewriting when they were learned.

The calculated memory opens in the existing detail view with its contributing source spans. To change it, propose another evidence-backed record; its calculated text cannot be edited independently. Editing, deleting, or excluding a source removes affected saved source payloads and invalidates derived memory. Deleted correction identities retain opaque replacement links so older claims do not reappear. Deleting the calculated memory also removes its journal payloads and prevents replay of the removed subject identity.

The optional extraction model also suggests these records from completed turns. Each suggestion quotes the exact words it relies on from the user's message. A quote that doesn't match the message word for word is dropped, never repaired, and the plain memory suggestion from the same turn still arrives. A suggestion joins an existing subject with the same name and library, or starts a new subject when you accept it. A correction replaces the newest current record of that subject for the same count, property, or care activity, and it's dropped if there's nothing approved to correct yet. Denied, hypothetical, secondhand, and unclear statements are kept in that form and never change a count. Suggestions go through the same review as Record from evidence, and nothing is approved automatically. At most eight are suggested per turn, and running extraction again on the same turn doesn't repeat them. When you accept one record, other pending records for the same subject are rechecked against the new state so they can still be accepted.

Typed suggestions follow the same settings as other suggestions: memory off, Generate proposals off, excluded conversations, private or "do not remember" messages, sensitive turns, and credentials produce none, and turning a setting off stops suggestions still being saved. Replies from the persistent-workspace runtime go through the same extraction and produce the same plain memory suggestions, without a source link. Their typed records aren't suggested, because those messages aren't saved on this Mac where the quoted words could be checked and removed later. Entity alias resolution and synchronization with live Home inventory are not implemented. These records do not execute care, purchase, or other actions. Existing task approvals remain separate.

`mise run domain-state-test` exercises synthetic quantities, corrections, event and learned time, conflicting care, reviewed SQLite commits, stale approvals, duplicate replay, source redaction, populated migration and restoration, and shared native/Pi context preparation. It makes no provider calls and does not validate model extraction or visible UI interaction.

`mise run domain-extraction-test` runs the extraction parser and staging against a stubbed model endpoint returning fixed output: the hens scenario across two chats through approval and reopen, evidence modes, quote mismatch, repeat runs, settings turned off mid-turn, runtime and native parity, malformed output, and gating. It does not measure how well a real model extracts records.
