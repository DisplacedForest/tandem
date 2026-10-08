# App replacement and recovery

The updater and `deploy.sh` use `SafeAppReplacement.swift`. They copy a candidate with `ditto` into a private directory beside the destination, validate its bundle identifier, version, executable and complete code signature, then atomically exchange the two app directories. The candidate must satisfy the installed app's designated signing requirement. The first install requires an explicit CLI flag and a trusted local source bundle; it verifies the candidate's signature but has no prior identity to compare.

Staging preserves the source or extracted bundle's extended attributes, including quarantine. The old app retains its attributes in the rollback directory. The installer does not change signing identities, Keychain access, trust settings or Gatekeeper policy. Different ad-hoc builds normally have different designated requirements and cannot replace each other through this path. Establishing a distribution signing identity is separate work.

A successful replacement prints a `receipt.json` path beneath a private `.Vera-replacement-*` directory beside the installed app. That directory retains the previous `Vera.app`. Receipts bind directory identities and SHA-256 manifests of file contents, names, types, link destinations and permissions. They distinguish a prepared copy from an installed replacement even if the installer is killed immediately after the exchange. In-place content changes invalidate a receipt. Inspection does not launch either app or modify installation state.

Packaged apps include a standalone repair command. Inspection needs no compiler or checkout:

```sh
/Applications/Vera.app/Contents/Helpers/VeraAppReplacement --inspect /path/to/receipt.json
```

For development builds, compile the same command from the repository root:

```sh
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macosx26.0" \
  apps/vera-mac/Sources/Vera/SafeAppReplacement.swift \
  apps/vera-mac/scripts/app-replacement/main.swift \
  -o /tmp/vera-app-replacement
/tmp/vera-app-replacement --inspect /path/to/receipt.json
```

To restore a retained app, quit Vera and run:

```sh
/Applications/Vera.app/Contents/Helpers/VeraAppReplacement --rollback /path/to/receipt.json
```

Rollback requires the current installation and retained app to match that receipt and pass signature validation. It uses another atomic exchange and retains the displaced replacement under a new receipt. A receipt marked `changed` cannot be used to roll back. No automatic cleanup deletes retained apps. Remove an obsolete rollback directory only after verifying the new installation works and keeping any required backup.

This mechanism preserves a usable namespace during copy failures and process interruption on filesystems that support atomic rename exchange. Unsupported filesystems fail without a delete-and-copy fallback. The tests exercise process termination, not power loss. Receipt writes are atomic but are not a power-loss durability guarantee. Relaunch is requested after the exchange; this is not a health check or an automatic post-launch health rollback.

Downloaded updates must pass a strict ZIP preflight before `ditto` extraction. It rejects paths outside the bundle and resource-fork roots, links, special files, conflicting headers or paths, unlisted local records, alternate filename metadata, encrypted archives, ZIP64 and unsupported metadata. Ordinary `ditto` release archives and stored or deflated entries are covered by the tests. Archive size is limited to 512 MiB, with a declared expanded size limit of 2 GiB. Bundles containing symlinks need a separately reviewed archive format before they can use the downloaded-update path.

The archive creator determines which source metadata enters a downloaded artifact. A fixture showed that `ditto` ZIP creation omitted a custom attribute on the root app directory. The replacement copy tests prove preservation of existing bundle attributes; they do not establish a complete metadata roundtrip through release ZIP creation.

Run the focused offline checks from the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s apps/vera-mac/tests/app-replacement -p 'test_*.py' -v
```

Filesystem failure and SIGKILL cases use an injected signature validator and temporary executable fixtures. Unsigned-bundle rejection uses the real Security framework. For real signature, identity-mismatch, tamper and rollback checks, set `VERA_REPLACEMENT_SIGNED_FIXTURE` to an existing, strictly signed app. The test copies its public bundle files into temporary directories and never launches, signs or changes the original. Without that explicit fixture the integration case is reported as skipped. A restricted sandbox may prevent host trust evaluation; that failure is not a reason to weaken signature checks.
