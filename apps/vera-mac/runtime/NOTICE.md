# Bundled Pi runtime

This runtime includes unmodified upstream binaries and library distributions. Its lock records exact upstream artifact URLs and checksums. The file manifest records the assembled contents. The Python and npm dependencies retain their upstream license files and metadata.

Python 3.12.15 is built by Astral's python-build-standalone project, release 20261003. Python's license is in `python/lib/python3.12/LICENSE.txt`. Additional component licenses and the upstream build metadata are in `licenses/python`. Source and build recipes: https://github.com/astral-sh/python-build-standalone/tree/20261003 and https://www.python.org/downloads/source/.

Node 22.23.3 is the official darwin-arm64 distribution from https://nodejs.org/dist/v22.23.3/. Its license file includes the bundled third-party notices at `node/LICENSE`. npm, headers and package-install commands are not required by the application.

Pi agent-core, pi-ai and pi-telemetry are pinned to 1.0.4 from https://github.com/earendil-works/pi. Their npm packages and other JavaScript dependencies are assembled from the committed npm lock with SHA-512 verification. Package scripts are never executed. Exact versions, license identifiers and integrity values are in `manifest.json`; notices remain with each package under `repo/prototypes/pi_assistant/node_modules`.

Supplementary notices for packages whose npm tarballs omit license files are in `licenses/npm`, with pinned source URLs and hashes in the runtime lock. The proxy-agent-negotiate package declares MIT and the same author as the proxy-agent project; its supplied notice is that project's existing MIT notice. AWS notices are from a pinned source snapshot of the official SDK repository. The Standard Webhooks JavaScript library uses the MIT notice under the upstream `libraries` directory.

Python wheels are pinned to individual macOS arm64 or platform-independent artifacts from PyPI. Their notices remain in each distribution's `.dist-info` directory. Wheels are unpacked without invoking setup, build or installation hooks. The one native wheel, pydantic-core, is built for CPython 3.12 and macOS arm64.

The bundled Vera adapter and durable task modules retain the repository's MIT license at `repo/LICENSE`. No user settings, history, credentials, developer environment or installed package directory is copied into this runtime.
