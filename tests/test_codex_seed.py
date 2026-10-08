#!/usr/bin/env python3
"""helpers/codex_seed.py: seeding a fresh codex home by clone, and refreshing the canonical tree.

The production clone is clonefile(2) and exists only on APFS-like volumes, so every case but one runs against a
test double that makes a true copy with NEW inodes (what clonefile also does). The one real-clone case is skipped
where the volume cannot clone, and the report marks it so the umbrella suite can cash a named skip for it."""
import ast
import errno
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'helpers'))
import codex_seed as cs

REAL_CLONE = cs._clonefile

KEY = 'codex-0.160.1'
NOW = 1_800_000_000


def double_clone(src, dst, *_a):
    shutil.copytree(src, dst, symlinks=True, copy_function=shutil.copy2)


class Case(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / 'codex-seed'
        self.src = self.base / 'src-home'
        self.write(self.src / 'plugins/cache/openai-curated-remote/figma/plugin.json', '{"id":"figma"}\n')
        self.write(self.src / 'plugins/cache/openai-curated-remote/figma/.codex-remote-plugin-install.json', '{"p":"figma"}\n')
        self.write(self.src / 'plugins/cache/tools/a/b/c.txt', 'c\n')
        self.write(self.src / 'cache/remote_plugin_catalog/id.json', '{"rows":[1,2,3]}\n')   # codex's catalog: present, never staged
        self.home = self.base / 'home'
        self.home.mkdir()
        patcher = patch.object(cs, '_clonefile', double_clone)
        patcher.start()
        self.addCleanup(patcher.stop)

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def promote(self, key=KEY, now=NOW):
        line, rc = cs.promote(str(self.root), key, str(self.src), now=now)
        self.assertEqual((line.split()[0], rc), ('promoted', 0), line)
        return line

    def seed(self, key=KEY, now=NOW + 60, home=None):
        return cs.seed(str(self.root), key, str(home or self.home), now=now)

    def ids(self, top):
        return {(e[5], e[6]) for e in cs.walk(str(top), 'x')}

    def untouched(self):
        return sorted(p.name for p in self.home.iterdir()) == []

    def leftovers(self):
        return sorted(n for n in os.listdir(self.root) if n.startswith('.'))


class SeedFresh(Case):
    def test_seeds_the_plugin_cache_with_new_inodes_and_no_links(self):
        self.promote()
        line, rc = self.seed()
        self.assertEqual((line.split()[0], rc), ('seeded', 0), line)
        canon = self.root / KEY / 'plugins-cache'
        got = cs.walk(str(self.home / 'plugins/cache'), 'plugins-cache')
        self.assertEqual(cs.lines(got), cs.lines(cs.walk(str(canon), 'plugins-cache')))
        self.assertFalse(self.ids(self.home / 'plugins/cache') & self.ids(canon))
        self.assertTrue(all(e[1] == 'd' or os.lstat(self.home / 'plugins/cache' / e[0].split('/', 1)[1]).st_nlink == 1 for e in got if '/' in e[0]))
        self.assertFalse(any(os.path.islink(os.path.join(d, n)) for d, ds, fs in os.walk(self.home) for n in ds + fs))
        self.assertEqual(sorted(os.listdir(self.home)), ['plugins'], 'the catalog and every other path is left to codex')

    def test_no_canonical_leaves_the_home_untouched(self):
        self.assertEqual(self.seed(), ('skipped:no-seed', 0))
        self.assertTrue(self.untouched())
        self.assertFalse(self.root.exists(), 'seed must not create the store')

    def test_a_canonical_for_another_version_is_not_used(self):
        self.promote('codex-0.159.0')
        self.assertEqual(self.seed(), ('skipped:no-seed', 0))
        self.assertTrue(self.untouched())

    def test_an_old_canonical_is_not_used(self):
        self.promote()
        self.assertEqual(self.seed(now=NOW + cs.MAX_AGE_SECS + 1), ('skipped:stale', 0))
        self.assertTrue(self.untouched())

    def test_a_canonical_dated_in_the_future_is_refused(self):
        self.promote(now=NOW + 10 * 3600)
        self.assertEqual(self.seed(), ('skipped:canonical-tampered', 0))

    def test_a_planted_symlink_in_the_canonical_is_refused_and_left_in_place(self):
        self.promote()
        os.symlink('/etc/hosts', self.root / KEY / 'plugins-cache/planted')
        self.assertEqual(self.seed(), ('skipped:symlink', 0))
        self.assertTrue(self.untouched())
        self.assertTrue((self.root / KEY / 'MANIFEST').exists())

    def test_a_tampered_file_in_the_canonical_is_refused(self):
        self.promote()
        (self.root / KEY / 'plugins-cache/tools/a/b/c.txt').write_text('changed\n')
        self.assertEqual(self.seed(), ('skipped:canonical-tampered', 0))
        self.assertTrue(self.untouched())

    def test_a_file_added_to_the_canonical_is_refused(self):
        self.promote()
        self.write(self.root / KEY / 'plugins-cache/extra.txt', 'x\n')
        self.assertEqual(self.seed(), ('skipped:canonical-tampered', 0))

    def test_a_hard_link_in_the_canonical_is_refused(self):
        self.promote()
        os.link(self.root / KEY / 'plugins-cache/tools/a/b/c.txt', self.base / 'outside-link')
        self.assertEqual(self.seed(), ('skipped:link-or-special', 0))
        self.assertTrue(self.untouched())

    def test_a_warm_home_is_never_reseeded(self):
        self.promote()
        (self.home / 'plugins').mkdir()
        self.assertEqual(self.seed(), ('skipped:warm', 0))
        self.assertEqual(os.listdir(self.home / 'plugins'), [])

    def test_a_symlinked_cache_counts_as_warm(self):
        self.promote()
        os.symlink(self.base, self.home / 'cache')
        self.assertEqual(self.seed(), ('skipped:warm', 0))
        self.assertFalse((self.home / 'plugins').exists())

    def test_an_unusable_key_seeds_nothing(self):
        self.promote()
        for key in ('codex-unknown', 'codex-', '0.160.1', 'codex-0.160.1/../x', 'codex-0.160.1\n'):
            self.assertEqual(self.seed(key), ('skipped:no-key', 0), key)
        self.assertTrue(self.untouched())

    def test_a_symlinked_or_loose_store_is_refused(self):
        self.promote()
        loose = self.base / 'loose'
        os.rename(self.root, loose)
        os.symlink(loose, self.root)
        self.assertEqual(self.seed(), ('skipped:bad-root', 0))
        os.unlink(self.root)
        os.rename(loose, self.root)
        os.chmod(self.root, 0o755)
        self.assertEqual(self.seed(), ('skipped:bad-root', 0))
        self.assertTrue(self.untouched())


class SeedFailsClosed(Case):
    def test_a_failed_clone_never_becomes_a_copy(self):
        self.promote()
        calls = []

        def refuse(src, dst, *_a):
            calls.append(dst)
            raise OSError(errno.EXDEV, 'cross-device')
        with patch.object(cs, '_clonefile', refuse), patch.object(shutil, 'copytree') as tree, \
                patch.object(shutil, 'copy2') as c2, patch.object(shutil, 'copyfile') as cf:
            self.assertEqual(self.seed(), ('skipped:clone-failed:EXDEV', 0))
        self.assertTrue(calls)
        self.assertFalse(tree.called or c2.called or cf.called)
        self.assertTrue(self.untouched(), 'the parents seed created must be removed again')

    def test_a_missing_clonefile_symbol_is_a_failed_clone(self):
        self.promote()
        with patch.object(cs, '_clonefile', REAL_CLONE), patch.object(cs.ctypes, 'CDLL', return_value=object()):
            self.assertEqual(self.seed(), ('skipped:clone-failed:ENOSYS', 0))
        self.assertTrue(self.untouched())

    def test_a_clone_that_differs_from_the_canonical_is_removed(self):
        self.promote()

        def drift(src, dst, *_a):
            double_clone(src, dst)
            if dst.endswith('plugins/cache'):
                (Path(dst) / 'tools/a/b/c.txt').write_text('drifted\n')
        with patch.object(cs, '_clonefile', drift):
            line, rc = self.seed()
        self.assertEqual((line.split()[0], rc), ('skipped:clone-unverified', 0), line)
        self.assertTrue(self.untouched())

    def test_a_clone_holding_a_symlink_is_removed(self):
        self.promote()

        def planted(src, dst, *_a):
            double_clone(src, dst)
            os.symlink('/etc/hosts', Path(dst) / 'link')
        with patch.object(cs, '_clonefile', planted):
            line, rc = self.seed()
        self.assertEqual((line.split()[0], rc), ('skipped:clone-unverified', 0), line)
        self.assertTrue(self.untouched())

    def test_a_clone_that_hard_links_to_the_canonical_is_removed(self):
        self.promote()

        def linked(src, dst, *_a):
            shutil.copytree(src, dst, symlinks=True, copy_function=os.link)
        with patch.object(cs, '_clonefile', linked):
            line, rc = self.seed()
        self.assertEqual((line.split()[0], rc), ('skipped:clone-unverified', 0), line)
        self.assertTrue(self.untouched())

    def test_a_clone_that_cannot_be_removed_refuses_the_turn(self):
        self.promote()

        def drift(src, dst, *_a):
            double_clone(src, dst)
            (Path(dst) / 'tools/a/b/c.txt').write_text('drifted\n')
        with patch.object(cs, '_clonefile', drift), patch.object(shutil, 'rmtree', side_effect=PermissionError(errno.EACCES, 'denied')):
            line, rc = self.seed()
        self.assertEqual(rc, 2, line)
        self.assertTrue(line.startswith('cleanup-failed'))


class Promote(Case):
    def test_publishes_a_manifested_canonical_with_no_leftovers(self):
        line = self.promote()
        canon = self.root / KEY
        self.assertEqual(stat.S_IMODE(os.lstat(self.root).st_mode), 0o700)
        hdr, body = cs.read_manifest(str(canon / 'MANIFEST'))
        self.assertEqual((hdr['version'], hdr['created']), (KEY, str(NOW)))
        self.assertEqual(hdr['digest'], cs.digest(body))
        self.assertIn('digest=' + hdr['digest'][:12], line)
        self.assertEqual(self.leftovers(), [])
        self.assertFalse(self.ids(canon / 'plugins-cache') & self.ids(self.src / 'plugins/cache'))

    def test_replaces_a_stale_canonical_in_one_step(self):
        self.promote(now=NOW - 20 * 24 * 3600)
        self.write(self.src / 'plugins/cache/tools/new.txt', 'new\n')
        self.promote(now=NOW)
        self.assertTrue((self.root / KEY / 'plugins-cache/tools/new.txt').is_file())
        self.assertEqual(cs.read_manifest(str(self.root / KEY / 'MANIFEST'))[0]['created'], str(NOW))
        self.assertEqual(self.leftovers(), [])

    def test_a_home_with_nothing_to_promote_creates_nothing(self):
        line, rc = cs.promote(str(self.root), KEY, str(self.home), now=NOW)
        self.assertEqual((line.split()[0], rc), ('skipped:incomplete-home', 0))
        self.assertFalse(self.root.exists())
        shutil.rmtree(self.src / 'plugins/cache')
        (self.src / 'plugins/cache').mkdir()
        self.assertEqual(cs.promote(str(self.root), KEY, str(self.src), now=NOW)[0].split()[0], 'skipped:incomplete-home')
        self.assertFalse(self.root.exists())

    def test_the_catalog_is_never_promoted(self):
        self.promote()
        self.assertEqual(sorted(os.listdir(self.root / KEY)), ['MANIFEST', 'plugins-cache'])
        self.assertNotIn('remote_plugin_catalog', (self.root / KEY / 'MANIFEST').read_text())

    def test_a_symlink_in_the_home_is_not_promoted(self):
        os.symlink('/etc/hosts', self.src / 'plugins/cache/tools/link')
        self.assertEqual(cs.promote(str(self.root), KEY, str(self.src), now=NOW)[0], 'skipped:symlink')
        self.assertFalse(self.root.exists())

    def test_a_failed_clone_leaves_the_previous_canonical_and_no_temp(self):
        self.promote()
        with patch.object(cs, '_clonefile', side_effect=OSError(errno.EPERM, 'x')):
            line, rc = cs.promote(str(self.root), KEY, str(self.src), now=NOW + 5)
        self.assertEqual((line, rc), ('skipped:clone-failed:EPERM', 0))
        self.assertEqual(cs.read_manifest(str(self.root / KEY / 'MANIFEST'))[0]['created'], str(NOW))
        self.assertEqual(self.leftovers(), [])

    def test_a_promote_of_a_home_on_another_volume_is_refused(self):
        real = os.lstat

        def other_dev(path, *a, **k):
            st = real(path, *a, **k)
            if str(path) == str(self.src):
                return os.stat_result((st.st_mode, st.st_ino, st.st_dev + 1) + tuple(st)[3:])
            return st
        with patch.object(cs.os, 'lstat', other_dev):
            self.assertEqual(cs.promote(str(self.root), KEY, str(self.src), now=NOW)[0], 'skipped:other-volume')

    def test_two_racing_promotes_leave_one_complete_canonical(self):
        self.root.mkdir(mode=0o700)
        pids = []
        for _ in range(2):
            pid = os.fork()
            if pid == 0:
                code = 1
                try:
                    line, rc = cs.promote(str(self.root), KEY, str(self.src), now=NOW)
                    code = 0 if rc == 0 and line.split()[0] in ('promoted', 'skipped:lost-race') else 1
                finally:
                    os._exit(code)
            pids.append(pid)
        self.assertEqual([os.waitpid(p, 0)[1] for p in pids], [0, 0])
        hdr, body = cs.read_manifest(str(self.root / KEY / 'MANIFEST'))
        walked = cs.walk(str(self.root / KEY / 'plugins-cache'), 'plugins-cache')
        self.assertEqual(cs.lines(walked), body)
        self.assertEqual(self.leftovers(), [])
        self.assertEqual(self.seed()[0].split()[0], 'seeded')

    def test_an_old_canonical_of_another_version_is_pruned_and_a_young_one_kept(self):
        self.promote('codex-0.150.0', now=NOW - 30 * 24 * 3600)
        self.promote('codex-0.159.0', now=NOW - 2 * 24 * 3600)
        self.promote(KEY, now=NOW)
        self.assertEqual(sorted(n for n in os.listdir(self.root)), ['codex-0.159.0', KEY])

    def test_a_dead_callers_temp_directory_is_reaped_and_a_live_one_kept(self):
        self.promote()
        dead = subprocess.Popen([sys.executable, '-c', 'pass'])
        dead.wait()
        (self.root / ('.tmp.%d.aa' % dead.pid)).mkdir()
        (self.root / ('.tmp.%d.bb' % os.getpid())).mkdir()
        self.promote(now=NOW + 1)
        self.assertEqual(self.leftovers(), ['.tmp.%d.bb' % os.getpid()])


class Entrypoint(Case):
    def run_cli(self, *args):
        p = subprocess.run([sys.executable, '-I', str(REPO / 'helpers/codex_seed.py'), *args], capture_output=True, text=True)
        return p.returncode, p.stdout.strip()

    def test_the_cli_reports_a_skip_with_exit_zero_and_usage_errors_with_one(self):
        self.assertEqual(self.run_cli('seed', '--root', str(self.root), '--key', KEY, '--home', str(self.home)), (0, 'skipped:no-seed'))
        self.assertEqual(self.run_cli('seed', '--root', str(self.root))[0], 1)
        self.assertEqual(self.run_cli('frob', '--root', 'a', '--key', 'b', '--home', 'c')[0], 1)
        self.assertEqual(self.run_cli('seed', '--root', 'a', '--key', 'b', '--home', 'c', '--wait-secs', '5')[0], 1)
        self.assertEqual(self.run_cli('promote', '--root', 'a', '--key', 'b', '--home', 'c', '--wait-secs', '601')[0], 1)

    def test_no_byte_copy_link_process_or_environment_use_exists_in_the_helper(self):
        tree = ast.parse((REPO / 'helpers/codex_seed.py').read_text())
        attrs = {}
        for node in ast.walk(tree):
            if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name):
                attrs.setdefault(node.value.id, set()).add(node.attr)
        self.assertEqual(attrs['shutil'], {'rmtree'})
        self.assertFalse(attrs['os'] & {'link', 'symlink', 'system', 'popen', 'environ', 'getenv', 'sendfile', 'copy_file_range'}, attrs['os'])
        imported = {a.name for n in ast.walk(tree) if isinstance(n, ast.Import) for a in n.names}
        self.assertFalse(imported & {'subprocess', 'distutils', 'pty', 'multiprocessing'}, imported)


class RealClone(unittest.TestCase):
    def test_a_real_clonefile_seeds_with_new_inodes_and_shared_content(self):
        with tempfile.TemporaryDirectory() as t:
            base = Path(t).resolve()
            probe = base / 'probe'
            probe.write_text('x')
            try:
                REAL_CLONE(str(probe), str(base / 'probe2'))
            except OSError as e:
                self.skipTest('this volume cannot clone: %s' % e)
            src, home = base / 'src', base / 'home'
            (src / 'plugins/cache/p').mkdir(parents=True)
            (src / 'plugins/cache/p/f.json').write_text('{"a":1}\n')
            (src / 'cache/remote_plugin_catalog').mkdir(parents=True)
            (src / 'cache/remote_plugin_catalog/c.json').write_text('{"b":2}\n')
            home.mkdir()
            root = base / 'codex-seed'
            self.assertEqual(cs.promote(str(root), KEY, str(src), now=NOW)[0].split()[0], 'promoted')
            line, rc = cs.seed(str(root), KEY, str(home), now=NOW + 1)
            self.assertEqual((line.split()[0], rc), ('seeded', 0), line)
            canon_ids = {(e[5], e[6]) for e in cs.walk(str(root / KEY / 'plugins-cache'), 'p')}
            home_walk = cs.walk(str(home / 'plugins/cache'), 'p')
            self.assertFalse(canon_ids & {(e[5], e[6]) for e in home_walk})
            self.assertFalse(stat.S_ISLNK(os.lstat(home / 'plugins/cache/p/f.json').st_mode))
            self.assertEqual((home / 'plugins/cache/p/f.json').read_text(), '{"a":1}\n')


class Result(unittest.TextTestResult):
    """One report row per executed case so the umbrella coverage gate counts them; a skipped case is marked."""
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.cases = []
        self.state = 'fail'

    def startTest(self, test):
        self.state = 'fail'
        super().startTest(test)

    def addSuccess(self, test):
        self.state = 'pass'
        super().addSuccess(test)

    def addSkip(self, test, reason):
        self.state = 'skip'
        super().addSkip(test, reason)

    def stopTest(self, test):
        self.cases.append({'name': test.id(), 'passed': self.state == 'pass', 'skipped': self.state == 'skip'})
        super().stopTest(test)


if __name__ == '__main__':
    report = None
    if '--report' in sys.argv:
        index = sys.argv.index('--report')
        report = Path(sys.argv[index + 1])
        del sys.argv[index:index + 2]
    program = unittest.main(exit=False, testRunner=unittest.TextTestRunner(resultclass=Result))
    if report:
        report.write_text(json.dumps(program.result.cases))
    sys.exit(0 if program.result.wasSuccessful() else 1)
