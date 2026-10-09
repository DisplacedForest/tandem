import shutil
import subprocess
import tempfile
from pathlib import Path


root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='vera-oauth-ui-test-') as temporary:
    repository = Path(temporary)
    package = repository / 'apps' / 'vera-mac'
    package.mkdir(parents=True)
    shutil.copytree(root / 'Sources', package / 'Sources')
    shutil.copytree(root.parent.parent / 'prototypes' / 'assistant-ui', repository / 'prototypes' / 'assistant-ui', ignore=shutil.ignore_patterns('.build', '.swiftpm'))
    shutil.copy(root / 'Package.swift', package / 'Package.swift')
    shutil.copy(root / 'Package.resolved', package / 'Package.resolved')
    (package / 'Sources/Vera/main.swift').write_text('import Foundation\nNativeApplicationEntry.runAsync { do { try await NativeMCPOAuthUISelftest.run(); try await NativeMCPAuthorityAuthSelftest.run() } catch { print("OAUTH UI SELFTEST FAILED: \\(error)"); exit(1) } }\n')
    subprocess.run(['swift', 'run', '--package-path', str(package), '--scratch-path', str(root / '.build/mcp-oauth-ui-selftest'), 'Vera'], check=True)
