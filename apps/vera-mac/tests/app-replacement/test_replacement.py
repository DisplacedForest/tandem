from __future__ import annotations

import os
from pathlib import Path
import plistlib
import platform
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
import zipfile
import struct


ROOT = Path(__file__).resolve().parents[2]


def set_xattr(path: Path, name: str, value: bytes) -> None:
    subprocess.run(["/usr/bin/xattr", "-wx", name, value.hex(), str(path)], check=True)


def get_xattr(path: Path, name: str) -> bytes:
    return bytes.fromhex(subprocess.check_output(["/usr/bin/xattr", "-px", name, str(path)], text=True))


class ReplacementTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.build = tempfile.TemporaryDirectory(prefix="vera-replacement-build-")
        cls.runner = Path(cls.build.name) / "replacement-tests"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "6", "-target", f"{platform.machine()}-apple-macosx26.0", "-module-cache-path",
            str(Path(cls.build.name) / "modules"),
            str(ROOT / "Sources/Vera/SafeAppReplacement.swift"),
            str(ROOT / "Sources/Vera/AppUpdateArchive.swift"),
            str(ROOT / "tests/app-replacement/main.swift"), "-o", str(cls.runner),
        ], check=True)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.build.cleanup()

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="vera-replacement-fixture-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.target = self.root / "User's Tandem.app"
        self.source = self.root / "New Tandem.app"
        self.bundle(self.target, "1.0.0", "old")
        self.bundle(self.source, "2.0.0", "new")

    def bundle(self, path: Path, version: str, text: str, identifier: str = "app.tandem.mac", executable_name: str = "Tandem") -> None:
        executable = path / "Contents/MacOS" / executable_name
        executable.parent.mkdir(parents=True)
        executable.write_text(f"#!/bin/sh\nprintf '%s' '{text}'\n")
        executable.chmod(0o755)
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version, "CFBundleExecutable": executable_name,
        }))

    def run_fixture(self, mode: str = "mock", first: bool = False) -> subprocess.CompletedProcess[str]:
        return subprocess.run([str(self.runner), mode, str(self.source), str(self.target),
                               "2.0.0", "first" if first else "update"], capture_output=True, text=True)

    def output(self, bundle: Path | None = None) -> str:
        app = bundle or self.target
        executable_name = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleExecutable"]
        return subprocess.check_output([str(app / "Contents/MacOS" / executable_name)], text=True)

    def receipt_state(self, receipt: Path) -> str:
        return subprocess.check_output([str(self.runner), "inspect", str(receipt)], text=True).strip()

    def test_atomic_swap_retains_executable_rollback_and_xattrs(self) -> None:
        set_xattr(self.target, "org.vera.test", b"old")
        set_xattr(self.source, "org.vera.test", b"new")
        set_xattr(self.source / "Contents/MacOS/Tandem", "org.vera.test", b"resource")
        result = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = Path(result.stdout.strip())
        previous = receipt.parent / self.target.name
        self.assertEqual(self.output(), "new")
        self.assertEqual(self.output(previous), "old")
        self.assertEqual(get_xattr(self.target, "org.vera.test"), b"new")
        self.assertEqual(get_xattr(previous, "org.vera.test"), b"old")
        self.assertEqual(get_xattr(self.target / "Contents/MacOS/Tandem", "org.vera.test"), b"resource")
        self.assertEqual(self.receipt_state(receipt), "installed")

    def test_legacy_executable_upgrade_and_rollback(self) -> None:
        shutil.rmtree(self.target)
        self.bundle(self.target, "1.0.0", "old", executable_name="Vera")
        result = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = Path(result.stdout.strip())
        previous = receipt.parent / self.target.name
        self.assertTrue((self.target / "Contents/MacOS/Tandem").is_file())
        self.assertFalse((self.target / "Contents/MacOS/Vera").exists())
        self.assertTrue((previous / "Contents/MacOS/Vera").is_file())
        self.assertEqual(self.output(), "new")
        self.assertEqual(self.output(previous), "old")
        rollback = subprocess.run([str(self.runner), "rollback-mock", str(receipt)], capture_output=True, text=True)
        self.assertEqual(rollback.returncode, 0, rollback.stderr)
        self.assertTrue((self.target / "Contents/MacOS/Vera").is_file())
        self.assertFalse((self.target / "Contents/MacOS/Tandem").exists())
        self.assertEqual(self.output(), "old")

    def test_legacy_identifier_upgrade_and_rollback(self) -> None:
        import json
        metadata = self.target / "Contents/Info.plist"
        values = plistlib.loads(metadata.read_bytes())
        values["CFBundleIdentifier"] = "app.vera.mac"
        metadata.write_bytes(plistlib.dumps(values))
        result = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = Path(result.stdout.strip())
        self.assertEqual(json.loads(receipt.read_text())["previousIdentifier"], "app.vera.mac")
        self.assertEqual(plistlib.loads(metadata.read_bytes())["CFBundleIdentifier"], "app.tandem.mac")
        rollback = subprocess.run([str(self.runner), "rollback-mock", str(receipt)], capture_output=True, text=True)
        self.assertEqual(rollback.returncode, 0, rollback.stderr)
        self.assertEqual(plistlib.loads(metadata.read_bytes())["CFBundleIdentifier"], "app.vera.mac")
        self.assertEqual(self.output(), "old")

    def test_unrelated_installed_identity_is_preserved(self) -> None:
        metadata = self.target / "Contents/Info.plist"
        values = plistlib.loads(metadata.read_bytes())
        values["CFBundleIdentifier"] = "unrelated.app"
        metadata.write_bytes(plistlib.dumps(values))
        self.assertNotEqual(self.run_fixture().returncode, 0)
        self.assertEqual(self.output(), "old")

    def test_old_receipt_without_previous_identifier_can_roll_back(self) -> None:
        import json
        result = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = Path(result.stdout.strip())
        values = json.loads(receipt.read_text())
        values.pop("previousIdentifier", None)
        receipt.write_text(json.dumps(values))
        rollback = subprocess.run([str(self.runner), "rollback-mock", str(receipt)], capture_output=True, text=True)
        self.assertEqual(rollback.returncode, 0, rollback.stderr)
        self.assertEqual(self.output(), "old")

    def test_copy_signature_and_swap_failures_preserve_old_app(self) -> None:
        for mode in ("copy-failure", "reject-signature", "fail-copied", "fail-prepared", "swap-failure"):
            with self.subTest(mode=mode):
                before = self.target.stat().st_ino
                result = self.run_fixture(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.output(), "old")
                self.assertEqual(self.target.stat().st_ino, before)
                self.assertEqual(list(self.root.glob(".Vera-replacement-*")), [])

    def test_missing_executable_rejected_before_copy(self) -> None:
        (self.source / "Contents/MacOS/Tandem").unlink()
        result = self.run_fixture()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.output(), "old")

    def test_wrong_version_and_identity_are_rejected(self) -> None:
        plist = self.source / "Contents/Info.plist"
        original = plist.read_bytes()
        for key, value in (("CFBundleShortVersionString", "9.0.0"), ("CFBundleIdentifier", "other.app")):
            values = plistlib.loads(original)
            values[key] = value
            plist.write_bytes(plistlib.dumps(values))
            self.assertNotEqual(self.run_fixture().returncode, 0)
            self.assertEqual(self.output(), "old")

    def test_external_symlink_and_target_symlink_are_rejected(self) -> None:
        link = self.source / "Contents/outside"
        link.symlink_to(self.target)
        self.assertNotEqual(self.run_fixture().returncode, 0)
        link.unlink()
        saved = self.root / "Saved.app"
        self.target.rename(saved)
        self.target.symlink_to(saved)
        self.assertNotEqual(self.run_fixture().returncode, 0)
        self.assertEqual(self.output(saved), "old")
        self.assertTrue(self.target.is_symlink())

    def test_explicit_first_install_and_missing_update(self) -> None:
        shutil.rmtree(self.target)
        self.assertNotEqual(self.run_fixture().returncode, 0)
        self.assertFalse(self.target.exists())
        result = self.run_fixture(first=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output(), "new")
        self.assertEqual(self.receipt_state(Path(result.stdout.strip())), "installed")

    def rollback_folders(self) -> list[Path]:
        return sorted(self.root.glob(".Vera-replacement-*"))

    def test_repeat_installs_keep_only_the_latest_rollback_copy(self) -> None:
        first = self.run_fixture()
        self.assertEqual(first.returncode, 0, first.stderr)
        second = self.run_fixture()
        self.assertEqual(second.returncode, 0, second.stderr)
        receipt = Path(second.stdout.strip())
        self.assertEqual(self.rollback_folders(), [receipt.parent])
        self.assertFalse(Path(first.stdout.strip()).exists())
        self.assertEqual(self.receipt_state(receipt), "installed")
        self.assertEqual(self.output(), "new")

    def test_rollback_restores_previous_app_and_leaves_one_rollback_copy(self) -> None:
        result = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stderr)
        rollback = subprocess.run([str(self.runner), "rollback-mock", result.stdout.strip()], capture_output=True, text=True)
        self.assertEqual(rollback.returncode, 0, rollback.stderr)
        receipt = Path(rollback.stdout.strip())
        self.assertEqual(self.output(), "old")
        self.assertEqual(self.rollback_folders(), [receipt.parent])
        self.assertEqual(self.output(receipt.parent / self.target.name), "new")
        self.assertEqual(self.receipt_state(receipt), "installed")

    def test_interrupted_leftover_is_removed_by_next_install(self) -> None:
        stale = self.root / ".Vera-replacement-stale"
        (stale / self.target.name).mkdir(parents=True)
        (stale / self.target.name / "partial").write_text("partial")
        empty = self.root / ".Vera-replacement-empty"
        empty.mkdir()
        result = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set(self.rollback_folders()), {Path(result.stdout.strip()).parent, empty})

    def test_rollback_folder_with_extra_contents_is_kept(self) -> None:
        first = self.run_fixture()
        self.assertEqual(first.returncode, 0, first.stderr)
        kept = Path(first.stdout.strip()).parent
        extra = kept / "Earlier.app"
        extra.mkdir()
        (extra / "file").write_text("keep")
        second = self.run_fixture()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(set(self.rollback_folders()), {kept, Path(second.stdout.strip()).parent})
        self.assertEqual((extra / "file").read_text(), "keep")

    def test_receipt_links_and_special_files_never_qualify_or_block(self) -> None:
        first = self.run_fixture()
        self.assertEqual(first.returncode, 0, first.stderr)
        receipt = Path(first.stdout.strip())
        saved = self.root / "saved-receipt.json"
        saved.write_bytes(receipt.read_bytes())
        linked = self.root / ".Vera-replacement-linked"
        linked.mkdir()
        (linked / "receipt.json").symlink_to(saved)
        (linked / "notes.txt").write_text("keep")
        linked_only = self.root / ".Vera-replacement-linked-only"
        linked_only.mkdir()
        (linked_only / "receipt.json").symlink_to(saved)
        pipe = self.root / ".Vera-replacement-pipe"
        pipe.mkdir()
        os.mkfifo(pipe / "receipt.json")
        second = subprocess.run([str(self.runner), "mock", str(self.source), str(self.target), "2.0.0", "update"],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(set(self.rollback_folders()),
                         {Path(second.stdout.strip()).parent, linked, linked_only, pipe})
        self.assertEqual((linked / "notes.txt").read_text(), "keep")
        self.assertTrue(saved.exists())

    def test_differently_cased_target_path_still_leaves_one_rollback_copy(self) -> None:
        alias = self.target.with_name(self.target.name.lower())
        if alias == self.target or not alias.exists():
            self.skipTest("Volume is case-sensitive")
        first = self.run_fixture()
        self.assertEqual(first.returncode, 0, first.stderr)
        second = subprocess.run([str(self.runner), "mock", str(self.source), str(alias), "2.0.0", "update"],
                                capture_output=True, text=True)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.rollback_folders(), [Path(second.stdout.strip()).parent])
        self.assertEqual(self.output(), "new")

    def test_unrelated_folders_and_links_are_left_alone(self) -> None:
        other = self.root / "Other.app"
        self.bundle(other, "1.0.0", "other")
        foreign = subprocess.run([str(self.runner), "mock", str(self.source), str(other), "2.0.0", "update"],
                                 capture_output=True, text=True)
        self.assertEqual(foreign.returncode, 0, foreign.stderr)
        foreign_receipt = Path(foreign.stdout.strip())
        unknown = self.root / ".Vera-replacement-unknown"
        unknown.mkdir()
        (unknown / "notes.txt").write_text("keep")
        unreadable = self.root / ".Vera-replacement-unreadable"
        unreadable.mkdir()
        (unreadable / "receipt.json").write_text("not a receipt")
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "file").write_text("untouched")
        link = self.root / ".Vera-replacement-link"
        link.symlink_to(outside)
        for _ in range(2):
            result = self.run_fixture()
            self.assertEqual(result.returncode, 0, result.stderr)
        current = Path(result.stdout.strip()).parent
        self.assertEqual(set(self.rollback_folders()), {current, foreign_receipt.parent, unknown, unreadable, link})
        self.assertEqual(self.receipt_state(foreign_receipt), "installed")
        self.assertEqual(self.output(foreign_receipt.parent / other.name), "other")
        self.assertEqual((unknown / "notes.txt").read_text(), "keep")
        self.assertTrue(link.is_symlink())
        self.assertEqual((outside / "file").read_text(), "untouched")

    def test_failed_install_keeps_the_retained_rollback_copy(self) -> None:
        result = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = Path(result.stdout.strip())
        for mode in ("copy-failure", "reject-signature", "fail-copied", "fail-prepared"):
            with self.subTest(mode=mode):
                self.assertNotEqual(self.run_fixture(mode).returncode, 0)
                self.assertEqual(self.rollback_folders(), [receipt.parent])
                self.assertEqual(self.receipt_state(receipt), "installed")
                self.assertEqual(self.output(receipt.parent / self.target.name), "old")

    def test_sigkill_during_copy_and_both_sides_of_swap(self) -> None:
        for phase in ("copy", "copied", "prepared", "installed"):
            with self.subTest(phase=phase):
                marker = self.root / "stopped"
                process = subprocess.Popen([str(self.runner), "kill-" + phase, str(self.source),
                    str(self.target), "2.0.0", "update", str(marker)], stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, text=True)
                try:
                    deadline = time.monotonic() + 10
                    while not marker.exists() and time.monotonic() < deadline:
                        if process.poll() is not None:
                            self.fail(str(process.communicate()))
                        time.sleep(0.02)
                    self.assertTrue(marker.exists())
                    self.assertNotEqual(self.run_fixture().returncode, 0)
                    os.kill(process.pid, signal.SIGKILL)
                    process.communicate(timeout=10)
                    self.assertEqual(process.returncode, -signal.SIGKILL)
                    self.assertEqual(self.output(), "new" if phase == "installed" else "old")
                    receipts = list(self.root.glob(".Vera-replacement-*/receipt.json"))
                    if phase in ("prepared", "installed"):
                        self.assertEqual(len(receipts), 1)
                        self.assertEqual(self.receipt_state(receipts[0]), "installed" if phase == "installed" else "prepared")
                    if phase == "installed":
                        self.assertEqual(self.output(receipts[0].parent / self.target.name), "old")
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.communicate()
                marker.unlink(missing_ok=True)
                for path in self.root.glob(".Vera-replacement-*"):
                    shutil.rmtree(path)
                shutil.rmtree(self.target)
                self.bundle(self.target, "1.0.0", "old")

    def test_real_signature_check_rejects_unsigned_fixture(self) -> None:
        result = self.run_fixture("real")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signature", result.stderr.lower())
        self.assertEqual(self.output(), "old")

    def test_receipt_detects_in_place_content_changes(self) -> None:
        result = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = Path(result.stdout.strip())
        executable = self.target / "Contents/MacOS/Tandem"
        original = executable.read_bytes()
        executable.write_text("different code")
        self.assertEqual(self.receipt_state(receipt), "changed")
        executable.write_bytes(original)
        self.assertEqual(self.receipt_state(receipt), "installed")
        (receipt.parent / self.target.name / "Contents/MacOS/Tandem").write_text("different prior code")
        self.assertEqual(self.receipt_state(receipt), "changed")
        rollback = subprocess.run([str(self.runner), "rollback", str(receipt)], capture_output=True, text=True)
        self.assertNotEqual(rollback.returncode, 0)
        self.assertEqual(self.output(), "new")

    def test_archive_preflight_rejects_unsafe_entries_before_extraction(self) -> None:
        archive = self.root / "update.zip"
        outside = self.root / "escape"
        outside.write_text("untouched")
        destination = self.root / "expanded"
        for name in ("../escape", "/tmp/escape", "Tandem.app/../../escape", "Tandem.app/./file", "Tandem.app//file",
                     "__MACOSX/._..", "__MACOSX/._outside", "__MACOSX/Tandem.app/._..",
                     "__MACOSX/Tandem.app/._missing", "Tandem.app/._..", "Tandem.app/._file"):
            with self.subTest(name=name):
                with zipfile.ZipFile(archive, "w") as output:
                    output.writestr(name, "bad")
                result = subprocess.run([str(self.runner), "extract", str(archive), str(destination)], capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(destination.exists())
                self.assertEqual(outside.read_text(), "untouched")
        with zipfile.ZipFile(archive, "w") as output:
            link = zipfile.ZipInfo("Tandem.app/link")
            link.create_system = 3
            link.external_attr = 0o120777 << 16
            output.writestr(link, "../../escape")
            output.writestr("Tandem.app/link/file", "bad")
        self.assertNotEqual(subprocess.run([str(self.runner), "archive", str(archive)], capture_output=True).returncode, 0)
        with zipfile.ZipFile(archive, "w") as output:
            entry = zipfile.ZipInfo("Tandem.app/file")
            entry.extra = struct.pack("<HH", 0x7075, 3) + b"bad"
            output.writestr(entry, "data")
        self.assertNotEqual(subprocess.run([str(self.runner), "archive", str(archive)], capture_output=True).returncode, 0)

    def test_archive_preflight_accepts_release_zip_and_rejects_header_mismatch(self) -> None:
        archive = self.root / "update.zip"
        release = self.root / "Tandem.app"
        shutil.copytree(self.source, release)
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(release), str(archive)], check=True)
        result = subprocess.run([str(self.runner), "archive", str(archive)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        destination = self.root / "expanded"
        result = subprocess.run([str(self.runner), "extract", str(archive), str(destination)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output(destination / "Tandem.app"), "new")
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
            output.writestr("Tandem.app/file", "content")
        result = subprocess.run([str(self.runner), "archive", str(archive)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        raw = bytearray(archive.read_bytes())
        raw[30:34] = b"../x"
        archive.write_bytes(raw)
        self.assertNotEqual(subprocess.run([str(self.runner), "archive", str(archive)], capture_output=True).returncode, 0)

    def test_archive_preflight_rejects_unlisted_local_record(self) -> None:
        archive = self.root / "update.zip"
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("Tandem.app/hidden", "hidden")
            output.writestr("Tandem.app/listed", "listed")
        raw = bytearray(archive.read_bytes())
        end = raw.rfind(b"PK\x05\x06")
        central = struct.unpack_from("<I", raw, end + 16)[0]
        first_size = 46 + sum(struct.unpack_from("<HHH", raw, central + 28))
        del raw[central:central + first_size]
        end -= first_size
        struct.pack_into("<HH", raw, end + 8, 1, 1)
        struct.pack_into("<I", raw, end + 12, end - central)
        archive.write_bytes(raw)
        result = subprocess.run([str(self.runner), "archive", str(archive)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unlisted", result.stderr)

    def test_signed_fixture_integrity_continuity_and_explicit_rollback(self) -> None:
        fixture = os.environ.get("VERA_REPLACEMENT_SIGNED_FIXTURE")
        if not fixture:
            self.skipTest("Set VERA_REPLACEMENT_SIGNED_FIXTURE to an existing strictly signed app for host integration")
        signed = Path(fixture)
        values = plistlib.loads((signed / "Contents/Info.plist").read_bytes())
        identifier = values["CFBundleIdentifier"]
        version = values["CFBundleShortVersionString"]
        shutil.rmtree(self.target)
        shutil.rmtree(self.source)
        for destination in (self.target, self.source):
            destination.mkdir()
            for entry in signed.rglob("*"):
                copied = destination / entry.relative_to(signed)
                if entry.is_symlink():
                    copied.symlink_to(os.readlink(entry))
                elif entry.is_dir():
                    copied.mkdir()
                else:
                    copied.write_bytes(entry.read_bytes())
                    copied.chmod(entry.stat().st_mode & 0o777)
        set_xattr(self.target, "org.vera.test", b"previous")
        set_xattr(self.source, "org.vera.test", b"candidate")
        result = subprocess.run([str(self.runner), "real", str(self.source), str(self.target),
            version, "update", "unused", identifier], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = Path(result.stdout.strip())
        self.assertEqual(get_xattr(self.target, "org.vera.test"), b"candidate")
        rollback = subprocess.run([str(self.runner), "rollback", str(receipt)], capture_output=True, text=True)
        self.assertEqual(rollback.returncode, 0, rollback.stderr)
        self.assertEqual(get_xattr(self.target, "org.vera.test"), b"previous")
        restored = Path(rollback.stdout.strip())
        self.assertEqual(get_xattr(restored.parent / self.target.name, "org.vera.test"), b"candidate")
        self.assertFalse(receipt.exists())
        self.assertEqual(self.rollback_folders(), [restored.parent])
        self.assertEqual(self.receipt_state(restored), "installed")
        again = subprocess.run([str(self.runner), "rollback", str(receipt)], capture_output=True, text=True)
        self.assertNotEqual(again.returncode, 0)
        mismatch = subprocess.run([str(self.runner), "validate", "/usr/bin/true", str(signed)],
                                  capture_output=True, text=True)
        self.assertNotEqual(mismatch.returncode, 0)
        (self.source / "Contents/Info.plist").write_bytes(b"tampered")
        tampered = subprocess.run([str(self.runner), "validate", str(self.source)], capture_output=True, text=True)
        self.assertNotEqual(tampered.returncode, 0)


if __name__ == "__main__":
    unittest.main()
