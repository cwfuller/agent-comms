"""Adversarial checks of the actual coordinator report reader and scheduling."""
import importlib.util
from pathlib import Path
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


if __name__ == '__main__':
    unittest.main()
