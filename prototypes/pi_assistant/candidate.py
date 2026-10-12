import argparse
import os
import shutil
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description='Open the integrated Vera test candidate with an injected mock provider')
    parser.add_argument('--mock', action='store_true', required=True)
    parser.add_argument('--data-root', type=Path, required=True)
    parser.add_argument('--contract-test', action='store_true')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    binary = repo / 'apps/vera-mac/.build/debug/Vera'
    node = shutil.which('node')
    if not binary.is_file() or not node:
        print('Build with mise run mac-build and configure Node before opening the candidate.', file=sys.stderr)
        return 1
    mode = '--pi-candidate-contract' if args.contract_test else '--pi-candidate-mock'
    command = [str(binary), mode, '--root', str(args.data_root.expanduser().absolute()), '--repo', str(repo), '--python', sys.executable, '--node', node, '--port', '0']
    os.execve(binary, command, {'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8', 'PYTHONDONTWRITEBYTECODE': '1'})
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
