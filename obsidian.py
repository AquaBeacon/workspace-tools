"""Prepare a local Obsidian vault for the multi-repository workspace."""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent


def settings(root: Path) -> dict:
    return json.loads((root / 'workspace-tools/repositories.json').read_text(
        encoding='utf-8'))['obsidian']


def local_path(root: Path, relative: str) -> Path:
    path = (root / relative).resolve()
    if not path.is_relative_to(root.resolve()):
        raise ValueError(f'Path outside workspace: {relative}')
    return path


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    content = json.dumps(value, ensure_ascii=False, indent=2) + '\n'
    if not path.exists() or path.read_text(encoding='utf-8') != content:
        path.write_text(content, encoding='utf-8')


def defaults(path: Path, values: dict) -> None:
    current = json.loads(path.read_text(encoding='utf-8')) if path.exists() else {}
    for key, value in values.items():
        current.setdefault(key, value)
    write_json(path, current)


def configure(root: Path) -> None:
    config = settings(root)
    private = config['private_root']
    for name in ['00_Inbox', '10_Notes', '20_Sources', '30_Experiments',
                 '40_Decisions', '50_Journal', '90_Attachments']:
        local_path(root, f'{private}/{name}').mkdir(parents=True, exist_ok=True)
    vault = local_path(root, config['vault_root'])
    obsidian = vault / '.obsidian'
    defaults(obsidian / 'app.json', {
        'newFileLocation': 'folder',
        'newFileFolderPath': f'{private}/00_Inbox',
        'attachmentFolderPath': f'{private}/90_Attachments',
        'alwaysUpdateLinks': True,
        'useMarkdownLinks': False,
        'newLinkFormat': 'absolute',
        'promptDelete': True,
        'userIgnoreFilters': ['.local/', '.git/', 'obsidian/knowledge/templates/',
                          'spresense-imu/spresense/', 'spresense-imu/nuttx/',
                          'node_modules/', '.venv/', '.pio/'],
    })
    defaults(obsidian / 'templates.json', {
        'folder': config['templates'], 'dateFormat': 'YYYY-MM-DD', 'timeFormat': 'HH:mm',
    })
    defaults(obsidian / 'daily-notes.json', {
        'folder': f'{private}/50_Journal', 'format': 'YYYY-MM-DD',
        'template': config['templates'] + '/日誌.md', 'autorun': False,
    })
    defaults(obsidian / 'graph.json', {
        'search': 'path:obsidian/knowledge -path:obsidian/knowledge/templates',
        'showTags': False, 'showAttachments': False, 'showOrphans': True,
    })
    defaults(obsidian / 'hotkeys.json', {
        'daily-notes': [{'modifiers': ['Mod', 'Alt'], 'key': 'D'}],
        'insert-template': [{'modifiers': ['Mod', 'Alt'], 'key': 'T'}],
    })
    plugins_path = obsidian / 'core-plugins.json'
    plugins = json.loads(plugins_path.read_text(encoding='utf-8')) if plugins_path.exists() else []
    required = ['file-explorer', 'global-search', 'switcher', 'graph', 'backlink',
                'canvas', 'outgoing-link', 'tag-pane', 'properties', 'daily-notes',
                'templates', 'note-composer', 'command-palette', 'bookmarks',
                'outline', 'word-count', 'file-recovery', 'bases']
    for plugin in required:
        if isinstance(plugins, dict):
            plugins[plugin] = True
        elif plugin not in plugins:
            plugins.append(plugin)
    write_json(plugins_path, plugins)
    bookmarks_path = obsidian / 'bookmarks.json'
    bookmarks = json.loads(bookmarks_path.read_text(encoding='utf-8')) if bookmarks_path.exists() else {}
    items = bookmarks.setdefault('items', [])
    for key, title in [('home', 'AquaBeacon 知識のホーム'),
                       ('base', '知識一覧'), ('canvas', '知識マップ')]:
        if not any(item.get('type') == 'file' and item.get('path') == config[key] for item in items):
            items.append({'type': 'file', 'path': config[key], 'title': title})
    write_json(bookmarks_path, bookmarks)
    starter = local_path(root, f'{private}/00_Inbox/自由メモ.md')
    if not starter.exists():
        starter.write_text('''---
kind: note
status: inbox
tags:
  - knowledge
---

# 自由メモ

思いつき、疑問、引用したいこと、作業中の気づきをそのまま書く。
整理やテンプレートは後回しでよい。

- この場所を、これから知識をためて自由に使うための入口にする。
- 関連するノートができたら `[[` でつなぐ。

[[obsidian/knowledge/ホーム|ホーム]] · [[obsidian/knowledge/使い方|使い方]]
''', encoding='utf-8')
    print(f'Obsidian vault: {vault}')
    print(f'New notes: {private}/00_Inbox (Git-ignored)')
    print('Existing note contents and personal settings preserved; required core plugins enabled.')


def check(root: Path) -> list[str]:
    config = settings(root)
    errors = []
    for key in ['vault_root', 'knowledge_root', 'home', 'templates', 'base', 'canvas', 'private_root']:
        if not local_path(root, config[key]).exists():
            errors.append(f'Missing {key}: {config[key]}')
    knowledge = local_path(root, config['knowledge_root'])
    # Templates deliberately contain placeholders; user notes may link to ideas not written yet.
    private = local_path(root, config['private_root'])
    templates = local_path(root, config['templates'])
    for note in sorted(knowledge.rglob('*.md')):
        if note.is_relative_to(private) or note.is_relative_to(templates):
            continue
        content = note.read_text(encoding='utf-8')
        for match in re.finditer(r'(?<!!)\[\[([^\]\n]+)\]\]', content):
            target = match.group(1).replace('\\|', '|').split('|')[0].split('#')[0]
            if not target:
                continue
            path = local_path(root, target)
            if not path.exists() and not path.with_suffix('.md').exists():
                errors.append(f'{note.relative_to(root)}: unresolved [[{target}]]')
    canvas = local_path(root, config['canvas'])
    if canvas.exists():
        data = json.loads(canvas.read_text(encoding='utf-8'))
        ids = [item['id'] for item in data['nodes'] + data['edges']]
        if len(ids) != len(set(ids)):
            errors.append('Canvas has duplicate IDs')
        node_ids = {node['id'] for node in data['nodes']}
        for node in data['nodes']:
            if node['type'] == 'file' and not local_path(root, node['file']).exists():
                errors.append(f'Canvas file missing: {node["file"]}')
        for edge in data['edges']:
            if edge['fromNode'] not in node_ids or edge['toNode'] not in node_ids:
                errors.append(f'Canvas edge has missing endpoint: {edge["id"]}')
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['configure', 'check'])
    args = parser.parse_args()
    if args.command == 'configure':
        configure(ROOT)
    else:
        errors = check(ROOT)
        for error in errors:
            print('FAIL:', error)
        print(f'Obsidian knowledge structure: {len(errors)} errors')
        return int(bool(errors))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
