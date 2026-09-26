#!/usr/bin/env python3
"""Profile contract tests. No network, credentials, or installed model runtime required."""
import copy
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'helpers'))
import agent_profiles as profiles
import opencode_adapter as adapter
from profile_io import private_directory, place


def profile(**changes):
    return dict(adapter='acp', command=[sys.executable, '-u', 'server.py'],
                family='example', model='vendor/model-v1', **changes)


def opencode():
    result = profile()
    result.update(adapter='opencode', command=[sys.executable], runtime_version=adapter.VERSION)
    return result


class Profiles(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.env = patch.dict(os.environ, {'AGENT_COMMS_HOME': str(self.root)})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.config = self.root / 'agents.json'

    def write(self, agents):
        self.config.write_text(json.dumps({'version': 1, 'agents': agents}))

    def binding(self):
        self.write({'alpha': profile()})
        return profiles.resolve('alpha')

    def test_absent_profiles_preserves_defaults(self):
        self.assertEqual(profiles.load(), {})

    def test_profiles_are_strict(self):
        for bad in ['claude', 'codex', 'grok', 'alpha-review', '../evil', 'Aname', 'a b', '']:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                profiles.validate(bad, profile())
        for changes in [{'bogus': True}, {'adapter': 'unknown'}, {'command': 'shell command'},
                        {'command': ['./relative']}, {'family': 'two words'}, {'model': 'x\ny'},
                        {'credentials': {'PATH': {'env': 'SECRET'}}},
                        {'credentials': {'TOKEN': {'value': 'secret'}}}]:
            bad = profile(); bad.update(changes)
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                profiles.validate('alpha', bad)

    def test_duplicate_keys_and_writable_config_fail(self):
        self.config.write_text('{"version":1,"version":1,"agents":{}}')
        with self.assertRaises(ValueError): profiles.load()
        self.write({}); self.config.chmod(0o666)
        with self.assertRaises(ValueError): profiles.load()

    def test_broken_config_symlink_fails(self):
        self.config.symlink_to(self.root / 'missing')
        with self.assertRaises(ValueError): profiles.load()

    def test_missing_executable_fails(self):
        p = profile(); p['command'] = ['/no/such/agent/runtime']
        self.write({'alpha': p})
        with self.assertRaises(ValueError): profiles.resolve('alpha')

    def test_canonical_binding_and_model_namespace(self):
        binding = self.binding()
        self.assertEqual(profiles.decode(profiles.encode(binding)), binding)
        second = copy.deepcopy(binding); second['profile']['model'] = 'vendor/model-v2'
        self.assertNotEqual(profiles.digest(binding), profiles.digest(second))
        second = copy.deepcopy(binding); second['name'] = 'beta'
        self.assertNotEqual(profiles.digest(binding), profiles.digest(second))
        with self.assertRaises(ValueError): profiles.decode(profiles.encode(binding) + ' ')

    def test_launcher_change_invalidates_current_binding_not_history(self):
        binding = self.binding()
        with patch.object(profiles, 'launcher_revision', return_value='0' * 64):
            changed = profiles.resolve('alpha')
            self.assertNotEqual(profiles.digest(binding), profiles.digest(changed))
            self.assertEqual(profiles.decode(profiles.encode(binding)), binding)
        binding['profile'] = opencode()
        binding['profile']['runtime_version'] = '0.0.1'
        self.assertEqual(profiles.decode(profiles.encode(binding)), binding)
        with self.assertRaises(ValueError): adapter.check_runtime_profile(binding['profile'])

    def test_command_arguments_are_not_shell_code(self):
        binding = self.binding()
        binding['profile']['command'].append('$(touch unsafe); `id`')
        self.assertEqual(profiles.decode(profiles.encode(binding)), binding)
        args = profiles.acpx_arguments(binding, str(self.root / 'state'), ['--format', 'json', 'agent-comms-custom', '-s', 'session', '--file', 'q.md'])
        self.assertEqual(args[-5:], ['prompt', '-s', 'session', '--file', 'q.md'])
        launch = shlex.split(args[args.index('--agent') + 1])
        self.assertEqual(profiles.decode(launch[-2]), binding)
        self.assertFalse((self.root / 'unsafe').exists())

    def test_session_and_mode_argv_translation(self):
        binding = self.binding()
        for suffix, tail in [(['sessions', 'show', 'one'], ['sessions', 'show', 'one']),
                             (['-s', 'one', 'set-mode', 'review'], ['set-mode', '-s', 'one', 'review'])]:
            args = profiles.acpx_arguments(binding, str(self.root / 'state'), ['agent-comms-custom', *suffix])
            self.assertEqual(args[-len(tail):], tail)
            self.assertIn('--no-fs', args); self.assertIn('--no-terminal', args)
            self.assertEqual(json.loads((self.root / 'state/mcp.json').read_text()), {'mcpServers': []})

    def test_credentials_resolve_only_at_launch(self):
        p = profile(credentials={'API_KEY': {'env': 'TEST_API_TOKEN'}})
        self.write({'alpha': p})
        binding = profiles.resolve('alpha')
        resolved = profiles.credentials(p, {'TEST_API_TOKEN': 'sensitive-value'})
        self.assertEqual(resolved['API_KEY'], 'sensitive-value')
        self.assertNotIn('sensitive-value', profiles.canonical(binding))
        with self.assertRaises(ValueError): profiles.credentials(p, {})

    def test_model_control_must_match(self):
        binding = self.binding()
        with self.assertRaises(ValueError): profiles.model_check(binding, {})
        with self.assertRaises(ValueError): profiles.model_check(binding, {'acpx': {'current_model_id': 'other'}})
        receipt = profiles.model_check(binding, {'acpx': {'current_model_id': 'vendor/model-v1'}})
        self.assertFalse(receipt['inference_attested'])
        with self.assertRaises(ValueError):
            profiles.model_check(binding, {'acpx': {'current_model_id': 'vendor/model-v1',
                'config_options': [{'id': 'model', 'currentValue': 'other'}]}})

        with self.assertRaises(ValueError):
            profiles.model_check(binding, {'acpx': {'current_model_id': 'other',
                'config_options': [{'id': 'model', 'currentValue': 'vendor/model-v1'}]}})

    def message(self, path, fields):
        path.write_text('---\n' + ''.join(f'{k}: {v}\n' for k, v in fields.items()) + '---\n\nbody\n')
        return path

    def test_historical_reply_and_metadata_forgery(self):
        binding = self.binding()
        fm = dict(agent_profile=profiles.encode(binding), agent_profile_digest=profiles.digest(binding),
                  review_family='example', review_model='vendor/model-v1')
        req = self.message(self.root / 'req.md', dict(fm, type='review-request', message_id='request-1'))
        reply = self.message(self.root / 'reply.md', dict(fm, type='review-feedback', **{'from': 'alpha', 'in-reply-to': 'request-1'}))
        self.config.unlink()
        self.assertEqual(profiles.message_binding(reply, req), binding)
        self.message(req, dict(fm, type='error', message_id='request-1'))
        self.assertEqual(profiles.message_binding(reply, req), binding)
        for key, value in [('review_family', 'other'), ('review_model', 'other'), ('agent_profile_digest', 'bad'), ('from', 'beta'), ('in-reply-to', 'other')]:
            fields = dict(fm, type='review-feedback', **{'from': 'alpha', 'in-reply-to': 'request-1'})
            fields[key] = value; self.message(reply, fields)
            with self.subTest(key=key), self.assertRaises(ValueError): profiles.message_binding(reply, req)

    def test_duplicate_frontmatter_fails(self):
        p = self.root / 'message.md'; p.write_text('---\nagent_profile: a\nagent_profile: b\n---\n')
        with self.assertRaises(ValueError): profiles.frontmatter(p)

    def test_private_state_refuses_symlinks(self):
        target = self.root / 'target'; target.mkdir()
        link = self.root / 'link'; link.symlink_to(target, target_is_directory=True)
        with self.assertRaises(ValueError): private_directory(link / 'new')
        self.assertFalse((target / 'new').exists())
        state = private_directory(self.root / 'state')
        place(state / 'value.json', {'a': 1})
        self.assertEqual((state / 'value.json').stat().st_mode & 0o777, 0o600)

    def test_opencode_version_and_connection(self):
        p = opencode(); profiles.validate('alpha', p)
        p['runtime_version'] = 'unknown'
        with self.assertRaises(ValueError): profiles.validate('alpha', p)
        p = opencode(); p['connection'] = dict(base_url='http://remote.example/v1', api_key_env='API_KEY', context=1000, output=100)
        with self.assertRaises(ValueError): profiles.validate('alpha', p)
        p['connection']['base_url'] = 'http://127.0.0.1:9999/v1'
        profiles.validate('alpha', p)

    def test_opencode_config_has_single_read_only_mode(self):
        cfg = adapter.config(opencode())
        self.assertEqual(cfg['permission'], {'*': 'deny', 'read': 'allow', 'glob': 'allow', 'grep': 'allow', 'external_directory': 'deny'})
        self.assertEqual(cfg['default_agent'], adapter.MODE)
        self.assertEqual(cfg['model'], cfg['small_model'])
        self.assertEqual(cfg['mcp'], {}); self.assertEqual(cfg['plugin'], [])
        self.assertTrue(all(cfg['agent'][n]['disable'] for n in ['build', 'plan', 'general', 'explore']))

    def test_opencode_refuses_escaping_symlinks_before_launch(self):
        root = self.root / 'tree'; root.mkdir()
        (root / 'file').write_text('safe')
        (root / 'internal').symlink_to('file')
        adapter.check_tree(root)
        (root / 'escape').symlink_to(self.root / 'outside')
        with self.assertRaises(ValueError): adapter.check_tree(root)
        (root / 'escape').unlink()
        (root / 'escape').symlink_to('loop')
        (root / 'loop').symlink_to('escape')
        with self.assertRaises(ValueError): adapter.check_tree(root)

    def test_opencode_model_and_mode_control(self):
        b = {'name': 'alpha', 'profile': opencode()}; wanted = b['profile']['model']
        state = {'current_model_id': wanted, 'available_models': [wanted], 'config_options': [
            {'id': 'mode', 'currentValue': adapter.MODE, 'options': [{'value': adapter.MODE}]}]}
        profiles.model_check(b, {'acpx': state})
        state['available_models'].append('other')
        with self.assertRaises(ValueError): profiles.model_check(b, {'acpx': state})

    def test_native_attestation_checks_only_new_records(self):
        p = opencode(); snapshot = self.root / 'snapshot.json'; sid = 'ses_test'
        old = {'id': 'old', 'role': 'assistant', 'modelID': 'old', 'providerID': 'vendor'}
        new = {'id': 'new', 'role': 'assistant', 'modelID': 'model-v1', 'providerID': 'vendor', 'sessionID': sid, 'agent': adapter.MODE}
        data = {'info': {'id': sid}, 'messages': [{'info': old}]}
        def result(*a, **kw): return subprocess.CompletedProcess([], 0, json.dumps(data), '')
        with patch.object(adapter, 'environment', return_value={}), patch.object(adapter.subprocess, 'run', side_effect=result):
            adapter.attest(p, self.root, {}, {'acpSessionId': sid}, snapshot, 'before')
            with self.assertRaises(ValueError): adapter.attest(p, self.root, {}, {'acpSessionId': sid}, snapshot, 'after')
            data['messages'].append({'info': new})
            self.assertEqual(adapter.attest(p, self.root, {}, {'acpSessionId': sid}, snapshot, 'after')['assistant_records'], 1)
            new['modelID'] = 'other'
            with self.assertRaises(ValueError): adapter.attest(p, self.root, {}, {'acpSessionId': sid}, snapshot, 'after')
            new['modelID'] = 'model-v1'; new['agent'] = 'build'
            with self.assertRaises(ValueError): adapter.attest(p, self.root, {}, {'acpSessionId': sid}, snapshot, 'after')


class ProfileIntegration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / 'project'; self.repo.mkdir()
        self.home = self.root / 'home'; self.home.mkdir()
        self.env = dict(os.environ, AGENT_COMMS_HOME=str(self.home), COMMS_SELF='codex', COMMS_DELIVERY='mailbox', COMMS_REVIEW_ROUTE='0', COMMS_ROUTE='0')
        for key in list(self.env):
            if key.startswith('GIT_') or key.startswith('COMMS_PRESENCE_'):
                self.env.pop(key)
        self.git('init', '-q', '-b', 'main')
        (self.repo / '.gitignore').write_text('.comms/\n')
        self.git('add', '.gitignore')
        self.git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'init')
        self.comms = self.repo / '.comms'; self.comms.mkdir()
        (self.comms / 'archive').mkdir()
        (self.comms / 'config').write_text('agents = codex alpha delta\ndefault-target = codex\n')
        p = profile(); q = profile(); q['family'] = 'different'
        self.configuration = {'version': 1, 'agents': {'alpha': p, 'delta': q}}
        self.write_config()
        self.ws = self.cli('workspace').stdout.strip()

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.repo, env=self.env, check=True, capture_output=True, text=True)

    def write_config(self):
        (self.home / 'agents.json').write_text(json.dumps(self.configuration))

    def cli(self, *args, success=True):
        result = subprocess.run([str(REPO / 'helpers/comms.sh'), *map(str,args)], cwd=self.repo, env=self.env, capture_output=True, text=True, timeout=90)
        if success: self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def request(self):
        p = self.comms / 'request.md'
        fields = dict(type='review-request', timestamp='2026-09-25T10:00:00Z', workspace=self.ws, message_id='profile-request', thread='profile-arc', workflow='auto', phase='implement', round=1, **{'from':'codex','max-rounds':4})
        self.write_message(p, fields)
        return p

    def write_message(self, path, fields):
        path.write_text('---\n' + ''.join(f'{k}: {v}\n' for k,v in fields.items()) + '---\n\n## Findings\n\n### Blocking\n- None.\n\n### Advisory\n- None.\n')

    def panel(self):
        self.cli('panel', 'dispatch', '--to', 'alpha,delta', '--set', 'profile-set', self.request())
        self.requests = {}
        self.replies = {}
        for name in ('alpha','delta'):
            req = next((self.comms / f'to-{name}').glob('*panel-*'))
            fm = profiles.frontmatter(req)
            self.assertIn('agent_profile', fm)
            self.set_id = fm['review_set']
            self.requests[name] = req
            rep = self.comms / 'archive' / f'{self.ws}_2026-09-25T11-00-00_{name}-reply.md'
            reply = dict(fm, type='review-feedback', verdict='APPROVE', message_id=name+'-answer', **{'from':name,'in-reply-to':fm['message_id']})
            self.write_message(rep, reply)
            self.replies[name] = rep
            self.cli('validate', rep)

    def test_send_history_compose_and_family_forgery(self):
        self.panel()
        self.cli('compose', '--set', self.set_id)
        # Live reclassification must not change the historical panel.
        self.configuration['agents']['delta']['family'] = 'example'; self.write_config()
        self.cli('compose', '--set', self.set_id)
        # Profile removal is also compatible with retained requests and replies.
        (self.home / 'agents.json').unlink()
        (self.comms / 'config').write_text('agents = codex\ndefault-target = codex\n')
        self.cli('compose', '--set', self.set_id)
        # A reply alone cannot rewrite family, even with a self-consistent digest.
        rep = self.replies['delta']; fields = profiles.frontmatter(rep)
        binding = profiles.decode(fields['agent_profile']); binding['profile']['family'] = 'example'
        fields.update(agent_profile=profiles.encode(binding), agent_profile_digest=profiles.digest(binding), review_family='example')
        self.write_message(rep, fields)
        self.assertNotEqual(self.cli('validate', rep, success=False).returncode, 0)
        # If both retained records say same family, composition must reject despite
        # different execution identities. This also covers imported historical records.
        req = self.requests['delta']; request = profiles.frontmatter(req)
        request.update({k: fields[k] for k in profiles.BINDING_FIELDS})
        self.write_message(req, request)
        self.cli('validate', rep)
        result = self.cli('compose', '--set', self.set_id, success=False)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('both answered on provider example', result.stdout + result.stderr)

    def test_panel_rejects_family_alias_before_dispatch(self):
        self.configuration['agents']['delta']['family'] = 'example'; self.write_config()
        result = self.cli('panel', 'dispatch', '--to', 'alpha,delta', self.request(), success=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.comms / 'grades/sets.tsv').exists())

    def test_changed_profile_cannot_resend_or_run(self):
        self.panel()
        self.configuration['agents']['alpha']['model'] = 'vendor/changed'; self.write_config()
        result = self.cli('send', '--to', 'alpha', self.requests['alpha'], success=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('profile changed', result.stdout + result.stderr)
        run = self.root / 'run'; run.mkdir()
        result = subprocess.run([str(REPO / 'helpers/runphase.sh'), 'run', '--message', str(self.requests['alpha']), '--dir', str(run), '--agent', 'alpha', '--via', 'acp', '--no-deliver'], cwd=self.repo, env=self.env, capture_output=True, text=True, timeout=45)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('changed since dispatch', result.stdout + result.stderr + ((run / 'runner.log').read_text() if (run / 'runner.log').exists() else ''))


class ProfileResult(unittest.TextTestResult):
    """One report row per executed case so the umbrella coverage gate counts them."""
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.cases = []

    def startTest(self, test):
        self.case_passed = False
        super().startTest(test)

    def addSuccess(self, test):
        self.case_passed = True
        super().addSuccess(test)

    def stopTest(self, test):
        self.cases.append({'name': test.id(), 'passed': self.case_passed})
        super().stopTest(test)


if __name__ == '__main__':
    report = None
    if '--report' in sys.argv:
        index = sys.argv.index('--report')
        report = Path(sys.argv[index + 1])
        del sys.argv[index:index + 2]
    program = unittest.main(exit=False, testRunner=unittest.TextTestRunner(resultclass=ProfileResult))
    if report:
        report.write_text(json.dumps(program.result.cases))
    sys.exit(0 if program.result.wasSuccessful() else 1)
