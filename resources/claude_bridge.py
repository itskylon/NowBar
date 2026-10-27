#!/usr/bin/env python3
"""Claude Code's official statusLine -> private numeric AgentMeter snapshot.

No network requests and no credential access. Existing statusLine commands keep
their complete stdin and stdout. Install/uninstall are explicit UI actions.
"""
import argparse
import copy
import datetime
import fcntl
import json
import math
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile


def data_dir(home=None):
    return Path(home or Path.home()) / 'Library' / 'Application Support' / 'AgentMeter'


def atomic_write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix='.' + path.name, dir=str(path.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w') as stream:
            stream.write(content)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def json_write(path, value):
    atomic_write(path, json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n')


def read_object(path, default=None):
    if not path.exists():
        return {} if default is None else default
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError('配置文件必须是 JSON 对象；未修改原文件。')
    return value


def install(home=None):
    home = Path(home or Path.home())
    support = data_dir(home)
    support.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (support / 'bridge.lock').open('a') as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        settings_path = home / '.claude' / 'settings.json'
        settings = read_object(settings_path)
        state_path = support / 'claude-bridge-state.json'
        state = read_object(state_path)
        if state and settings.get('statusLine') == state.get('installed_statusLine'):
            return {'installed': True, 'message': 'Claude 桥接已接入。'}
        target = support / 'claude_bridge.py'
        previous = copy.deepcopy(settings.get('statusLine'))
        if state and previous == state.get('installed_statusLine'):
            previous = state.get('original_statusLine')
        # Validate before touching either settings or the helper.
        if previous is not None and (not isinstance(previous, dict) or previous.get('type') != 'command'):
            raise ValueError('现有 statusLine 不是 command 类型，保留原设置。')
        if previous is not None and not isinstance(previous.get('command'), str):
            raise ValueError('现有 statusLine 命令无效，保留原设置。')
        command = shlex.quote(sys.executable) + ' ' + shlex.quote(str(target))
        if not state and previous is not None and previous.get('command') == command:
            raise ValueError('桥接恢复记录缺失；保留当前设置，避免重复包裹自身。')
        configured = copy.deepcopy(previous) if previous else {'type': 'command'}
        configured['command'] = command
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        if settings_path.exists():
            atomic_write(support / ('claude-settings-backup-' + stamp + '.json'), settings_path.read_text())
        atomic_write(target, Path(__file__).read_text())
        new_state = {'version': 1, 'original_statusLine': previous, 'installed_statusLine': configured}
        json_write(state_path, new_state)
        settings['statusLine'] = configured
        json_write(settings_path, settings)
        return {'installed': True, 'message': '已接入。请新开 Claude Code 会话；首个回复后更新额度。'}


def uninstall(home=None):
    home = Path(home or Path.home())
    support = data_dir(home)
    state_path = support / 'claude-bridge-state.json'
    state = read_object(state_path)
    settings_path = home / '.claude' / 'settings.json'
    if not state:
        return {'installed': False, 'message': 'Claude 桥接未安装。'}
    settings = read_object(settings_path)
    if settings.get('statusLine') != state.get('installed_statusLine'):
        return {'installed': False, 'message': '检测到后续手动修改，保留当前 Claude 设置。'}
    original = state.get('original_statusLine')
    if original is None:
        settings.pop('statusLine', None)
    else:
        settings['statusLine'] = original
    json_write(settings_path, settings)
    state_path.unlink(missing_ok=True)
    return {'installed': False, 'message': '已移除桥接并恢复原有状态栏设置。'}


def status(home=None):
    home = Path(home or Path.home())
    state = read_object(data_dir(home) / 'claude-bridge-state.json')
    settings = read_object(home / '.claude' / 'settings.json')
    return {'installed': bool(state and settings.get('statusLine') == state.get('installed_statusLine'))}


def finite_number(value):
    if isinstance(value, bool) or not isinstance(value, (float, int)):
        return None
    return float(value) if math.isfinite(value) else None


def capture(payload, home=None):
    limits = payload.get('rate_limits')
    if not isinstance(limits, dict):
        # Absence does not mean zero usage and must not freshen an old snapshot.
        return False
    sanitized = {}
    for name in ('five_hour', 'seven_day'):
        item = limits.get(name)
        if not isinstance(item, dict):
            continue
        used = finite_number(item.get('used_percentage'))
        reset = finite_number(item.get('resets_at'))
        if used is None or used < 0 or used > 100 or reset is None or reset <= 0:
            continue
        sanitized[name] = {'used_percentage': used, 'resets_at': reset}
    snapshot = {'version': 1,
                'updated_at': datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z'),
                'rate_limits': sanitized}
    json_write(data_dir(home) / 'claude-usage.json', snapshot)
    return True


def run_original(raw, home=None):
    state = read_object(data_dir(home) / 'claude-bridge-state.json')
    original = state.get('original_statusLine') or {}
    command = original.get('command')
    if isinstance(command, str) and command:
        try:
            environment = dict(os.environ)
            if home is not None:
                environment['HOME'] = str(home)
            return subprocess.run(command, shell=True, executable='/bin/sh', input=raw, text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  timeout=5, check=False, env=environment).stdout
        except (subprocess.TimeoutExpired, OSError):
            return ''
    try:
        limits = json.loads(raw).get('rate_limits') or {}
        parts = []
        for key, label in (('five_hour', '5h'), ('seven_day', '周')):
            used = finite_number((limits.get(key) or {}).get('used_percentage'))
            if used is not None:
                parts.append(label + ' 剩余 ' + str(round(max(0, min(100, 100 - used)))) + '%')
        return ' · '.join(parts) if parts else 'AgentMeter · 等待额度数据'
    except (ValueError, AttributeError):
        return ''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--install', action='store_true')
    group.add_argument('--uninstall', action='store_true')
    group.add_argument('--status', action='store_true')
    args = parser.parse_args()
    try:
        if args.install:
            print(json.dumps(install(), ensure_ascii=False))
        elif args.uninstall:
            print(json.dumps(uninstall(), ensure_ascii=False))
        elif args.status:
            print(json.dumps(status(), ensure_ascii=False))
        else:
            raw = sys.stdin.read()
            try:
                payload = json.loads(raw)
                if isinstance(payload, dict):
                    capture(payload)
            except (ValueError, OSError):
                pass
            sys.stdout.write(run_original(raw))
    except (OSError, ValueError) as error:
        # Do not echo command strings, settings, stdin, or arbitrary file contents.
        print(json.dumps({'error': '无法更新 Claude 桥接，请检查配置文件和目录权限。'}, ensure_ascii=False))
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
