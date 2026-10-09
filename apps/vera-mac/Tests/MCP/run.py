import shutil
import subprocess
import tempfile
from pathlib import Path


root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='vera-mcp-test-') as temporary:
    package = Path(temporary)
    source = package / 'Sources' / 'Runner'
    source.mkdir(parents=True)
    fixture = package / 'Tests' / 'MCP'
    fixture.mkdir(parents=True)
    shutil.copy(root / 'Tests/MCP/server.py', fixture / 'server.py')
    for name in ['NativeMCPTransport.swift', 'NativeMCPTransportSelftest.swift', 'NativeMCPWireJSON.swift', 'NativeTaskJSON.swift']:
        shutil.copy(root / 'Sources/Vera' / name, source / name)
    native = (root / 'Sources/Vera/NativeChatTools.swift').read_text()
    start = native.index('enum NativeJSONValue:')
    end = native.index('\nstruct NativeToolSchema:')
    (source / 'NativeJSONValue.swift').write_text('import Foundation\nenum NativeTaskHTTPError: Error { case invalidResponse }\nenum NativeToolError: Error { case invalidArguments(String) }\n' + native[start:end])
    (source / 'Runner.swift').write_text('import Foundation\n@main struct Runner { static func main() async throws { try await NativeMCPTransportSelftest.run() } }\n')
    (package / 'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Runner", platforms: [.macOS(.v26)], dependencies: [.package(url: "https://github.com/apple/swift-log.git", exact: "1.16.1"), .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")], targets: [.executableTarget(name: "Runner", dependencies: [.product(name: "Logging", package: "swift-log"), .product(name: "MCP", package: "swift-sdk")])])
''')
    shutil.copy(root / 'Package.resolved', package / 'Package.resolved')
    subprocess.run(['swift', 'run', '--package-path', str(package), '--scratch-path', str(root / '.build/mcp-transport-selftest'), 'Runner'], check=True)
