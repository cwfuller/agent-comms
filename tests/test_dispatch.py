"""Adversarial checks of the actual coordinator report reader and scheduling."""
import importlib.util
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

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
        # Use the production supervisor, including its separate child process group.
        shutil.copyfile(Path(__file__).parents[1] / 'helpers/comms.sh',
                        self.root / 'helpers/comms.sh')
        (self.root / 'tests/worker.sh').write_text('''#!/bin/bash
name="$1"; results="$3"
printf '%s\\t1\\n' "$name" > "$results/$name.sections"
: > "$results/$name.skips"
printf '1\\t0\\t0\\n%s\\ncomplete\\n' "$name" > "$results/$name.done"
sleep 60 &
echo $! > .descendant-pid
echo $$ > .worker-pid
# The worker's parent is with-beat, whose parent is the dispatcher.
ps -p "$PPID" -o ppid= > .dispatcher-pid
wait
''')
        proc = subprocess.Popen(['bash', 'tests/run.sh'], cwd=self.root,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                start_new_session=True)
        try:
            wait_file(self.root / '.dispatcher-pid')
            os.kill(int((self.root / '.dispatcher-pid').read_text()), signal.SIGINT)
            out, err = proc.communicate(timeout=20)
            self.assertEqual(proc.returncode, 130, out + err)
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


def assert_stopped(test, pid):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        state = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='],
                               capture_output=True, text=True).stdout.strip()
        if not state or state.startswith('Z'):
            return
        time.sleep(0.02)
    test.fail(f'worker process {pid} survived cancellation ({state})')


class WorkerLifecycle(unittest.TestCase):
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
