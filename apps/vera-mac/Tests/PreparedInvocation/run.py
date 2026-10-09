import os
import subprocess
import sys
import tempfile
from pathlib import Path


app = Path(__file__).resolve().parents[2]
repository = app.parents[1]
environment = dict(os.environ)
environment['PYTHONPATH'] = str(repository / 'prototypes') + os.pathsep + str(repository / 'services/vera-api')
subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', str(repository / 'prototypes/pi_assistant/tests'), '-p', 'test_confirmed_invocations.py', '-v'], env=environment, check=True, timeout=60)
with tempfile.TemporaryDirectory(prefix='vera-prepared-invocation-') as temporary:
    root = Path(temporary).resolve()
    main = root / 'Runner.swift'
    main.write_text('''import Foundation
enum NativeTaskHTTPError: Error { case invalidResponse }
@main struct Runner {
    static func main() async {
        do {
        try await NativePreparedInvocationSelftest.run()
        try await NativePreparedInvocationSelftest.runWire(python: URL(fileURLWithPath: CommandLine.arguments[1]), repositoryRoot: URL(fileURLWithPath: CommandLine.arguments[2]), dataRoot: URL(fileURLWithPath: CommandLine.arguments[3]))
        } catch {
            FileHandle.standardError.write(Data("Prepared invocation fixture failed: \\(error)\\n".utf8))
            exit(1)
        }
    }
}
''')
    sources = [app / 'Sources/Vera' / name for name in ['NativePreparedToolInvocation.swift', 'NativePreparedInvocationSelftest.swift', 'NativePreparedInvocationFixture.swift', 'NativeTaskJSON.swift']]
    binary = root / 'Runner'
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', '-module-cache-path', str(root / 'module-cache'), *map(str, sources), str(main), '-o', str(binary)], check=True, timeout=180)
    data_root = root / 'data'
    data_root.mkdir(mode=0o700)
    subprocess.run([str(binary), sys.executable, str(repository), str(data_root)], check=True, timeout=60)
