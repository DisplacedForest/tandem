import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--deny-checkout', type=Path, action='append', default=[])
    parser.add_argument('--development-binary', type=Path)
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    denied = [ROOT, *[path.resolve() for path in args.deny_checkout]]
    if any(app.is_relative_to(path) or output.is_relative_to(path) for path in denied):
        raise ValueError('Copy the app and choose evidence storage outside the denied checkouts')
    profile = output / 'offline.sb'
    profile.write_text('(version 1)\n(allow default)\n(deny network-outbound)\n(allow network-outbound (remote ip "localhost:*"))\n' + '\n'.join('(deny file-read* (subpath ' + json.dumps(str(path)) + '))' for path in denied) + '\n(deny file-read-data (subpath ' + json.dumps(str(Path.home() / '.vera')) + '))\n(deny file-read* (subpath ' + json.dumps(str(Path.home() / 'Library/Keychains')) + '))\n')
    prefix = ['/usr/bin/sandbox-exec', '-f', str(profile)]
    probe = subprocess.run(prefix + ['/bin/cat', str(ROOT / 'VERSION')], capture_output=True)
    if probe.returncode == 0:
        raise AssertionError('Checkout denial probe failed')
    spec = importlib.util.spec_from_file_location('app_contract', ROOT / 'prototypes/pi_assistant/app_tests/test_app_broker.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    binary = app / 'Contents/MacOS/Vera'

    class PackagedApp(module.App):
        def __init__(self, root, repo=None):
            self.root = root.resolve()
            self.buffer = bytearray()
            self.process = subprocess.Popen(prefix + [str(binary), '--pi-broker-mock', '--root', str(self.root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, cwd=output, env={'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8', 'VERA_NO_UPDATE': '1'})
            try:
                self.ready = self.read()
                assert self.ready['op'] == 'ready'
                self.endpoint = 'http://127.0.0.1:' + str(self.ready['port'])
                self.capability = self.ready['ui_capability']
            except BaseException:
                self.close()
                raise

    module.App = PackagedApp
    checks = []
    with tempfile.TemporaryDirectory(prefix='workflow-', dir=output) as temporary:
        module.test_actual_app_pi_http_responsiveness_and_restart(Path(temporary))
        checks.append('approval, independent foreground, artifact, one delivery, restart identity, no replay')
    for loss in ['cancel', 'app', 'runtime']:
        with tempfile.TemporaryDirectory(prefix='loss-' + loss + '-', dir=output) as temporary:
            module.test_active_worker_loss_preserves_identity_without_duplicate_effect(Path(temporary), loss)
            checks.append(loss + ': descendant cleanup and preserved task identity')
    source = app / 'Contents/Resources/PiRuntime/repo/prototypes/pi_assistant/agent.mjs'
    manifest_path = app / 'Contents/Resources/PiRuntime/manifest.json'
    original = source.read_bytes()
    original_manifest = manifest_path.read_bytes()
    def refused(label):
        with tempfile.TemporaryDirectory(prefix='refused-', dir=output) as temporary:
            root = Path(temporary) / 'state'
            try:
                instance = PackagedApp(root)
            except AssertionError:
                assert not root.exists()
                checks.append(label)
            else:
                instance.close()
                raise AssertionError('Untrusted runtime was accepted')
    try:
        source.write_bytes(original + b'\n')
        refused('changed packaged source refused before runtime or state creation')
        manifest = json.loads(original_manifest)
        for entry in manifest['files']:
            if entry['path'] == 'repo/prototypes/pi_assistant/agent.mjs':
                entry['sha256'] = hashlib.sha256(source.read_bytes()).hexdigest()
        manifest_path.write_text(json.dumps(manifest, sort_keys=True, separators=(',', ':')) + '\n')
        refused('paired source and inventory tamper refused by compiled seal')
        source.write_bytes(original)
        refused('mismatched runtime inventory refused by compiled seal')
    finally:
        source.write_bytes(original)
        manifest_path.write_bytes(original_manifest)
    if args.development_binary:
        original_binary = binary.read_bytes()
        try:
            binary.write_bytes(args.development_binary.read_bytes())
            refused('ordinary development executable refuses implicit bundled runtime')
        finally:
            binary.write_bytes(original_binary)
    result = {'transport': 'app-owned-mock', 'checkout_denial_verified': True, 'runtime_paths_supplied': False, 'real_keychain_reads': 0, 'real_provider_calls': 0, 'installed_changes': 0, 'checks': checks}
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
