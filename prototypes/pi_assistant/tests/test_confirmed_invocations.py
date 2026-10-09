import concurrent.futures
import os
import sqlite3
import tempfile
import threading
import time
import unittest
from pathlib import Path

from pi_assistant.confirmed_invocations import ConfirmedInvocationFixture, FixtureInvocationAuthority, InvocationDenied, SYNTHETIC_SCHEMA, canonical, digest
from routers.task_store import TaskConflict, TaskStore


def binding(**changes):
    return {**{'hostOriginID': 'explicit-chat-origin', 'operationID': 'operation-one', 'assistantID': 'assistant', 'conversationID': 'conversation', 'serverID': 'synthetic', 'endpoint': 'https://fixture.invalid/mcp', 'tool': 'fixture.record', 'schemaJSON': canonical(SYNTHETIC_SCHEMA), 'argumentsJSON': canonical({'value': 'synthetic value'}), 'permissionRevision': 'permission-one', 'authorizationGeneration': 'authorization-one', 'expiresAtMilliseconds': int(time.time() * 1000) + 60000}, **changes}


class ConfirmedInvocationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='vera-invocation-tests-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve() / 'fixture'
        self.binding = binding()
        self.scope = {key: self.binding[key] for key in ('hostOriginID', 'assistantID', 'conversationID')}
        self.authority = FixtureInvocationAuthority(self.binding)
        self.fixture = ConfirmedInvocationFixture(self.root, self.authority, create=True)
        self.addCleanup(self.fixture.close)

    def ready(self):
        receipt = self.fixture.prepare(self.binding)
        result = self.fixture.decisions.respond(self.scope, receipt['taskID'], receipt['decisionID'], 'reply-one', True)
        self.assertEqual(result['phase'], 'ready')
        self.assertEqual(self.fixture.effect_count(), 0)
        return receipt

    def reopen(self):
        self.fixture.close()
        self.fixture = ConfirmedInvocationFixture(self.root, FixtureInvocationAuthority(self.binding), create=False)
        self.addCleanup(self.fixture.close)

    def test_pending_is_prompt_and_does_not_execute(self):
        started = time.monotonic()
        receipt = self.fixture.prepare(self.binding)
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual(receipt['phase'], 'awaiting_decision')
        self.assertEqual(receipt['bindingDigest'], digest(self.binding))
        self.assertEqual(self.fixture.prepare(self.binding), receipt)
        with self.assertRaises(InvocationDenied):
            self.fixture.dispatch_synthetic(self.scope, receipt['taskID'])
        self.assertEqual(self.fixture.effect_count(), 0)

    def test_approval_exactly_one_effect_and_completed_replay(self):
        receipt = self.ready()
        result = self.fixture.dispatch_synthetic(self.scope, receipt['taskID'])
        self.assertEqual(self.fixture.dispatch_synthetic(self.scope, receipt['taskID']), result)
        self.assertEqual(self.fixture.effect_count(), 1)
        self.assertEqual(self.fixture.inspect(self.scope, receipt['taskID'])['phase'], 'effect_completed')
        self.reopen()
        self.assertEqual(self.fixture.dispatch_synthetic(self.scope, receipt['taskID']), result)
        self.assertEqual(self.fixture.effect_count(), 1)
        self.assertEqual(self.fixture.inspect(self.scope, receipt['taskID'])['state'], 'completed')

    def test_duplicate_binding_conflicts(self):
        receipt = self.fixture.prepare(self.binding)
        for changes in [{'argumentsJSON': canonical({'value': 'other'})}, {'expiresAtMilliseconds': self.binding['expiresAtMilliseconds'] - 1}]:
            with self.assertRaises(TaskConflict):
                self.fixture.prepare({**self.binding, **changes})
        self.assertEqual(len(self.fixture.store.list()), 1)
        self.assertEqual(self.fixture.inspect(self.scope, receipt['taskID'])['phase'], 'awaiting_decision')

    def test_schema_destination_generation_and_scope_are_host_bound(self):
        for field in ['serverID', 'endpoint', 'schemaJSON', 'tool', 'permissionRevision', 'authorizationGeneration', 'hostOriginID', 'assistantID', 'conversationID']:
            changed = 'https://other.invalid/mcp' if field == 'endpoint' else canonical({'type': 'object'}) if field == 'schemaJSON' else 'different'
            with self.assertRaises(InvocationDenied):
                self.fixture.prepare({**self.binding, field: changed})
        self.assertEqual(self.fixture.store.list(), [])

    def test_decision_requires_capability_exact_scope_and_current_id(self):
        receipt = self.fixture.prepare(self.binding)
        with self.assertRaises(InvocationDenied):
            self.fixture._respond(object(), self.scope, receipt['taskID'], receipt['decisionID'], 'model-reply', True)
        with self.assertRaises(InvocationDenied):
            self.fixture.decisions.respond({**self.scope, 'assistantID': 'other'}, receipt['taskID'], receipt['decisionID'], 'reply', True)
        with self.assertRaises(TaskConflict):
            self.fixture.decisions.respond(self.scope, receipt['taskID'], 'wrong', 'reply', True)
        with self.assertRaises(InvocationDenied):
            self.fixture.decisions.respond(self.scope, receipt['taskID'], receipt['decisionID'], 'reply', 1)
        self.assertEqual(self.fixture.effect_count(), 0)

    def test_decision_reply_idempotency_and_decline(self):
        receipt = self.fixture.prepare(self.binding)
        once = self.fixture.decisions.respond(self.scope, receipt['taskID'], receipt['decisionID'], 'reply', False)
        self.assertEqual(self.fixture.decisions.respond(self.scope, receipt['taskID'], receipt['decisionID'], 'reply', False), once)
        with self.assertRaises(TaskConflict):
            self.fixture.decisions.respond(self.scope, receipt['taskID'], receipt['decisionID'], 'reply', True)
        with self.assertRaises(InvocationDenied):
            self.fixture.dispatch_synthetic(self.scope, receipt['taskID'])
        self.assertEqual(once['phase'], 'declined')
        self.assertEqual(self.fixture.effect_count(), 0)

    def test_cancel_before_and_after_approval(self):
        for index in range(2):
            receipt = self.fixture.prepare({**self.binding, 'operationID': str(index)})
            if index:
                self.fixture.decisions.respond(self.scope, receipt['taskID'], receipt['decisionID'], 'reply', True)
            self.fixture.cancel(self.scope, receipt['taskID'])
            with self.assertRaises(InvocationDenied):
                self.fixture.dispatch_synthetic(self.scope, receipt['taskID'])
        self.assertEqual(self.fixture.effect_count(), 0)

    def test_approval_does_not_survive_owner_restart(self):
        receipt = self.ready()
        self.reopen()
        self.assertEqual(self.fixture.inspect(self.scope, receipt['taskID'])['phase'], 'stale')
        with self.assertRaises(InvocationDenied):
            self.fixture.dispatch_synthetic(self.scope, receipt['taskID'])
        self.assertEqual(self.fixture.effect_count(), 0)

    def test_close_invalidates_old_instance(self):
        receipt = self.ready()
        old = self.fixture
        self.reopen()
        for call in [lambda: old.prepare(self.binding), lambda: old.inspect(self.scope, receipt['taskID']), lambda: old.cancel(self.scope, receipt['taskID']), lambda: old.dispatch_synthetic(self.scope, receipt['taskID']), old.effect_count]:
            with self.assertRaises(InvocationDenied):
                call()
        self.assertEqual(self.fixture.effect_count(), 0)

    def test_close_reopen_during_paused_dispatch(self):
        receipt = self.ready()
        entered, release = threading.Event(), threading.Event()
        def pause():
            entered.set()
            self.assertTrue(release.wait(5))
        old = self.fixture
        with concurrent.futures.ThreadPoolExecutor() as pool:
            future = pool.submit(old.dispatch_synthetic, self.scope, receipt['taskID'], before_effect=pause)
            self.assertTrue(entered.wait(5))
            self.reopen()
            release.set()
            with self.assertRaises(InvocationDenied):
                future.result(timeout=5)
        self.assertEqual(self.fixture.effect_count(), 0)
        self.assertEqual(self.fixture.inspect(self.scope, receipt['taskID'])['phase'], 'effect_uncertain')

    def test_revocation_at_effect_and_result_boundaries(self):
        receipt = self.ready()
        with self.assertRaises(InvocationDenied):
            self.fixture.dispatch_synthetic(self.scope, receipt['taskID'], before_effect=self.authority.revoke)
        self.assertEqual(self.fixture.effect_count(), 0)
        self.assertEqual(self.fixture.inspect(self.scope, receipt['taskID'])['phase'], 'effect_uncertain')

    def test_cancel_at_result_discards_completion_without_replay(self):
        receipt = self.ready()
        with self.assertRaises(InvocationDenied):
            self.fixture.dispatch_synthetic(self.scope, receipt['taskID'], after_effect=lambda: self.fixture.cancel(self.scope, receipt['taskID']))
        self.assertEqual(self.fixture.effect_count(), 1)
        result = self.fixture.inspect(self.scope, receipt['taskID'])
        self.assertEqual((result['state'], result['phase'], result['result']), ('canceled', 'effect_uncertain', None))
        with self.assertRaises(InvocationDenied):
            self.fixture.dispatch_synthetic(self.scope, receipt['taskID'])
        self.assertEqual(self.fixture.effect_count(), 1)

    def test_revocation_at_result_discards_completion(self):
        receipt = self.ready()
        with self.assertRaises(InvocationDenied):
            self.fixture.dispatch_synthetic(self.scope, receipt['taskID'], after_effect=self.authority.revoke)
        self.assertEqual(self.fixture.effect_count(), 1)
        self.assertIsNone(self.fixture.inspect(self.scope, receipt['taskID'])['result'])

    def test_locked_database_rechecks_expiry_before_effect(self):
        receipt = self.ready()
        writer = sqlite3.connect(self.fixture.store.path, check_same_thread=False)
        self.addCleanup(writer.close)
        timers = []
        def pause():
            writer.execute('BEGIN IMMEDIATE')
            self.fixture.deadlines[receipt['taskID']] = time.monotonic() + .05
            timer = threading.Timer(.2, writer.commit)
            timer.start()
            timers.append(timer)
        with self.assertRaises(InvocationDenied):
            self.fixture.dispatch_synthetic(self.scope, receipt['taskID'], before_effect=pause)
        for timer in timers:
            timer.join()
        self.assertEqual(self.fixture.effect_count(), 0)

    def test_concurrent_dispatch_cannot_duplicate_effect(self):
        receipt = self.ready()
        entered, release = threading.Event(), threading.Event()
        def pause():
            entered.set()
            self.assertTrue(release.wait(5))
        with concurrent.futures.ThreadPoolExecutor() as pool:
            future = pool.submit(self.fixture.dispatch_synthetic, self.scope, receipt['taskID'], before_effect=pause)
            self.assertTrue(entered.wait(5))
            with self.assertRaises(InvocationDenied):
                self.fixture.dispatch_synthetic(self.scope, receipt['taskID'])
            release.set()
            self.assertEqual(future.result(timeout=5)['status'], 'completed')
        self.assertEqual(self.fixture.effect_count(), 1)

    def test_invalid_json_and_deadlines_fail_closed(self):
        for arguments in ['{"value":"one","value":"two"}', '{"value":NaN}', '{"value":1e999}', '{"value":1}', '{"value":"one","extra":true}', '{"é":1,"e\\u0301":2}']:
            with self.assertRaises(InvocationDenied):
                self.fixture.prepare({**self.binding, 'argumentsJSON': arguments})
        for deadline in [0, True, int(time.time() * 1000) - 1, int(time.time() * 1000) + 3601000]:
            with self.assertRaises(InvocationDenied):
                self.fixture.prepare({**self.binding, 'expiresAtMilliseconds': deadline})
        self.assertEqual(self.fixture.store.list(), [])

    def test_no_existing_database_migration(self):
        other = Path(self.temporary.name).resolve() / 'existing'
        other.mkdir(mode=0o700)
        store = TaskStore(str(other / 'tasks.sqlite'))
        with store.connect() as db:
            before = list(db.execute('SELECT name,sql FROM sqlite_master'))
        for create in [True, False]:
            with self.assertRaises((InvocationDenied, FileExistsError, FileNotFoundError)):
                ConfirmedInvocationFixture(other, self.authority, create=create)
        with store.connect() as db:
            self.assertEqual(before, list(db.execute('SELECT name,sql FROM sqlite_master')))

    def test_exclusive_owner_and_fifo_rejection(self):
        with self.assertRaises(BlockingIOError):
            ConfirmedInvocationFixture(self.root, self.authority, create=False)
        other = Path(self.temporary.name).resolve() / 'fifo'
        other.mkdir(mode=0o700)
        os.mkfifo(other / 'fixture.json', 0o600)
        started = time.monotonic()
        with self.assertRaises(InvocationDenied):
            ConfirmedInvocationFixture(other, self.authority, create=False)
        self.assertLess(time.monotonic() - started, .5)

    def test_symlink_and_hardlink_rejection(self):
        outside = Path(self.temporary.name).resolve() / 'outside'
        outside.write_text('untouched')
        linked = self.root / 'linked'
        linked.symlink_to(outside)
        with self.assertRaises(InvocationDenied):
            ConfirmedInvocationFixture(self.root, self.authority, create=False)
        linked.unlink()
        os.link(outside, linked)
        with self.assertRaises(InvocationDenied):
            ConfirmedInvocationFixture(self.root, self.authority, create=False)
        self.assertEqual(outside.read_text(), 'untouched')


if __name__ == '__main__':
    unittest.main()
