#!/usr/bin/env python3
"""Interactive driver launch from an operator profile; separate from reviewer policy."""
import argparse
import copy
import json
import os
from pathlib import Path
import subprocess
import sys

from agent_profiles import ProfileError, TOKEN, credentials, load, resolve, unique_object
from opencode_adapter import VERSION, config as reviewer_config


def select_profile(name, model, profiles):
    selected = copy.deepcopy(profiles[name])
    if selected['adapter'] != 'opencode':
        raise ProfileError('interactive launch currently supports the opencode adapter')
    provider = selected['model'].split('/', 1)[0]
    if model:
        if not TOKEN.fullmatch(model):
            raise ProfileError('invalid model identifier')
        # Bare IDs may themselves include a vendor slash; only our provider prefix
        # is special. The connection always remains the operator-selected provider.
        selected['model'] = model if model.startswith(provider + '/') else provider + '/' + model
    if not TOKEN.fullmatch(selected['model']):
        raise ProfileError('model identifier is too long')
    return selected


def identity(name, profile, profiles, enabled):
    keys = ('adapter', 'command', 'model', 'runtime_version', 'connection', 'credentials')
    matches = [n for n, p in profiles.items() if n in enabled
               and all(p.get(k) == profile.get(k) for k in keys)]
    if name in matches:
        return name
    return matches[0] if len(matches) == 1 else None


def configuration(profile, inherited, skills):
    raw = inherited.get('OPENCODE_CONFIG_CONTENT', '{}')
    config = json.loads(raw, object_pairs_hook=unique_object)
    if not isinstance(config, dict):
        raise ProfileError('OPENCODE_CONFIG_CONTENT must be a JSON object')
    provider, _ = profile['model'].split('/', 1)
    # Reuse only the provider declaration; never copy the review tool restrictions.
    config.setdefault('provider', {}).update(reviewer_config(profile)['provider'])
    config.update(model=profile['model'], small_model=profile['model'],
                  default_agent='build', enabled_providers=[provider], autoupdate=False)
    build = config.setdefault('agent', {}).setdefault('build', {})
    build.update(model=profile['model'], disable=False)
    if skills:
        paths = config.setdefault('skills', {}).setdefault('paths', [])
        if not isinstance(paths, list) or not all(isinstance(p, str) for p in paths):
            raise ProfileError('skills.paths must be an array of paths')
        if str(skills) not in paths:
            paths.append(str(skills))
    return config


def project_context(helper):
    def read(*args):
        result = subprocess.run([str(helper), *args], capture_output=True, text=True, timeout=30)
        if result.returncode:
            raise ProfileError('could not read project agent configuration')
        return result.stdout.strip()
    enabled = read('agents', '--drivers').split()
    root = Path(read('root')).parent
    skills = root / '.agents' / 'skills'
    return enabled, skills if skills.is_dir() else None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('profile', help='operator profile providing the runtime and connection')
    parser.add_argument('model', nargs='?', help='optional model ID within that provider')
    parser.add_argument('--print', action='store_true', dest='show', help='show public launch settings without credentials or starting the runtime')
    parser.add_argument('--prompt', help='initial task in the interactive session')
    args = parser.parse_args(argv)
    if os.environ.get('COMMS_REVIEW_TURN'):
        raise ProfileError('a review turn cannot launch an implementing agent')
    profiles = load()
    if args.profile not in profiles:
        raise ProfileError(f'no operator profile for {args.profile}')
    profile = select_profile(args.profile, args.model, profiles)
    binding = resolve(args.profile)
    enabled, skills = project_context(Path(__file__).with_name('comms.sh'))
    driver = identity(args.profile, profile, profiles, enabled)
    settings = configuration(profile, os.environ, skills)
    command = [binding['profile']['command'][0], '--model', profile['model'], '--agent', 'build']
    if args.prompt is not None:
        command += ['--prompt', args.prompt]
    if args.show:
        # Do not echo inherited config: it may contain inline API keys.
        print(json.dumps({'command': command, 'profile': args.profile, 'model': profile['model'],
                          'identity': driver, 'skills': str(skills) if skills else None}))
        return
    version = subprocess.run([command[0], '--version'], capture_output=True, text=True, timeout=15)
    if version.returncode or version.stdout.strip() != VERSION:
        raise ProfileError(f'configured OpenCode runtime must be {VERSION}')
    env = credentials(profile, os.environ)
    # An unmatched override must never inherit the caller's codex/claude identity.
    env['COMMS_SELF'] = driver or 'unregistered-model:' + profile['model']
    env['OPENCODE_CONFIG_CONTENT'] = json.dumps(settings)
    env['PWD'] = os.getcwd()
    if driver:
        print(f'Launching {profile["model"]} as {driver} (Build).', file=sys.stderr, flush=True)
    else:
        print('Launching standalone Build session. Register an enabled profile with this exact '
              'model/connection for agent-comms workflows.', file=sys.stderr, flush=True)
    os.execvpe(command[0], command, env)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, TypeError, AttributeError, OSError, subprocess.SubprocessError) as error:
        print(f'launch: {error}', file=sys.stderr)
        sys.exit(1)
