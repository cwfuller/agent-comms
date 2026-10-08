#!/usr/bin/env python3
"""Exact-per-leg-binding contract tests. No network, no credential, no installed model runtime required."""
import base64
import copy
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'helpers'))
import access_profiles as access
import agent_profiles as profiles
import leg_binding as binding

ACCESS = {
    'codex': dict(route_id='codex-subscription', transport='acp', provider='openai', account='primary', billing='subscription', credential=None),
    'gemini': dict(route_id='gemini-api', transport='acp', provider='google', account='metered', billing='api', credential='env:CFG_GEMINI_KEY'),
    'glm': dict(route_id='venice-api', transport='acp', provider='venice', account='primary', billing='api', credential='env:CFG_VENICE_KEY'),
    'other': dict(route_id='venice-other', transport='acp', provider='venice', account='other', billing='api', credential='env:CFG_OTHER_KEY'),
}


def opencode(command, model, family, env):
    return dict(adapter='opencode', command=[command], runtime_version='1.18.32', model=model, family=family,
                api_provider='venice', credentials={'VENICE_API_KEY': {'env': env}},
                connection=dict(base_url='https://venice.example.invalid/v1', api_key_env='VENICE_API_KEY', context=1000, output=100))


class Configured(unittest.TestCase):
    """A test-owned agent-comms home with an access file and profiles; the real one is never read."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.runtime = self.root / 'opencode'
        self.runtime.write_text('#!/bin/sh\ncase "$1" in --version) echo 1.18.32;; acp) for v in $OC_ENV_VARS; do printf "%s=%s\\n" "$v" "$(printenv "$v" || echo "<unset>")" >> "$OC_ENV_LOG"; done;; esac\n')
        self.runtime.chmod(0o755)
        self.env = patch.dict(os.environ, {'AGENT_COMMS_HOME': str(self.root)})
        self.env.start()
        self.addCleanup(self.env.stop)
        agents = {'glm': opencode(str(self.runtime), 'venice/glm-a', 'glm', 'CFG_VENICE_KEY'),
                  'other': opencode(str(self.runtime), 'venice/glm-a', 'glm', 'CFG_OTHER_KEY')}
        (self.root / 'agents.json').write_text(json.dumps({'version': 1, 'agents': agents}))
        self.write_access(ACCESS)

    def write_access(self, entries):
        path = self.root / 'access.json'
        path.write_text(json.dumps({'version': 1, 'agents': entries}))
        path.chmod(0o600)

    def loaded(self):
        profile_set = profiles.load()
        return profile_set, access.load_checked(profile_set)


class Scrub(Configured):
    ENV = {'PATH': '/usr/bin', 'HOME': '/home/x', 'BD_PLAIN_SETTING': 'visible',
           'CFG_GEMINI_KEY': 'v1', 'CFG_VENICE_KEY': 'v2', 'CFG_OTHER_KEY': 'v3',      # configured, arbitrary names
           'VENICE_API_KEY': 'v4',                                                       # configured, pattern-shaped
           'ZZ_UNCONFIGURED_API_KEY': 'v5', 'SOME_TOKEN': 'v6', 'MY_SECRET_THING': 'v7', 'X_ACCESS_KEY_ID': 'v8',   # patterns only
           'GOOGLE_APPLICATION_CREDENTIALS': 'v9', 'OPENAI_BASE_URL': 'v10', 'AWS_PROFILE': 'v11',               # the table
           'COMMS_ROUTE_API_KEY': 'v12', 'AGENT_COMMS_SERVICE_TOKEN': 'v13'}            # no prefix is exempt: only credential shapes are removed, nothing is kept by name

    def test_every_kind_of_credential_name_is_removed_and_the_rest_kept(self):
        profile_set, entries = self.loaded()
        removed = set(access.scrub_list(self.ENV, entries, profile_set))
        self.assertEqual(removed, {'CFG_GEMINI_KEY', 'CFG_VENICE_KEY', 'CFG_OTHER_KEY', 'VENICE_API_KEY', 'ZZ_UNCONFIGURED_API_KEY',
                                   'SOME_TOKEN', 'MY_SECRET_THING', 'X_ACCESS_KEY_ID', 'GOOGLE_APPLICATION_CREDENTIALS',
                                   'OPENAI_BASE_URL', 'AWS_PROFILE', 'COMMS_ROUTE_API_KEY', 'AGENT_COMMS_SERVICE_TOKEN'})

    def test_a_name_configured_as_a_credential_cannot_escape_the_scrub(self):
        profile_set, entries = self.loaded()
        arbitrary = {'MY_INFERENCE_KEY': 'x', 'API_KEY': 'y', 'CODEX_METERED_KEY': 'z'}
        entries = dict(entries, codex=dict(ACCESS['codex']))
        profile_set = dict(profile_set)
        profile_set['alpha'] = dict(adapter='acp', command=[sys.executable], family='f', model='m/m',
                                    credentials={'API_KEY': {'env': 'MY_INFERENCE_KEY'}})
        self.assertEqual(set(access.scrub_list(arbitrary, {}, profile_set)), {'MY_INFERENCE_KEY', 'API_KEY'})
        # a name only access.json mentions is covered even when no profile does
        self.assertIn('CODEX_METERED_KEY', access.scrub_list(arbitrary, {'x': dict(ACCESS['gemini'], credential='env:CODEX_METERED_KEY')}, profile_set))

    def test_a_keep_set_exempts_exactly_the_legs_own_names(self):
        profile_set, entries = self.loaded()
        self.assertNotIn('CFG_VENICE_KEY', access.scrub_list(self.ENV, entries, profile_set, keep={'CFG_VENICE_KEY'}))
        self.assertIn('CFG_OTHER_KEY', access.scrub_list(self.ENV, entries, profile_set, keep={'CFG_VENICE_KEY'}))

    PREPARED = access.PREPARED

    def test_a_custom_harness_gets_only_its_prepared_credential_under_its_own_name(self):
        profile_set, entries = self.loaded()
        environment = access.bound_environment(dict(self.ENV, **{self.PREPARED: 'prepared'}), profile_set['glm'], entries, profile_set)
        self.assertEqual(environment['VENICE_API_KEY'], 'prepared')   # the runner's one resolution, under the profile's destination
        for name in ('CFG_GEMINI_KEY', 'CFG_VENICE_KEY', 'CFG_OTHER_KEY', 'ZZ_UNCONFIGURED_API_KEY', 'SOME_TOKEN',
                     'GOOGLE_APPLICATION_CREDENTIALS', 'AWS_PROFILE', 'COMMS_ROUTE_API_KEY', self.PREPARED):
            self.assertNotIn(name, environment)
        self.assertEqual(environment['BD_PLAIN_SETTING'], 'visible')

    def test_an_inherited_key_never_stands_in_for_the_bound_reference(self):
        profile_set, entries = self.loaded()
        # the ambient destination variable and the reference's own source are both present, the prepared value is not
        with self.assertRaises(ValueError):
            access.bound_environment(dict(self.ENV), profile_set['glm'], entries, profile_set)
        # and when it is, the ambient values lose to it: a keychain-bound credential is not overridden by VENICE_API_KEY
        environment = access.bound_environment(dict(self.ENV, **{self.PREPARED: 'from-bound-reference'}), profile_set['glm'], entries, profile_set)
        self.assertEqual(environment['VENICE_API_KEY'], 'from-bound-reference')

    def test_a_credential_that_is_not_there_refuses_rather_than_running_without_it(self):
        profile_set, entries = self.loaded()
        with self.assertRaises(ValueError):
            access.bound_environment({'PATH': '/usr/bin'}, profile_set['glm'], entries, profile_set)

    def test_env_plan_for_each_billing_class(self):
        profile_set, entries = self.loaded()
        with self.assertRaises(profiles.ProfileError):                    # gemini runs agy directly: no auth row, no env plan
            access.env_plan('gemini', 'gemini', 'api', dict(self.ENV, GEMINI_API_KEY='ambient'), None, entries, profile_set)
        subscription = access.env_plan('codex', 'codex', 'subscription', dict(self.ENV, GEMINI_API_KEY='ambient'), None, entries, profile_set)
        self.assertIsNone(subscription['destination'])
        self.assertIn('GEMINI_API_KEY', subscription['unset'])            # no API fallback exists for a subscription leg
        custom = access.env_plan('glm', 'opencode', 'api', self.ENV, profile_set['glm'], entries, profile_set)
        self.assertEqual(custom['destination'], self.PREPARED)           # one prepared credential, under one marker
        self.assertIn('CFG_VENICE_KEY', custom['unset'])                # the profile's own source and destination are scrubbed too
        self.assertIn('VENICE_API_KEY', custom['unset'])
        self.assertNotIn(self.PREPARED, custom['unset'])
        self.assertIn('CFG_OTHER_KEY', custom['unset'])

    def test_serve_in_bound_mode_hands_the_harness_only_its_own_credential(self):
        profile_set, entries = self.loaded()
        binding_ = profiles.resolve('glm')
        log = self.root / 'seen.log'
        names = 'VENICE_API_KEY CFG_VENICE_KEY CFG_OTHER_KEY CFG_GEMINI_KEY ZZ_UNCONFIGURED_API_KEY BD_PLAIN_SETTING'
        environ = dict(os.environ, **self.ENV, OC_ENV_LOG=str(log), OC_ENV_VARS=names, **{self.PREPARED: 'prepared'})
        project = self.root / 'tree'; project.mkdir()
        def serve(*extra):
            log.write_text('')
            subprocess.run([sys.executable, str(REPO / 'helpers/agent_profiles.py'), 'serve', profiles.encode(binding_),
                            str(self.root / 'state'), *extra], cwd=project, env=environ, check=True, capture_output=True, timeout=60)
            return dict(line.split('=', 1) for line in log.read_text().splitlines())
        bound = serve('--bound')
        self.assertEqual(bound, {'VENICE_API_KEY': 'prepared', 'CFG_VENICE_KEY': '<unset>', 'CFG_OTHER_KEY': '<unset>', 'CFG_GEMINI_KEY': '<unset>',
                                 'ZZ_UNCONFIGURED_API_KEY': '<unset>', 'BD_PLAIN_SETTING': 'visible'})
        # the control: without --bound the harness inherits the full environment, exactly as before
        unbound = serve()
        self.assertEqual(unbound['CFG_OTHER_KEY'], 'v3')
        self.assertEqual(unbound['ZZ_UNCONFIGURED_API_KEY'], 'v5')

    def test_serve_and_attest_refuse_an_ambient_key_when_nothing_was_prepared_for_the_bound_reference(self):
        # an ambient VENICE_API_KEY (the destination) and the reference's own source are present; the runner prepared nothing
        # (e.g. the bound reference is a keychain item it could not resolve): neither launch path may fall back to the ambient value
        binding_ = profiles.resolve('glm')
        environ = dict(os.environ, **self.ENV)
        environ.pop(self.PREPARED, None)
        project = self.root / 'tree-ambient'; project.mkdir()
        serve = subprocess.run([sys.executable, str(REPO / 'helpers/agent_profiles.py'), 'serve', profiles.encode(binding_),
                                str(self.root / 'state-ambient'), '--bound'], cwd=project, env=environ, capture_output=True, text=True, timeout=60)
        self.assertNotEqual(serve.returncode, 0)
        self.assertNotIn('v2', serve.stdout + serve.stderr)
        with patch.dict(os.environ, self.ENV), self.assertRaises(ValueError):
            profiles.bound_env(binding_['profile'], True)       # the one function attest, serve and acpx all call


class Stamp(Configured):
    LEG = dict(ref='res-1', agent='codex', role='gate', requirement='required', route_id='codex-subscription', model='gpt-6-luna', effort='low',
               access=dict(transport='acp', provider='openai', account='primary', billing='subscription', credential=None))

    def stamp(self):
        return dict(schema=1, capability_version=1, ref='res-1', role='gate', requirement='required', agent='codex',
                    route_id='codex-subscription', model='gpt-6-luna', effort='low', access=copy.deepcopy(self.LEG['access']),
                    access_digest=access.digest(ACCESS['codex']))

    def test_the_stamp_round_trips_and_is_bound_to_its_digest(self):
        encoded = binding.stamp_encode(self.stamp())
        self.assertEqual(binding.stamp_decode(encoded, binding.stamp_digest(encoded))['ref'], 'res-1')
        with self.assertRaises(ValueError):
            binding.stamp_decode(encoded, '0' * 64)

    def test_a_stamp_that_is_not_canonical_or_has_extra_keys_is_refused(self):
        spaced = base64.urlsafe_b64encode(json.dumps(self.stamp()).encode()).decode()      # not the canonical form
        with self.assertRaises(ValueError):
            binding.stamp_decode(spaced)
        extra = dict(self.stamp(), tier='fast')
        with self.assertRaises(ValueError):
            binding.stamp_decode(binding.stamp_encode(extra))
        with self.assertRaises(ValueError):
            binding.stamp_decode('')

    def test_the_result_binding_states_expected_and_observed_separately(self):
        encoded = binding.stamp_encode(self.stamp())
        ran = json.loads(binding.binding_json(encoded, 'ran', 'gpt-6-luna', 'low', 'observed', []))
        self.assertEqual(ran['expected'], {'model': 'gpt-6-luna', 'effort': 'low'})
        self.assertEqual(ran['observed'], {'model': 'gpt-6-luna', 'effort': 'low'})
        self.assertEqual((ran['status'], ran['auth_evidence'], ran['credential_ref'], ran['route_id']), ('ran', 'observed', None, 'codex-subscription'))
        refused = json.loads(binding.binding_json(encoded, 'refused', '', '', 'bogus', ['account-mismatch', 'made-up']))
        self.assertEqual(refused['observed'], {'model': None, 'effort': None})          # never copied from expected
        self.assertEqual((refused['auth_evidence'], refused['mismatches']), ('configured', ['account-mismatch']))

    def test_recheck_judges_the_stamp_against_the_configuration_as_it_is_now(self):
        encoded = binding.stamp_encode(self.stamp())
        context = {'provider': 'codex', 'transport': 'acp'}
        with patch.object(binding, 'resolve_pair', return_value=({'capability': 'eligible'}, [])), \
             patch.object(binding, 'observe_auth', return_value=[]):
            stamp, result = binding.recheck(encoded, binding.stamp_digest(encoded), 'codex', 'codex', 'acp')
            self.assertEqual(result['status'], 'ok')
            changed = dict(ACCESS, codex=dict(ACCESS['codex'], account='secondary'))
            self.write_access(changed)
            _, result = binding.recheck(encoded, binding.stamp_digest(encoded), 'codex', 'codex', 'acp')
            self.assertEqual((result['status'], result['codes']), ('refused', ['account-mismatch']))


class Quota(unittest.TestCase):
    def quota(self, provider, rate=None, reason=''):
        return json.loads(binding.quota_json(provider, 'host', rate, reason))

    def test_codex_reports_an_observed_snapshot_or_says_it_has_none(self):
        observed = self.quota('codex', {'limit_id': 'codex', 'window_minutes': 300, 'used_percent': 12.5, 'resets_at': 1790000200})
        self.assertEqual((observed['state'], observed['source'], observed['used_percent'], observed['resets_at']), ('observed', 'codex-rollout', 12.5, 1790000200))
        empty = self.quota('codex', None)
        self.assertEqual((empty['state'], empty['source'], empty['used_percent']), ('unavailable', 'codex-rollout', None))

    def test_a_provider_with_no_rate_limit_source_is_unsupported_not_missing(self):
        for provider in ('claude', 'grok', 'gemini', 'glm'):
            state = self.quota(provider, None)
            self.assertEqual((state['state'], state['source']), ('unsupported', None), provider)

    def test_a_refusal_is_named_but_its_reset_is_never_manufactured(self):
        refused = self.quota('gemini', None, 'rate-limited')
        self.assertEqual(refused['state'], 'refused')
        self.assertEqual(refused['refusal'], {'kind': 'rate-limited', 'reset_at': None, 'reset_state': 'not_provided'})
        self.assertEqual(self.quota('codex', {'limit_id': 'x'}, 'auth-failed')['refusal']['kind'], 'auth-failed')
        self.assertIsNone(self.quota('gemini', None, 'no-output')['refusal'])

    def test_the_object_is_versioned_and_carries_no_account_identifier(self):
        state = self.quota('codex', None)
        self.assertEqual(state['schema'], binding.LEG_METADATA_VERSION)
        self.assertEqual(state['provider'], 'host')
        self.assertEqual(sorted(state), sorted(['schema', 'provider', 'state', 'source', 'limit_id', 'window_minutes', 'used_percent', 'resets_at', 'refusal']))


class AuthRoute(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def write(self, path, value):
        path = self.root / path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))
        return path

    def test_the_auth_table_declares_every_adapter_billing_pair(self):
        for adapter in ('codex', 'opencode', 'claude'):
            for billing in access.BILLINGS:
                self.assertIn(access.auth_row(adapter, billing)['status'], ('supported', 'unsupported'))
        self.assertEqual(access.auth_row('codex', 'api')['status'], 'unsupported')           # not established for the mounted ACP adapter
        self.assertEqual([b for b in access.BILLINGS if access.auth_row('claude', b)['status'] == 'supported'], ['subscription'])
        for billing in access.BILLINGS:                                                      # gemini runs agy directly: no isolated login to bind
            with self.assertRaises(profiles.ProfileError):
                access.auth_row('gemini', billing)

    def test_codex_login_mode_is_read_without_the_secret(self):
        self.assertEqual(binding.login_mode(self.write('a.json', {'auth_mode': 'ChatGPT', 'tokens': {'id_token': 'x'}})), 'chatgpt')
        self.assertEqual(binding.login_mode(self.write('b.json', {'auth_mode': 'ApiKey', 'OPENAI_API_KEY': 'sk'})), 'apikey')
        self.assertEqual(binding.login_mode(self.write('c.json', {'OPENAI_API_KEY': 'sk'})), 'apikey')
        self.assertIsNone(binding.login_mode(self.write('d.json', {'tokens': {'id_token': 'x'}})))

    def test_observation_refuses_a_login_that_would_run_api_billed(self):
        self.write('home/.codex/auth.json', {'auth_mode': 'apikey', 'OPENAI_API_KEY': 'sk'})
        found = binding.observe_auth('codex', 'subscription', {'HOME': str(self.root / 'home')})
        self.assertEqual([c for c, _ in found], ['auth-selected-type-conflict'])
        self.assertEqual([c for c, _ in binding.observe_auth('codex', 'subscription', {'HOME': str(self.root / 'empty')})], ['auth-login-missing'])
        self.assertEqual([c for c, _ in binding.observe_auth('codex', 'api', {'HOME': str(self.root)})], ['auth-route-unsupported'])

    def test_readback_codex_requires_the_staged_chatgpt_login_and_no_credential(self):
        self.write('iso/auth.json', {'auth_mode': 'chatgpt', 'tokens': {'id_token': 'x'}})
        self.assertEqual(binding.auth_readback('codex', 'subscription', self.root / 'iso', False), ('observed', None))
        self.assertIsNone(binding.auth_readback('codex', 'subscription', self.root / 'iso', True)[0])
        self.write('iso/auth.json', {'auth_mode': 'apikey', 'OPENAI_API_KEY': 'sk'})
        self.assertIsNone(binding.auth_readback('codex', 'subscription', self.root / 'iso', False)[0])
        (self.root / 'iso/auth.json').unlink()
        self.assertIsNone(binding.auth_readback('codex', 'subscription', self.root / 'iso', False)[0])

    def test_gemini_has_no_auth_route_to_read_back(self):
        for billing in ('api', 'subscription'):
            with self.assertRaises(profiles.ProfileError):
                binding.auth_readback('gemini', billing, self.root / 'iso', False)

    def test_gemini_is_unbindable_whatever_its_transport(self):
        adapter, why = binding.classify('gemini', 'acp', {})
        self.assertIsNone(adapter)
        self.assertTrue(why.startswith('gemini-unsupported'))

    def test_claude_binds_over_acp_and_grok_still_does_not(self):
        self.assertEqual(binding.classify('claude', 'acp', {}), ('claude', None))
        self.assertIsNone(binding.classify('claude', 'cli', {})[0])
        adapter, why = binding.classify('grok', 'acp', {})
        self.assertIsNone(adapter)
        self.assertTrue(why.startswith('grok-unsupported'))

    def test_a_claude_route_other_than_subscription_is_refused_before_any_read(self):
        for billing in ('api', 'local', 'free'):
            self.assertEqual([c for c, _ in binding.observe_auth('claude', billing, {})], ['auth-route-unsupported'])
            self.assertIsNone(binding.auth_readback('claude', billing, '', False)[0])

    def test_a_custom_profile_selects_its_route_through_its_credentials_so_it_is_only_configured(self):
        self.assertEqual(binding.auth_readback('opencode', 'api', '', True), ('configured', None))
        self.assertIsNone(binding.auth_readback('opencode', 'subscription', '', False)[0])


class Parse(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'legs.json'

    def write(self, legs, schema=binding.SCHEMA):
        self.path.write_text(json.dumps({'schema': schema, 'legs': legs}))
        return binding.parse(self.path)

    def test_a_complete_file_parses_in_order(self):
        legs = self.write([Stamp.LEG, dict(Stamp.LEG, agent='gemini', ref='r2')])
        self.assertEqual([leg['agent'] for leg in legs], ['codex', 'gemini'])

    def test_every_defect_is_a_usage_error(self):
        for label, legs in [('unknown key', [dict(Stamp.LEG, tier='fast')]), ('no model', [{k: v for k, v in Stamp.LEG.items() if k != 'model'}]),
                            ('bad role', [dict(Stamp.LEG, role='judge')]), ('bad requirement', [dict(Stamp.LEG, requirement='maybe')]),
                            ('bad effort', [dict(Stamp.LEG, effort='a b')]), ('two refs', [Stamp.LEG, dict(Stamp.LEG, agent='gemini')]),
                            ('too many', [dict(Stamp.LEG, agent=f'agent{i}', ref=f'r{i}') for i in range(17)]),
                            ('access not an object', [dict(Stamp.LEG, access='x')])]:
            with self.subTest(label), self.assertRaises(ValueError):
                self.write(legs)
        with self.assertRaises(ValueError):
            self.write([Stamp.LEG], schema='leg-bindings/2')

    def test_a_null_effort_and_a_null_credential_are_values_not_omissions(self):
        legs = self.write([dict(Stamp.LEG, effort=None)])
        self.assertIsNone(legs[0]['effort'])
        self.assertIsNone(legs[0]['access']['credential'])

    def test_capability_names_the_versions_negotiation_reads(self):
        self.assertEqual(binding.capability_line(), 'leg-binding-capability v1 leg-bindings=1 route-view=2 leg-metadata=1')


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
