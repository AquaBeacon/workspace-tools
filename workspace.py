"""Inspect the AquaBeacon multi-repository workspace without changing Git state."""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
REGISTRY = HERE / 'repositories.json'


def git(directory: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(['git', '-C', str(directory), *args], capture_output=True)


def check(repositories: list[dict]) -> list[str]:
    errors = []
    if (ROOT / '.git').exists():
        errors.append('The workspace parent must not be a Git repository.')
    names = [r['name'] for r in repositories]
    if len(names) != len(set(names)):
        errors.append('Duplicate repository name in registry.')
    for repo in repositories:
        p = ROOT / repo['name']
        if not (p / '.git').is_dir():
            errors.append(f'{repo["name"]}: missing independent .git directory')
            continue
        result = git(p, 'rev-parse', '--show-toplevel')
        if result.returncode or Path(result.stdout.decode().strip()).resolve() != p.resolve():
            errors.append(f'{repo["name"]}: Git root is not this project')
        for entry in ['README.md', 'AGENTS.md', 'DEVELOPMENT.md', 'LICENSE', 'NOTICE',
                      'THIRD_PARTY.md', '.gitignore', *repo['entrypoints']]:
            if not (p / entry).exists():
                errors.append(f'{repo["name"]}: missing {entry}')
        if repo.get('original_head') and repo.get('history_scope') != 'local_archive':
            result = git(p, 'cat-file', '-e', repo['original_head'] + '^{commit}')
            if result.returncode:
                errors.append(f'{repo["name"]}: original history is unavailable')
        license_path = p / 'LICENSE'
        if license_path.exists() and 'Apache License' not in license_path.read_text(encoding='utf-8'):
            errors.append(f'{repo["name"]}: Apache license text missing')
    folders = json.loads((ROOT / 'AquaBeacon.code-workspace').read_text(encoding='utf-8'))['folders']
    if sorted(f['path'] for f in folders) != sorted(names):
        errors.append('Editor workspace and registry differ.')
    return errors


SECRET = re.compile(rb'(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|'
                    rb'AKIA[0-9A-Z]{16}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)')
TEXT_SUFFIXES = {'.py', '.md', '.json', '.toml', '.yaml', '.yml', '.ini', '.ps1',
                 '.sh', '.bat', '.cpp', '.h', '.html', '.js', '.cjs', '.txt', '.cfg'}


def audit(repositories: list[dict]) -> dict:
    """Inspect current publish candidates; never print credential contents."""
    report = {'scope': 'Current files (tracked + untracked non-ignored); not full Git history',
              'repositories': [], 'blocking_findings': 0}
    for repo in repositories:
        p = ROOT / repo['name']
        result = git(p, 'ls-files', '-z', '--cached', '--others', '--exclude-standard')
        if result.returncode:
            raise RuntimeError(f'Cannot enumerate {repo["name"]}')
        candidates = sorted(set(result.stdout.decode('utf-8').split('\0')) - {''})
        findings, total, count, missing, lfs = [], 0, 0, 0, []
        for relative in candidates:
            path = p / relative
            if not path.is_file():
                missing += 1
                continue  # Unstaged relocations are reported separately, not lost files.
            count += 1
            size = path.stat().st_size
            total += size
            parts = set(Path(relative).parts)
            reasons = []
            if size >= 100 * 1024 * 1024:
                attribute = git(p, 'check-attr', 'filter', '--', relative)
                if attribute.returncode == 0 and attribute.stdout.rstrip().endswith(b': lfs'):
                    lfs.append(relative)
                else:
                    reasons.append('large_file_over_100_MiB_without_LFS')
            if path.name.startswith('.env') and path.name != '.env.example':
                reasons.append('environment_file')
            if parts & {'.claude', '.agents', '.openai', '.local', '.history', '.pio', '.deps', '.venv'}:
                reasons.append('local_only_directory')
            if '購入物品' in path.name:
                reasons.append('private_procurement_record')
            if path.suffix.lower() in TEXT_SUFFIXES and size < 2_000_000:
                content = path.read_bytes()
                if SECRET.search(content):
                    reasons.append('possible_credential')
            if reasons:
                findings.append({'path': relative, 'reasons': reasons, 'bytes': size})
        report['repositories'].append({'name': repo['name'], 'candidate_files': count,
            'candidate_bytes': total, 'missing_index_paths': missing,
            'large_files_configured_for_lfs': lfs, 'findings': findings})
        report['blocking_findings'] += len(findings)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['list', 'check', 'audit', 'configure'])
    parser.add_argument('--output', type=Path, help='Write the audit JSON here')
    args = parser.parse_args()
    repositories = json.loads(REGISTRY.read_text(encoding='utf-8'))['repositories']
    if args.command == 'configure':
        # Regenerate only these explicitly managed workspace files, never project contents.
        for name in ['README.md', 'AGENTS.md', '.gitignore']:
            (ROOT / name).write_bytes((HERE / 'workspace-template' / name).read_bytes())
        workspace = {'folders': [{'name': r['name'], 'path': r['name']} for r in repositories],
                     'settings': {'files.exclude': {'**/.local': True, '**/.git': True,
                                                     '**/__pycache__': True},
                                  'search.exclude': {'**/.local': True, '**/_work': True,
                                                     '**/.pio': True, '**/spresense': True,
                                                     '**/data': True, '**/.venv*': True}}}
        (ROOT / 'AquaBeacon.code-workspace').write_text(
            json.dumps(workspace, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print('Workspace README, rules, ignore file and editor configuration generated.')
        return 0
    if args.command == 'list':
        for repo in repositories:
            print(f'{repo["name"]:24s} {repo["purpose"]}')
        return 0
    if args.command == 'check':
        errors = check(repositories)
        for error in errors:
            print('FAIL:', error)
        print(f'{len(repositories)} repositories; {len(errors)} structural errors')
        return int(bool(errors))
    result = audit(repositories)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    for repo in result['repositories']:
        print(f'{repo["name"]}: {repo["candidate_files"]} files, '
              f'{repo["candidate_bytes"] / 1024**2:.1f} MiB, {len(repo["findings"])} findings')
    print(f'{result["blocking_findings"]} findings; full history and third-party rights need separate review.')
    return int(bool(result['blocking_findings']))


if __name__ == '__main__':
    sys.exit(main())
