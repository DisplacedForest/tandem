import os
import signal
import shutil
import subprocess
import tempfile
from pathlib import Path


root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='vera-mcp-read-test-') as temporary:
    repository = Path(temporary)
    package = repository / 'apps' / 'vera-mac'
    package.mkdir(parents=True)
    shutil.copytree(root / 'Sources', package / 'Sources')
    shutil.copytree(root / 'Tests/MCPRead', package / 'Tests/MCPRead')
    shutil.copytree(root.parent.parent / 'prototypes' / 'assistant-ui', repository / 'prototypes' / 'assistant-ui', ignore=shutil.ignore_patterns('.build', '.swiftpm'))
    shutil.copy(root / 'Package.swift', package / 'Package.swift')
    shutil.copy(root / 'Package.resolved', package / 'Package.resolved')
    (package / 'Sources/Vera/main.swift').write_text('import Foundation\nNativeApplicationEntry.runAsync { do { try await NativeMCPReadTestSelftest.run() } catch { print("MCP READ SELFTEST FAILED: \\(error)"); exit(1) } }\n')
    command = ['swift', 'run', '--package-path', str(package), '--scratch-path', str(root / '.build/mcp-read-selftest'), '--jobs', '4', 'Vera']
    process = subprocess.Popen(command, start_new_session=True)
    try:
        result = process.wait(timeout=600)
        if result:
            raise subprocess.CalledProcessError(result, command)
    finally:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=2)
