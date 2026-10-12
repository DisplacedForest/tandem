from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import tarfile
import tempfile
from urllib.parse import urlsplit
from urllib.request import urlopen
import zipfile


APP = Path(__file__).resolve().parents[1]
REPO = APP.parents[1]
SOURCES = [
    'prototypes/pi_assistant/' + name for name in (
        '__init__.py', 'app_bridge.py', 'app_model.py', 'runtime.py', 'bridge.py',
        'process.py', 'agent.mjs', 'native.py', 'package.json', 'package-lock.json',
    )
] + ['services/vera-api/routers/' + name for name in (
    '__init__.py', 'tasks.py', 'task_store.py', 'task_runtime.py', 'inference_admission.py',
)] + ['LICENSE']


def file_hash(path: Path, algorithm: str = 'sha256') -> bytes:
    digest = hashlib.new(algorithm)
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.digest()


def download(url: str, digest: str, cache: Path, offline: bool, algorithm: str = 'sha256') -> Path:
    parsed = urlsplit(url)
    if parsed.scheme != 'https' or parsed.hostname not in {'github.com', 'raw.githubusercontent.com', 'nodejs.org', 'files.pythonhosted.org', 'registry.npmjs.org'}:
        raise ValueError('Unapproved dependency origin')
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / digest
    if not target.exists():
        if offline:
            raise ValueError('Pinned dependency missing from offline cache')
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as output:
            temporary = Path(output.name)
            try:
                with urlopen(url, timeout=60) as response:
                    shutil.copyfileobj(response, output)
                output.flush()
                if file_hash(temporary, algorithm).hex() != digest:
                    raise ValueError('Dependency checksum mismatch')
                temporary.replace(target)
            finally:
                temporary.unlink(missing_ok=True)
    if target.is_symlink() or not target.is_file() or file_hash(target, algorithm).hex() != digest:
        raise ValueError('Dependency cache checksum mismatch')
    return target


def relative(name: str) -> PurePosixPath:
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or '\\' in name or not path.parts:
        raise ValueError('Unsafe archive path')
    return path


def extract_tar(archive: Path, destination: Path, prefix: str) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as bundle:
        members = bundle.getmembers()
        for member in members:
            path = relative(member.name)
            if path.parts[0] != prefix or not (member.isfile() or member.isdir() or member.issym()):
                raise ValueError('Unsupported archive entry')
            target = destination.joinpath(*path.parts[1:])
            if member.issym():
                if PurePosixPath(member.linkname).is_absolute():
                    raise ValueError('External archive link')
                resolved = (target.parent / member.linkname).resolve()
                if not resolved.is_relative_to(destination.resolve()):
                    raise ValueError('External archive link')
        for member in members:
            path = relative(member.name)
            target = destination.joinpath(*path.parts[1:])
            if not target.resolve().is_relative_to(destination.resolve()):
                raise ValueError('Archive path escapes destination')
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                if target.exists() or target.is_symlink():
                    if target.is_symlink() or not target.is_file():
                        raise ValueError('Conflicting archive entry')
                    with bundle.extractfile(member) as source:
                        if hashlib.sha256(source.read()).digest() != file_hash(target):
                            raise ValueError('Conflicting archive file bytes')
                    continue
                with bundle.extractfile(member) as source, target.open('xb') as output:
                    shutil.copyfileobj(source, output)
                target.chmod(0o755 if member.mode & 0o111 else 0o644)
        for member in members:
            if member.issym():
                target = destination.joinpath(*relative(member.name).parts[1:])
                target.parent.mkdir(parents=True, exist_ok=True)
                target.symlink_to(member.linkname)
        validate_tree(destination)


def extract_wheel(archive: Path, destination: Path) -> None:
    with zipfile.ZipFile(archive) as wheel:
        entries = wheel.infolist()
        if not any('.dist-info/' in item.filename and ('license' in item.filename.lower() or 'copying' in item.filename.lower()) for item in entries):
            raise ValueError('Wheel license notice missing')
        for item in entries:
            path = relative(item.filename)
            if stat.S_ISLNK(item.external_attr >> 16) or '.data' in path.parts[0] or item.filename.endswith('.pth'):
                raise ValueError('Unsupported wheel entry')
            target = destination.joinpath(*path.parts)
            if not target.resolve().is_relative_to(destination.resolve()):
                raise ValueError('Wheel path escapes destination')
            if item.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with wheel.open(item) as source, target.open('xb') as output:
                    shutil.copyfileobj(source, output)
                target.chmod(0o644)


def validate_tree(root: Path) -> list[dict[str, str]]:
    result = []
    for path in sorted(root.rglob('*')):
        name = path.relative_to(root).as_posix()
        if path.is_symlink():
            if not path.resolve(strict=True).is_relative_to(root.resolve()):
                raise ValueError('External runtime link')
            result.append({'path': name, 'link': os.readlink(path)})
        elif path.is_file():
            result.append({'path': name, 'sha256': file_hash(path).hex()})
        elif not path.is_dir():
            raise ValueError('Special runtime file')
    return result


def materialize_links(root: Path) -> None:
    validate_tree(root)
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            source = path.resolve(strict=True)
            path.unlink()
            if source.is_dir():
                shutil.copytree(source, path)
            else:
                shutil.copy2(source, path)


def verify(root: Path, expected: str) -> None:
    manifest_path = root / 'manifest.json'
    if manifest_path.is_symlink() or file_hash(manifest_path).hex() != expected:
        raise ValueError('Runtime manifest seal mismatch')
    manifest = json.loads(manifest_path.read_text())
    actual = [entry for entry in validate_tree(root) if entry['path'] != 'manifest.json']
    if actual != manifest['files']:
        raise ValueError('Runtime inventory mismatch')


def assemble(destination: Path, cache: Path, offline: bool) -> dict:
    if destination.exists():
        raise ValueError('Runtime destination already exists')
    lock_path = APP / 'runtime/runtime-lock.json'
    lock = json.loads(lock_path.read_text())
    npm_path = REPO / 'prototypes/pi_assistant/package-lock.json'
    npm = json.loads(npm_path.read_text())
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.pi-runtime-', dir=destination.parent) as temporary:
        stage = Path(temporary) / 'PiRuntime'
        stage.mkdir()
        for name, prefix in [('python', 'python'), ('node', 'node-v' + lock['node']['version'] + '-darwin-arm64')]:
            asset = lock[name]
            archive = download(asset['url'], asset['sha256'], cache, offline)
            extract_tar(archive, stage / name, prefix)
        asset = lock['python_licenses']
        archive = download(asset['url'], asset['sha256'], cache, offline)
        notices = stage / 'licenses/python'
        notices.mkdir(parents=True)
        with tarfile.open(archive, mode='r:zst') as bundle:
            for member in bundle:
                if member.isfile() and (member.name.startswith('python/licenses/') or member.name == 'python/PYTHON.json'):
                    name = relative(member.name).name
                    with bundle.extractfile(member) as source, (notices / name).open('xb') as output:
                        shutil.copyfileobj(source, output)
        shutil.rmtree(stage / 'node/lib')
        shutil.rmtree(stage / 'node/include')
        for entry in (stage / 'node/bin').iterdir():
            if entry.name != 'node':
                entry.unlink()
        site = stage / 'python/lib/python3.12/site-packages'
        shutil.rmtree(site)
        site.mkdir()
        for asset in lock['wheels']:
            extract_wheel(download(asset['url'], asset['sha256'], cache, offline), site)
        for notice in lock['notices']:
            target = stage / 'licenses/npm' / (notice['name'] + '.txt')
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(download(notice['url'], notice['sha256'], cache, offline), target)
        for name in SOURCES:
            target = stage / 'repo' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / name, target)
        npm_audit = []
        for name, package in sorted(npm['packages'].items(), key=lambda pair: (pair[0].count('/'), pair[0])):
            if not name:
                continue
            relative(name)
            if not name.startswith('node_modules/') or not package.get('license'):
                raise ValueError('Unlicensed or unexpected npm dependency')
            algorithm, encoded = package['integrity'].split('-', 1)
            if algorithm != 'sha512':
                raise ValueError('Expected SHA-512 npm integrity')
            archive = download(package['resolved'], base64.b64decode(encoded, validate=True).hex(), cache, offline, algorithm)
            target = stage / 'repo/prototypes/pi_assistant' / name
            if target.exists():
                if target.is_symlink() or not target.is_dir():
                    raise ValueError('Invalid nested dependency directory')
                shutil.rmtree(target)
            with tarfile.open(archive) as bundle:
                prefix = relative(bundle.getmembers()[0].name).parts[0]
            extract_tar(archive, target, prefix)
            npm_audit.append({'path': name, 'version': package['version'], 'license': package['license'], 'integrity': package['integrity'], 'scripts_executed': False})
        shutil.copyfile(lock_path, stage / 'runtime-lock.json')
        shutil.copyfile(APP / 'runtime/NOTICE.md', stage / 'NOTICE.md')
        materialize_links(stage)
        manifest = {'schema': 1, 'platform': lock['platform'], 'python': 'python/bin/python3', 'node': 'node/bin/node', 'repo': 'repo', 'npm': npm_audit, 'files': validate_tree(stage)}
        (stage / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True, separators=(',', ':')) + '\n')
        stage.rename(destination)
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--cache', type=Path)
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--seal-source', type=Path)
    parser.add_argument('--verify', action='store_true')
    parser.add_argument('--manifest-sha256')
    args = parser.parse_args()
    if args.verify:
        if not args.manifest_sha256:
            parser.error('--verify requires --manifest-sha256')
        verify(args.destination.resolve(), args.manifest_sha256)
        print('Runtime inventory and compiled input seal match')
        return
    if not args.cache:
        parser.error('Assembly requires --cache')
    if sys.version_info < (3, 14):
        parser.error('Runtime assembly requires Python 3.14 or later')
    manifest = assemble(args.destination.resolve(), args.cache.resolve(), args.offline)
    if args.seal_source:
        digest = file_hash(args.destination / 'manifest.json').hex()
        with args.seal_source.open('x') as output:
            output.write('enum VeraPackagedRuntimeSeal { static let sha256 = "' + digest + '" }\n')
    print(json.dumps({'runtime': str(args.destination), 'files': len(manifest['files']), 'platform': manifest['platform'], 'scripts_executed': False}))


if __name__ == '__main__':
    main()
