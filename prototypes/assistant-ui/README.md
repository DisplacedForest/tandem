# Vera assistant UI prototype

A separate SwiftUI executable for the isolated Pi runtime prototype. New Chat creates a focused conversation. Vera reopens one persistent assistant conversation. Activity shows conversation-scoped tasks, approval replies, and Stop. Outputs reveals existing task files within an explicitly configured workspace. Computers remains unavailable because this prototype has no computer execution backend.

The executable has no dependency on the installed Vera application, ConfigStore, Keychain, or its database. It requires a separate data directory, refuses the live Vera directory, and binds saved identity and drafts to one explicit loopback runtime address. The bridge owns transcripts and task state. No existing conversations are imported.

## Build and test

Requires macOS 14 or later and Swift 6.2.

```sh
swift build --package-path prototypes/assistant-ui
prototypes/assistant-ui/.build/debug/VeraPrototype --selftest
prototypes/assistant-ui/.build/debug/VeraPrototype --selftest --render-dir /tmp/vera-ui-layouts
```

The selftest injects an in-memory HTTP fixture and uses a temporary data directory. It covers identity persistence, separate drafts, conversation/task scope, lost-response retry across restart, approval idempotency, task-specific cancellation, and artifact path validation. The optional renderer uses hidden windows only. It produces synthetic light, dark, and narrow layout captures, not evidence of model performance or completed user work.

The executable provides keyboard shortcuts for New Chat (Command-N) and Send (Command-Return), named controls, task-specific accessible action labels, selectable message text, and a visible composer focus outline. VoiceOver and keyboard event verification require a separately authorized visible QA session; hidden windows do not publish an accessibility tree.

## Run against the isolated bridge

Start the separately maintained `prototypes/pi_assistant/bridge.py` with a disposable data root and unused loopback port. Then launch the UI using a different empty directory for its identity and drafts:

```sh
prototypes/assistant-ui/.build/debug/VeraPrototype \
  --data-root /tmp/vera-ui-state \
  --endpoint http://127.0.0.1:8769 \
  --workspace-root /tmp/vera-pi-runtime/workspaces
```

The runtime root in this example is `/tmp/vera-pi-runtime`. Match the actual bridge's workspace. The UI never starts an engine. With no endpoint it remains disconnected. A configured endpoint must implement protocol version 1 before the UI reads tasks or enables Send. Runtime transport `mock` appears as **Test runtime**. Mock tasks operate on synthetic examples and do not establish general coding capability. The mock bridge recognizes `/task ` at the start of an assistant message; focused conversations do not delegate work.

A headless HTTP consumer check requires an explicitly started mock bridge and a fresh UI data directory:

```sh
prototypes/assistant-ui/.build/debug/VeraPrototype --contract-test \
  --data-root /tmp/vera-ui-contract \
  --endpoint http://127.0.0.1:8769 \
  --workspace-root /tmp/vera-pi-runtime/workspaces
```

This check submits two synthetic tasks, approves one, stops the other, verifies its real output file, and reopens both assistant and focused transcripts. It refuses non-mock transport. For a read-only hidden-window capture of existing mock work, replace `--contract-test` with `--snapshot-dir /tmp/vera-ui-snapshot` and reuse its data directory.

## Runtime boundary

The client uses `GET /assistant/capabilities`, `GET /assistant/messages?conversation_id=...`, and `POST /assistant/messages` with stable assistant, conversation, and message UUIDs plus `text` and `mode`. An uncertain send preserves the exact request for explicit retry. Drafts remain editable while another conversation receives a response.

Activity reconciles paginated `GET /tasks` snapshots every two seconds while the view is mounted. It scopes records to this assistant and selected conversation and only displays `pi_worker` tasks. It does not maintain a second event cursor or change the native app's task projection. `POST /tasks/{id}/cancel` targets one task. Approval replies use `POST /tasks/{id}/decision` with the current decision ID, a saved idempotency key, and `reply.approved`.

Outputs come only from `result.artifacts`. Reveal checks for an existing regular file inside the explicitly configured workspace, resolving traversal and symlinks before opening Finder. Missing, remote, or outside-workspace paths stay unavailable. Files are never executed by the output button.

Persistent computer execution, a configured cloud transport, and installed-app integration remain separate work. This prototype does not provision environments, add calling, change credentials, replace the installed app, or migrate data.
