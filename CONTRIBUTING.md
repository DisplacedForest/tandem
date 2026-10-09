# Contributing to Vera

How to set up, test, and land a change.

## How this repo is maintained

Vera was developed privately and published with a fresh history.

- **PRs are welcome and they land.** A merged PR is credited in the next release's notes and ships in that release.
- **Issues on this repo are the project's tracker** for bug reports and feature requests.

## Branching and releases

Trunk-based, deliberately simple:

- **`main` is the only long-lived branch and is always releasable.** There is no dev branch.
- **Changes arrive as PRs**: fork, short-lived branch, PR, squash merge. CI must be green to merge; `main` is protected (no force-pushes, no deletions, required checks).
- **Releases and tags are cut by the maintainer.** Don't bump `VERSION` or push tags in a PR.

## Ground rules for code

Enforced in review:

1. **Everything is parameterized.** No hardcoded endpoints, IPs, hostnames, home-directory paths, model names, or personal data. Every external service is a URL in config. Every judgment call (taste, thresholds, region) is a config value with a neutral default.
2. **Degrade gracefully.** Every capability must behave sensibly when its endpoint or integration is unconfigured: report itself as off in the config report, refuse politely at runtime, and never affect the rest of the stack.
3. **One capability = one router.** New server-side capabilities are a single `APIRouter` module in `services/vera-api/routers/` plus one entry in the `CAPABILITIES` table in `main.py`. No new containers, no sidecars.
4. **Typed throughout.** Python is type-hinted, Swift is Swift 6 strict.

## Project layout

```
apps/vera-mac/          native macOS app (SwiftPM, Swift 6, SwiftUI)
services/vera-api/      the shared FastAPI container; every capability is a router
services/vera-voice/    STT/TTS reference service (MLX; HTTP + Wyoming protocol)
services/vera-image/    image-gen reference service (MLX; OpenAI Images API + native)
services/vera-vision/   vision serving notes + launchd template
services/vera-coder/    coding-agent harness for the coder endpoint
scripts/                ops scripts; each documents its own env in its header
docs/                   SETUP.md + screenshots
```

## Running tests

**vera-api** (Python 3.12):

```sh
cd services/vera-api
pip install -r requirements.txt pytest
pytest
```

The API suite is hermetic (every store runs against a temp dir; no live endpoints), and
`pytest.ini` sets the import path. `pytest` works from `services/vera-api` or as
`pytest services/vera-api/tests` from the repo root, no `PYTHONPATH` required.

`mise run domain-state-test` checks typed memory projections, source-backed review, SQLite migration/restoration, privacy and shared native/Pi retrieval using synthetic local data.

Task-engine tests include deterministic fake workers, process-kill recovery, cancellation, replay, and duplicate-request checks. They do not call models or external tools. Native admission tests additionally launch the built app against a synthetic loopback engine and provider, exercising real streaming, cancellation, memory generation, and restart recovery without saved credentials. `mise run native-task-test` exercises synthetic native background handoff, crash recovery, persistent transcript cards, reconnects, explicit retries, and eight-task control responsiveness. Task-card screenshots use a pure offscreen host before any saved configuration is loaded: `.build/debug/Vera --shot /tmp/task-card.png --view task-card`. Variants include `task-card-complete`, `task-card-stopped`, `task-card-retry`, `task-card-offline`, `task-card-report`, and `task-card-report-unsafe`; append `-narrow` for the smaller layout. Synthetic screenshot sources are nonlinked, and embedded report images do not fetch. `mise run native-admission-test` builds and runs those tests.

`mise run native-document-test` passes a completed document task from a disposable API engine into the native artifact decoder and renderer. Document-worker tests use scripted model responses, bounded steps, restart/retry and cancellation checks. They do not contact a provider or grant credential access. Full Markdown stays in the artifact and is excluded from speech. `mise run pi-app-broker-test` also verifies native document submission, original-turn placement, task-scoped file validation, cancellation, and process-kill recovery through the shared app-owned runtime. All model responses are synthetic.

`mise run signing-test` validates local signing configuration, exact certificate selection, and failure behavior with mocked signing commands. It does not access Keychain identities or change trust settings.

`mise run task-engine-contract` runs the task HTTP contract against a disposable source engine. It uses synthetic tasks, a fresh data directory and loopback connections, then kills and restarts its own process to verify durable state and event replay. It makes no provider calls. The API test suite includes this contract. After building the engine with PyInstaller, run `mise run task-engine-package-test` to exercise the same contract against `services/vera-api/dist/vera-api/vera-api`. To test another build, pass its executable to `python scripts/tests/task_engine_contract.py --engine <path>`. Every run creates its own data; it does not attach to an existing engine.

The native app broker tests also exercise the persistent conversation against a disposable runtime over authenticated loopback SSE. They check event-driven updates without polling, task placement in the original turn, cursor replay, owner shutdown and restart, and task control boundaries. UI library selftests cover stale event callbacks, refresh failures and cursor persistence. For an offscreen transcript fixture, run the built app with `--pi-native-selftest --task-card-shot /tmp/task-transcript.png`; this renders synthetic task cards without launching the ordinary app or accessing saved configuration.

**Mac app** (no XCTest by design; the app validates through its own harness):

```sh
cd apps/vera-mac
swift build
.build/debug/Vera --selftest
```

Packaging also requires Python 3.14 or later to assemble the pinned portable runtime. See [Mac packaging](apps/vera-mac/README.md#package--install) for cache controls and the offline packaged-runtime contract.

The app builds **only on macOS**. It is SwiftUI/AppKit; on Linux (containers, cloud
agents, CI shells) `swift build` fails at the toolchain or first Apple-framework import,
which is environmental, not a code defect.

For UI work, render any view headlessly and inspect it:

```sh
.build/debug/Vera --shot /tmp/view.png --view chat
.build/debug/Vera --shot /tmp/view-light.png --view pulse --appearance light
```

Run all of the above before opening a PR. CI must be green to merge.

## Sending a change

1. Fork, branch, build, and make sure the tests above pass locally.
2. Keep the diff focused: one concern per PR.
3. If you add config, add it to `.env.example` with a comment and make sure it shows up in the startup config report (a test fails if an env var is read but undocumented).
4. If you add a capability, it must degrade gracefully when unconfigured. That is the first thing reviewed.
5. Open the PR with a plain description of what changed and why. No fixed template.

## Filing issues

**Bugs**: include the output of `GET /version`, the startup config report from the container log (`docker compose logs vera-api | head -60`, secrets are masked), and what you expected vs. what you saw.

**Feature requests**: describe the problem before the solution. Vera stays one shared container with parameterized capabilities; proposals that fit that shape are straightforward to land.

## License

By contributing, you agree your contributions are licensed under the [MIT License](LICENSE).

Session checks use injected model transports and isolated local databases. Run `VERA_SESSION_SELFTEST=1 .build/debug/Vera --selftest` from `apps/vera-mac` for queue, context, confirmation, and retry regressions. `mise run native-task-test` also exercises real native HTTP responsiveness and process-kill recovery against loopback fixtures. It makes no paid provider calls. Native task tests also use actual loopback HTTP to verify upload callbacks, delayed headers, read inactivity, total deadlines, cancellation, and sanitized transport diagnostics. Pure offscreen mode previews use `--shot /tmp/session.png --view session-continuous` or `session-chat`; append `-narrow` and use `--appearance light` to inspect the smaller light layout. These previews never construct saved settings or open a visible window.

Credential lifecycle checks inject both Keychain operations and configuration I/O. Run `VERA_CREDENTIAL_SELFTEST=1 .build/debug/Vera --selftest` from `apps/vera-mac` for the focused mock suite. It covers unchanged saves, denied reads, explicit edits/removal, retry after failure, and guarded legacy migration without accessing real credentials or configuration.

Native MCP changes must pass `mise run native-mcp-test` and `mise run check`. Tests use synthetic loopback servers. Live service setup, credential grants and built-in adapter removal require their own qualification and parity evidence.

The production assistant factory is covered through injected HTTP in the provider wiring selftest: selected-credential access refusal and explicit recovery without restart, usage outages before dispatch, price changes, lifetime allowance, more than twelve replies, document completion and reopening without new inference. This is local regression coverage. Delivery acceptance also requires an ordinary installed launch and real connected reply/document, with existing credentials and an explicitly authorized spending limit.
