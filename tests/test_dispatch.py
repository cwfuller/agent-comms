"""Adversarial checks of the actual coordinator report reader and scheduling."""
import importlib.util
import io
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('dispatch', Path(__file__).with_name('dispatch.py'))
dispatch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dispatch)


class ReportContract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def report(self, name='a', counts='2\t0\t0', section='alpha\t2\n', skips=''):
        (self.root / (name + '.done')).write_text(counts + '\n' + name + '\ncomplete\n')
        (self.root / (name + '.sections')).write_text(section)
        (self.root / (name + '.skips')).write_text(skips)

    def test_complete_union(self):
        self.report()
        self.report('b', '1\t0\t1', 'beta\t2\n', 'acl-report')
        self.assertEqual(dispatch.merge_reports(self.root, ['b', 'a']),
                         ([3, 0, 1], {'beta': 2, 'alpha': 2}))

    def test_missing_worker(self):
        self.report()
        with self.assertRaises(OSError):
            dispatch.merge_reports(self.root, ['a', 'missing'])

    def test_truncated_worker(self):
        self.report()
        (self.root / 'a.done').write_text('2\t0\t0\na\n')
        with self.assertRaises(ValueError):
            dispatch.merge_reports(self.root, ['a'])

    def test_relabelled_worker(self):
        self.report()
        (self.root / 'a.done').write_text('2\t0\t0\nb\ncomplete\n')
        with self.assertRaises(ValueError):
            dispatch.merge_reports(self.root, ['a'])

    def test_invalid_counts(self):
        for counts in ('1+1\t0\t0', '-1\t0\t0', '99999999999\t0\t0', '2\t0'):
            with self.subTest(counts=counts):
                self.report(counts=counts)
                with self.assertRaises(ValueError):
                    dispatch.merge_reports(self.root, ['a'])

    def test_empty_vector(self):
        self.report(section='')
        with self.assertRaises(ValueError):
            dispatch.merge_reports(self.root, ['a'])

    def test_vector_disagrees_with_counts(self):
        self.report(section='alpha\t1\n')
        with self.assertRaises(ValueError):
            dispatch.merge_reports(self.root, ['a'])

    def test_failure_still_counts_as_coverage(self):
        self.report(counts='1\t1\t0')
        self.assertEqual(dispatch.merge_reports(self.root, ['a'])[0], [1, 1, 0])

    def test_duplicate_section_across_workers(self):
        self.report()
        self.report('b')
        with self.assertRaises(ValueError):
            dispatch.merge_reports(self.root, ['a', 'b'])

    def test_duplicate_section_within_worker(self):
        self.report(section='alpha\t1\nalpha\t1\n')
        with self.assertRaises(ValueError):
            dispatch.merge_reports(self.root, ['a'])

    def test_duplicate_skip_across_workers(self):
        self.report(counts='1\t0\t1', skips='acl-report')
        self.report('b', '1\t0\t1', 'beta\t2\n', 'acl-report')
        with self.assertRaises(ValueError):
            dispatch.merge_reports(self.root, ['a', 'b'])

    def test_duplicate_skip_within_worker(self):
        self.report(counts='0\t0\t2', skips='acl-report acl-report')
        with self.assertRaises(ValueError):
            dispatch.merge_reports(self.root, ['a'])

    def test_skip_count_mismatch(self):
        self.report(counts='1\t0\t1', skips='')
        with self.assertRaises(ValueError):
            dispatch.merge_reports(self.root, ['a'])

    def test_manifest_is_explicit(self):
        self.assertEqual(dispatch.manifest('presence\tserial\na\tparallel\n'),
                         [('presence', 'serial'), ('a', 'parallel')])

    def test_manifest_cannot_parallelize_presence(self):
        for text in ('a\tparallel\n', 'presence\tparallel\n'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                dispatch.manifest(text)

    def test_manifest_rejects_duplicates_and_paths(self):
        for row in ('a\tparallel\na\tparallel', '../a\tparallel', '/tmp/a\tparallel',
                    'a\tunknown', 'a\tparallel\tignored'):
            with self.subTest(row=row), self.assertRaises(ValueError):
                dispatch.manifest('presence\tserial\n' + row + '\n')


class CompleteRunner(unittest.TestCase):
    """Run the actual entrypoint and gates against a tiny committed test corpus."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        source = Path(__file__).parent
        (self.root / 'tests/lib').mkdir(parents=True)
        (self.root / 'helpers').mkdir()
        for path in ('run.sh', 'dispatch.py', 'lib/harness.sh'):
            shutil.copyfile(source / path, self.root / 'tests' / path)
        (self.root / 'tests/groups.tsv').write_text('presence\tserial\nsample\tparallel\n')
        (self.root / 'tests/expected-counts.tsv').write_text('total\t2\n')
        (self.root / 'tests/section-counts.tsv').write_text('presence\t1\nsample\t1\n')
        # Attestation is observable; the helper's own authorization is covered by the
        # integration group. This fixture tests whether the suite ever calls it.
        helper = self.root / 'helpers/comms.sh'
        helper.write_text('''#!/bin/bash
if [ "$1" = attest-green ]; then touch .attested; exit 0; fi
while [ "$1" != -- ]; do shift; done
shift
exec "$@"
''')
        helper.chmod(0o755)
        (self.root / 'tests/worker.sh').write_text('''#!/bin/bash
name="$1"; results="$3"
if [ "$name" = sample ]; then
  case "${PROBE_CASE:-}" in
    missing) exit 0 ;;
    crash) exit 7 ;;
  esac
fi
banner="$name"
[ "$name" = sample ] && [ "${PROBE_CASE:-}" = wrong-section ] && banner=other
printf '%s\\t1\\n' "$banner" > "$results/$name.sections"
: > "$results/$name.skips"
printf '1\\t0\\t0\\n%s\\ncomplete\\n' "$name" > "$results/$name.done"
exit 0
''')
        self.git('init', '-q', '-b', 'main')
        self.git('add', '--', 'tests', 'helpers')
        self.git('-c', 'user.name=test', '-c', 'user.email=test@test',
                 '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null',
                 'commit', '-qm', 'fixture')

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.root), *args], check=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def run_suite(self, *args, case=''):
        env = os.environ.copy()
        env['PROBE_CASE'] = case
        for key in ('BASH_ENV', 'ENV', 'SHELLOPTS', 'BASHOPTS'):
            env.pop(key, None)
        return subprocess.run(['bash', 'tests/run.sh', *args], cwd=self.root, env=env,
                              capture_output=True, text=True, timeout=30)

    def test_complete_run_reaches_attestation(self):
        run = self.run_suite()
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn('passed: 2  failed: 0  skipped: 0', run.stdout)
        self.assertTrue((self.root / '.attested').exists())

    def test_focused_run_cannot_attest_even_when_selecting_every_group(self):
        run = self.run_suite('--group', 'presence', '--group', 'sample')
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn('FOCUSED:', run.stdout)
        self.assertNotIn('passed:', run.stdout)
        self.assertFalse((self.root / '.attested').exists())

    def test_worker_exit_zero_without_report_cannot_pass(self):
        run = self.run_suite(case='missing')
        self.assertNotEqual(run.returncode, 0)
        self.assertFalse((self.root / '.attested').exists())

    def test_worker_crash_cannot_pass(self):
        run = self.run_suite(case='crash')
        self.assertNotEqual(run.returncode, 0)
        self.assertFalse((self.root / '.attested').exists())

    def test_same_total_with_wrong_section_cannot_attest(self):
        run = self.run_suite(case='wrong-section')
        self.assertNotEqual(run.returncode, 0)
        self.assertIn('per-section covered counts do not match', run.stderr)
        self.assertFalse((self.root / '.attested').exists())

    def test_manifest_comes_from_commit(self):
        (self.root / 'tests/groups.tsv').write_text('presence\tserial\n')
        run = self.run_suite()
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn('START sample', run.stdout)

    def test_working_tree_contract_cannot_reduce_coverage(self):
        (self.root / 'tests/expected-counts.tsv').write_text('total\t1\n')
        run = self.run_suite()
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn('passed: 2  failed: 0  skipped: 0', run.stdout)

    def test_section_vector_comes_from_commit(self):
        (self.root / 'tests/section-counts.tsv').write_text('presence\t1\nother\t1\n')
        run = self.run_suite()
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn('passed: 2  failed: 0  skipped: 0', run.stdout)

    def test_real_supervisor_cancellation_cannot_accept_prepared_report(self):
        self.check_real_supervisor_cancellation(nested_group=False)

    def test_real_supervisor_cancellation_reaches_nested_process_group(self):
        self.check_real_supervisor_cancellation(nested_group=True)

    def check_real_supervisor_cancellation(self, nested_group):
        # Use the production supervisor, including its separate child process group.
        shutil.copyfile(Path(__file__).parents[1] / 'helpers/comms.sh',
                        self.root / 'helpers/comms.sh')
        (self.root / 'tests/worker.sh').write_text('''#!/bin/bash
name="$1"; results="$3"
printf '%s\\t1\\n' "$name" > "$results/$name.sections"
: > "$results/$name.skips"
printf '1\\t0\\t0\\n%s\\ncomplete\\n' "$name" > "$results/$name.done"
JOB_CONTROL
sleep 60 &
echo $! > .descendant-pid
echo $$ > .worker-pid
# Worker -> supervisor -> lifeline owner -> dispatcher.
owner="$(ps -p "$PPID" -o ppid=)"
ps -p "$owner" -o ppid= > .dispatcher-pid
wait
'''.replace('JOB_CONTROL', 'set -m' if nested_group else ':'))
        proc = subprocess.Popen(['bash', 'tests/run.sh'], cwd=self.root,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                start_new_session=True)
        try:
            wait_file(self.root / '.dispatcher-pid')
            os.kill(int((self.root / '.dispatcher-pid').read_text()), signal.SIGINT)
            out, err = proc.communicate(timeout=20)
            self.assertEqual(proc.returncode, 130, out + err)
            self.assertNotIn('worker cleanup failed', err)
            self.assertNotIn('passed:', out)
            self.assertNotIn('ATTESTATION: recorded', out)
            for name in ('.worker-pid', '.descendant-pid'):
                assert_stopped(self, int((self.root / name).read_text()))
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.communicate(timeout=5)

    def test_presence_is_exclusive_and_parallel_worker_limit_is_enforced(self):
        names = ('presence', 'sample', 'other', 'last')
        (self.root / 'tests/groups.tsv').write_text(
            ''.join(name + ('\tserial\n' if name == 'presence' else '\tparallel\n') for name in names))
        (self.root / 'tests/expected-counts.tsv').write_text('total\t4\n')
        (self.root / 'tests/section-counts.tsv').write_text(''.join(name + '\t1\n' for name in names))
        self.git('add', '--', 'tests/groups.tsv', 'tests/expected-counts.tsv', 'tests/section-counts.tsv')
        self.git('-c', 'user.name=test', '-c', 'user.email=test@test',
                 '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null',
                 'commit', '-qm', 'four workers')
        (self.root / 'tests/worker.sh').write_text('''#!/bin/bash
name="$1"; results="$3"
printf 'start %s\\n' "$name" >> scheduling
case "$name" in
  presence) sleep 0.1 ;;
  sample|other)
    : > ".$name-ready"
    n=0
    while [ ! -e .sample-ready ] || [ ! -e .other-ready ]; do
      n=$((n+1)); [ "$n" -lt 500 ] || exit 9
      sleep 0.02
    done
    ;;
esac
printf 'end %s\\n' "$name" >> scheduling
printf '%s\\t1\\n' "$name" > "$results/$name.sections"
: > "$results/$name.skips"
printf '1\\t0\\t0\\n%s\\ncomplete\\n' "$name" > "$results/$name.done"
''')
        run = self.run_suite('--jobs', '2')
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        events = (self.root / 'scheduling').read_text().splitlines()
        self.assertEqual(events[:2], ['start presence', 'end presence'])
        running = peak = 0
        for row in events:
            running += 1 if row.startswith('start ') else -1
            peak = max(peak, running)
            self.assertLessEqual(running, 2)
        self.assertEqual((running, peak), (0, 2))


def wait_file(path):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if path.exists() and path.read_text().strip():
            return
        time.sleep(0.02)
    raise AssertionError('worker did not become ready: ' + str(path))


def assert_stopped(test, pid, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        probe = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='],
                               capture_output=True, text=True)
        state = probe.stdout.strip()
        if probe.returncode == 1 and not state and not probe.stderr.strip():
            return  # ps reports no matching process, without an inspection error.
        if probe.returncode != 0 or probe.stderr.strip() or not state:
            test.fail(f'cannot inspect worker {pid}: exit {probe.returncode}, {probe.stderr!r}')
        if state.startswith('Z'):
            return
        time.sleep(0.02)
    test.fail(f'worker process {pid} survived cancellation ({state})')


class RunnerOwnership(unittest.TestCase):
    setUp = CompleteRunner.setUp
    git = CompleteRunner.git
    run_suite = CompleteRunner.run_suite

    def test_group_sigkill_stops_workers_and_nested_groups(self):
        self.check_group_cancellation(signal.SIGKILL)

    def test_pending_int_then_term_stops_workers_once(self):
        self.check_group_cancellation(None, (signal.SIGINT, signal.SIGTERM))

    def test_pending_term_then_int_stops_workers_once(self):
        self.check_group_cancellation(None, (signal.SIGTERM, signal.SIGINT))

    def test_terminal_ctrl_c_with_stopped_dispatcher_stops_workers_once(self):
        self.check_group_cancellation(signal.SIGINT)

    def test_integrate_timeout_stops_term_ignoring_workers(self):
        self.check_group_cancellation('timeout')

    def check_group_cancellation(self, sig, pending_signals=()):
        shutil.copyfile(Path(__file__).parents[1] / 'helpers/comms.sh',
                        self.root / 'helpers/comms.sh')
        # Observe cleanup entry in the copied code, without changing its signal
        # handling, scheduling, lifeline or session-sweep logic.
        source = self.root / 'tests/dispatch.py'
        lines = source.read_text().splitlines(keepends=True)
        for i in range(len(lines) - 1, -1, -1):
            if lines[i].startswith(('def stop_workers(', 'def stop_owners(')):
                marker = '.worker-cleanup' if lines[i].startswith('def stop_workers(') else '.dispatch-cleanup'
                lines.insert(i + 1, f"    with open('{marker}', 'a') as probe: probe.write('cleanup\\n')\n")
        source.write_text(''.join(lines))
        (self.root / 'tests/worker.sh').write_text('''#!/bin/bash
trap '' INT TERM
set -m
bash -c 'trap "" INT TERM; echo $$ > .descendant-pid; exec sleep 60' &
echo $$ > .worker-pid
echo "$PPID" > .supervisor-pid
wait
''')
        command = ['bash', 'tests/run.sh']
        if sig == 'timeout':
            command = [str(self.root / 'helpers/comms.sh'), 'presence', 'with-beat',
                       '--no-heartbeat', '--name', 'timeout-probe',
                       '--instance', '00000000000000000000000000000001',
                       '--timeout-secs', '2', '--', *command]
        proc = subprocess.Popen(command, cwd=self.root,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, start_new_session=True)
        groups = set()
        pids = []
        dispatcher_pid = None
        owner_pid = None
        try:
            for name in ('descendant', 'worker', 'supervisor'):
                wait_file(self.root / ('.' + name + '-pid'))
            pids = [int((self.root / ('.' + name + '-pid')).read_text())
                    for name in ('supervisor', 'worker', 'descendant')]
            for pid in pids:
                groups.add(os.getpgid(pid))
            children = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,command='], text=True)
            rows = [line.split(None, 2) for line in children.splitlines()]
            parents = dict((int(pid), int(parent)) for pid, parent in
                           (row[:2] for row in rows))
            owner_pid = parents[pids[0]]
            groups.add(os.getpgid(owner_pid))
            run_pid = proc.pid
            if sig == 'timeout':
                # with-beat also owns a transient deadline sleep. Select the suite
                # invocation, which has its own job-control process group.
                run_pid, = [int(row[0]) for row in rows if len(row) == 3
                            and int(row[1]) == proc.pid and row[2] == 'bash tests/run.sh']
            run_pgid = os.getpgid(run_pid)
            groups.add(run_pgid)
            dispatcher_pid, = [pid for pid, parent in parents.items() if parent == run_pid]
            self.assertEqual(os.getpgid(dispatcher_pid), run_pgid)
            if owner_pid != dispatcher_pid:
                self.assertNotEqual(os.getpgid(owner_pid), run_pgid)
            if pending_signals or sig == signal.SIGINT:
                os.kill(dispatcher_pid, signal.SIGSTOP)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    state = subprocess.check_output(
                        ['ps', '-p', str(dispatcher_pid), '-o', 'stat='], text=True).strip()
                    if state.startswith('T'):
                        break
                    time.sleep(0.02)
                self.assertTrue(state.startswith('T'), 'dispatcher never stopped')
                if pending_signals:
                    for pending in pending_signals:
                        os.kill(dispatcher_pid, pending)
                else:
                    # INT reaches run.sh too; its EXIT trap then queues TERM.
                    os.killpg(run_pgid, signal.SIGINT)
                    time.sleep(0.5)
                os.kill(dispatcher_pid, signal.SIGCONT)
            elif sig != 'timeout':
                os.killpg(run_pgid, sig)
            out, err = proc.communicate(timeout=20)
            if sig == signal.SIGKILL:
                self.assertEqual(proc.returncode, -sig, out + err)
            elif sig == 'timeout':
                self.assertEqual(proc.returncode, 124, out + err)
            else:
                self.assertIn(proc.returncode, (130, 143), out + err)
            self.assertNotIn('ATTESTATION: recorded', out)
            self.assertNotIn('passed:', out)
            # Group KILL returns before the independent owner's five-second
            # grace starts. Allow that grace plus the session sweep to finish.
            assert_stopped(self, owner_pid, timeout=15)
            for pid in [dispatcher_pid, *pids]:
                assert_stopped(self, pid)
            self.assertEqual((self.root / '.worker-cleanup').read_text().splitlines(), ['cleanup'])
            if sig not in (signal.SIGKILL, 'timeout'):
                self.assertEqual((self.root / '.dispatch-cleanup').read_text().splitlines(), ['cleanup'])
        finally:
            # The negative control deliberately leaks. Remove all fixture groups,
            # including the worker's separate job-control group, even on failure.
            # Recover workers even if readiness or process discovery failed early.
            for name in ('supervisor', 'worker', 'descendant'):
                marker = self.root / ('.' + name + '-pid')
                if marker.exists() and marker.read_text().strip():
                    pid = int(marker.read_text())
                    if pid not in pids:
                        pids.append(pid)
                    try:
                        groups.add(os.getpgid(pid))
                    except ProcessLookupError:
                        pass
            # An unreaped launcher still pins its session identity. Sweep its
            # separate run.sh group too, including when discovery failed above.
            if proc.returncode is None:
                dispatch.kill_worker_session(proc)
            for group in groups:
                try:
                    os.killpg(group, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
            proc.communicate(timeout=20)
            # Only the launcher is our child to reap; orphaned descendants are
            # adopted by the system reaper. Wait for known non-children to stop.
            for pid in [owner_pid, dispatcher_pid, *pids]:
                if pid is not None:
                    assert_stopped(self, pid, timeout=15)

    def test_killing_run_sh_stops_all_worker_session_members(self):
        shutil.copyfile(Path(__file__).parents[1] / 'helpers/comms.sh',
                        self.root / 'helpers/comms.sh')
        (self.root / 'tests/worker.sh').write_text('''#!/bin/bash
set -m
bash -c 'trap "" INT TERM; echo $$ > .descendant-pid; exec sleep 60' &
echo $$ > .worker-pid
echo "$PPID" > .supervisor-pid
owner="$(ps -p "$PPID" -o ppid=)"
echo "$owner" > .owner-pid
ps -p "$owner" -o ppid= > .dispatcher-pid
wait
''')
        # Target only run.sh, never the launcher's group: workers live in their
        # own sessions, including a descendant in a separate job-control group.
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGKILL):
            with self.subTest(signal=sig):
                for name in ('worker', 'descendant', 'supervisor', 'dispatcher', 'owner'):
                    (self.root / ('.' + name + '-pid')).unlink(missing_ok=True)
                proc = subprocess.Popen(['bash', 'tests/run.sh'], cwd=self.root,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        text=True, start_new_session=True)
                try:
                    for name in ('descendant', 'dispatcher'):
                        wait_file(self.root / ('.' + name + '-pid'))
                    supervisor = int((self.root / '.supervisor-pid').read_text())
                    dispatcher_pid = int((self.root / '.dispatcher-pid').read_text())
                    os.kill(proc.pid, sig)
                    out, err = proc.communicate(timeout=25)
                    self.assertEqual(proc.returncode,
                                     -sig if sig == signal.SIGKILL else 128 + sig, out + err)
                    self.assertNotIn('worker cleanup failed', err)
                    self.assertNotIn('ATTESTATION: recorded', out)
                    for pid in (supervisor, dispatcher_pid, int((self.root / '.owner-pid').read_text()),
                                int((self.root / '.worker-pid').read_text()),
                                int((self.root / '.descendant-pid').read_text())):
                        assert_stopped(self, pid)
                finally:
                    # On failure, signal the still-owned dispatcher to perform its
                    # session sweep rather than leaving test-created orphans.
                    marker = self.root / '.dispatcher-pid'
                    if marker.exists() and marker.read_text().strip():
                        try:
                            os.kill(int(marker.read_text()), signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                    if proc.poll() is None:
                        proc.kill()
                    proc.communicate(timeout=25)

    def test_leftover_orphan_cannot_reduce_later_run_coverage(self):
        # Model identity-keyed supervisor state with a live leftover wrapper.
        # A repeated instance takes the collision path and silently omits work.
        helper = self.root / 'helpers/comms.sh'
        helper.write_text('''#!/bin/bash
if [ "$1" = attest-green ]; then touch .attested; exit 0; fi
name=""; instance=""
while [ "$1" != -- ]; do
  case "$1" in
    --name) shift; name="$1" ;;
    --instance) shift; instance="$1" ;;
  esac
  shift
done
shift
mkdir -p .leases
lease=".leases/$name-$instance"
mkdir "$lease" 2>/dev/null || exit 0
printf '%s %s\\n' "$name" "$instance" >> .instances
trap 'rm -rf "$lease"' EXIT
"$@"
''')
        legacy = '00000000000000000000000000000001'
        orphan = subprocess.Popen([str(helper), 'presence', 'with-beat', '--no-heartbeat',
                                   '--name', 'suite-sample', '--instance', legacy, '--',
                                   'bash', '-c', 'echo ready > .orphan-ready; exec sleep 60'],
                                  cwd=self.root, start_new_session=True,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            wait_file(self.root / '.orphan-ready')
            for _ in range(2):
                run = self.run_suite('--group', 'presence', '--group', 'sample')
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                self.assertIn('FOCUSED: passed=2 failed=0 skipped=0', run.stdout)
                self.assertIsNone(orphan.poll(), 'probe orphan must remain live during later runs')
            identities = (self.root / '.instances').read_text().splitlines()
            self.assertEqual(len(identities), 5)
            tokens = [row.split()[1] for row in identities]
            self.assertEqual(len(set(tokens)), 5, 'runs and workers must have distinct instances')
            for token in tokens:
                self.assertRegex(token, r'^[0-9a-f]{32}$')
            self.assertFalse((self.root / '.attested').exists())
        finally:
            os.killpg(orphan.pid, signal.SIGKILL)
            orphan.wait(timeout=5)


class WorkerLifecycle(unittest.TestCase):
    def test_owner_wait_timeout_preserves_cancellation_and_joins_other_owners(self):
        for sig in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=sig), tempfile.TemporaryDirectory() as temp:
                first, second = Mock(pid=101), Mock(pid=102)
                cancellation = KeyboardInterrupt(sig)
                first.poll.side_effect = cancellation
                first.wait.side_effect = subprocess.TimeoutExpired('owner', 15)
                second.wait.return_value = 0
                with patch.object(dispatch.subprocess, 'Popen', side_effect=[first, second]), \
                        patch('sys.stderr', new_callable=io.StringIO) as err:
                    with self.assertRaises(KeyboardInterrupt) as raised:
                        dispatch.run_workers(Path(temp), 'probe', Path(temp),
                                             [('first', 'parallel'), ('second', 'parallel')], 2)
                self.assertIs(raised.exception, cancellation)
                first.wait.assert_called_once_with(timeout=15)
                second.wait.assert_called_once_with(timeout=15)
                self.assertIn('owner cleanup timed out for 101', err.getvalue())

    def test_pending_signal_orders_enter_cleanup_once(self):
        # Real pending POSIX signals, with spawning/session inspection replaced
        # only here so this isolates the Python handler/unwind race itself.
        for first, second in ((signal.SIGINT, signal.SIGTERM), (signal.SIGTERM, signal.SIGINT)):
            with self.subTest(order=(first, second)), tempfile.TemporaryDirectory() as temp:
                script = '''
import importlib.util, os, signal, sys
from pathlib import Path
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('dispatch', sys.argv[1])
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)
for sig in (signal.SIGINT, signal.SIGTERM):
    signal.signal(sig, d.interrupted)
def launch(*args, **kwargs):
    os.kill(os.getpid(), int(sys.argv[3]))
    os.kill(os.getpid(), int(sys.argv[4]))
    return object()
calls = []
def cleanup(active):
    calls.append(len(active))
    assert all(signal.getsignal(sig) == signal.SIG_IGN for sig in (signal.SIGINT, signal.SIGTERM))
    for _, _, _, fd in active.values(): os.close(fd)
with patch.object(d.subprocess, 'Popen', launch), patch.object(d, 'stop_owners', cleanup):
    try:
        d.run_workers(Path(sys.argv[2]), 'probe', Path(sys.argv[2]), [('presence', 'serial')], 1)
    except KeyboardInterrupt:
        pass
assert calls == [1], calls
print('cleanup exactly once')
'''
                run = subprocess.run([sys.executable, '-B', '-c', script,
                                      str(Path(dispatch.__file__).resolve()), temp,
                                      str(first), str(second)], capture_output=True, text=True, timeout=10)
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                self.assertEqual(run.stdout.strip(), 'cleanup exactly once')

    def test_inspection_failure_is_not_proof_of_process_exit(self):
        for rc, error in ((1, 'ps: Operation not permitted'), (0, '')):
            with self.subTest(status=rc):
                failed = subprocess.CompletedProcess(['ps'], rc, '', error)
                with patch.object(subprocess, 'run', return_value=failed):
                    with self.assertRaises(AssertionError):
                        assert_stopped(self, 12345)

    def test_signal_between_spawn_and_registration_leaves_no_worker(self):
        real_popen = subprocess.Popen
        for sig in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=sig), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                (root / 'helpers').mkdir(); (root / 'tests').mkdir()
                helper = root / 'helpers/comms.sh'
                helper.write_text('#!/bin/bash\nwhile [ "$1" != -- ]; do shift; done\nshift\nexec "$@"\n')
                helper.chmod(0o755)
                (root / 'tests/worker.sh').write_text('#!/bin/bash\nsleep 60\n')
                spawned = []

                def interrupted(signum, _frame):
                    raise KeyboardInterrupt(signum)

                def launch(*args, **kwargs):
                    proc = real_popen(*args, **kwargs)
                    spawned.append(proc)
                    os.kill(os.getpid(), sig)
                    return proc

                old_handler = signal.signal(sig, interrupted)
                try:
                    with patch.object(dispatch.subprocess, 'Popen', launch):
                        with self.assertRaises(KeyboardInterrupt):
                            dispatch.run_workers(root, 'probe', root, [('presence', 'serial')], 1)
                    self.assertIsNotNone(spawned[0].poll(), 'unregistered worker survived')
                    self.assertFalse((root / 'counts').exists())
                finally:
                    signal.signal(sig, old_handler)
                    for proc in spawned:
                        if proc.poll() is None:
                            os.killpg(proc.pid, signal.SIGKILL)
                            proc.wait(timeout=5)

    def test_forced_cleanup_reaches_separate_child_group_only_in_owned_session(self):
        with tempfile.TemporaryDirectory() as temp:
            marker = Path(temp) / 'child'
            proc = subprocess.Popen(['bash', '-c', '''
trap '' TERM
set -m
bash -c 'trap "" TERM; echo $$ > "$1"; exec sleep 60' bash "$1" &
wait
''', 'bash', str(marker)], start_new_session=True,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            unrelated = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'],
                                         start_new_session=True)
            try:
                wait_file(marker)
                child = int(marker.read_text())
                self.assertNotEqual(os.getpgid(child), proc.pid)
                self.assertEqual(os.getsid(child), proc.pid)
                dispatch.stop_workers({'probe': (proc, None, time.monotonic())},
                                      signal.SIGTERM, grace=0.05)
                self.assertIsNotNone(proc.poll())
                assert_stopped(self, child)
                self.assertIsNone(unrelated.poll(), 'cleanup touched an unrelated session')
            finally:
                if proc.poll() is None:
                    dispatch.kill_worker_session(proc)
                    proc.wait(timeout=5)
                unrelated.kill(); unrelated.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
