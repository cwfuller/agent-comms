"""Adversarial checks of the actual coordinator report reader and scheduling."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

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


if __name__ == '__main__':
    unittest.main()
