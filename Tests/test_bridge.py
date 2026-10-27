import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'resources' / 'claude_bridge.py'

class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        spec = importlib.util.spec_from_file_location('bridge', SCRIPT)
        self.bridge = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.bridge)

    def tearDown(self):
        self.tmp.cleanup()

    def settings(self):
        return self.home / '.claude' / 'settings.json'

    def write_settings(self, value):
        self.settings().parent.mkdir(parents=True, exist_ok=True)
        self.settings().write_text(json.dumps(value))

    def test_install_preserves_original_and_uninstall_restores_it(self):
        old = {'statusLine': {'type': 'command', 'command': 'cat', 'padding': 2}, 'theme': 'dark'}
        self.write_settings(old)
        self.bridge.install(self.home)
        new = json.loads(self.settings().read_text())
        self.assertEqual(new['theme'], 'dark')
        self.assertEqual(new['statusLine']['padding'], 2)
        self.assertNotEqual(new['statusLine']['command'], 'cat')
        self.assertEqual(stat.S_IMODE(self.settings().stat().st_mode), 0o600)
        self.bridge.uninstall(self.home)
        self.assertEqual(json.loads(self.settings().read_text()), old)

    def test_install_twice_keeps_first_original(self):
        self.write_settings({'statusLine': {'type': 'command', 'command': 'printf original'}})
        self.bridge.install(self.home)
        first = self.settings().read_text()
        self.bridge.install(self.home)
        self.assertEqual(self.settings().read_text(), first)
        self.bridge.uninstall(self.home)
        self.assertEqual(json.loads(self.settings().read_text())['statusLine']['command'], 'printf original')

    def test_uninstall_preserves_later_user_change(self):
        self.write_settings({'theme': 'light'})
        self.bridge.install(self.home)
        changed = json.loads(self.settings().read_text())
        changed['statusLine'] = {'type': 'command', 'command': 'printf later'}
        changed['theme'] = 'dark'
        self.settings().write_text(json.dumps(changed))
        self.bridge.uninstall(self.home)
        self.assertEqual(json.loads(self.settings().read_text()), changed)

    def test_whitelist_only_and_private_permissions(self):
        payload = {'rate_limits': {'five_hour': {'used_percentage': 24, 'resets_at': 1800000000,
                                               'secret': 'sensitive'}, 'seven_day': None},
                   'transcript_path': '/secret', 'session_id': 'secret', 'api_key': 'secret'}
        self.assertTrue(self.bridge.capture(payload, self.home))
        path = self.bridge.data_dir(self.home) / 'claude-usage.json'
        saved = json.loads(path.read_text())
        self.assertEqual(set(saved), {'version', 'updated_at', 'rate_limits'})
        self.assertEqual(saved['rate_limits']['five_hour'], {'used_percentage': 24.0, 'resets_at': 1800000000.0})
        self.assertNotIn('secret', path.read_text())
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_missing_rate_limits_does_not_freshen_old_snapshot(self):
        self.bridge.capture({'rate_limits': {'five_hour': {'used_percentage': 4, 'resets_at': 1800000000}}}, self.home)
        path = self.bridge.data_dir(self.home) / 'claude-usage.json'
        before = path.read_text()
        self.assertFalse(self.bridge.capture({'model': {'id': 'x'}}, self.home))
        self.assertEqual(path.read_text(), before)

    def test_empty_limits_record_explicitly_absent_windows(self):
        self.assertTrue(self.bridge.capture({'rate_limits': {}}, self.home))
        saved = json.loads((self.bridge.data_dir(self.home) / 'claude-usage.json').read_text())
        self.assertEqual(saved['rate_limits'], {})

    def test_original_command_receives_original_stdin(self):
        self.write_settings({'statusLine': {'type': 'command', 'command': 'cat'}})
        self.bridge.install(self.home)
        raw = '{"rate_limits": {}, "session_id":"do not persist"}'
        output = self.bridge.run_original(raw, self.home)
        self.assertEqual(output, raw)

    def test_invalid_settings_stays_intact(self):
        self.settings().parent.mkdir()
        self.settings().write_text('{broken')
        with self.assertRaises(ValueError):
            self.bridge.install(self.home)
        self.assertEqual(self.settings().read_text(), '{broken')

    def test_finite_number_validation(self):
        self.bridge.capture({'rate_limits': {'five_hour': {'used_percentage': float('nan'), 'resets_at': 1800000000}}}, self.home)
        saved = json.loads((self.bridge.data_dir(self.home) / 'claude-usage.json').read_text())
        self.assertEqual(saved['rate_limits'], {})

    def test_uninstall_keeps_unrelated_changes(self):
        self.write_settings({'theme': 'light'})
        self.bridge.install(self.home)
        settings = json.loads(self.settings().read_text())
        settings['theme'] = 'dark'
        self.settings().write_text(json.dumps(settings))
        self.bridge.uninstall(self.home)
        self.assertEqual(json.loads(self.settings().read_text()), {'theme': 'dark'})

    def test_installed_command_executes_without_persisting_original_input(self):
        import subprocess
        self.bridge.install(self.home)
        command = json.loads(self.settings().read_text())['statusLine']['command']
        raw = json.dumps({'rate_limits': {'five_hour': {'used_percentage': 24, 'resets_at': 1800000000}}, 'api_key': 'DO_NOT_SAVE'})
        env = dict(os.environ, HOME=str(self.home))
        result = subprocess.run(command, shell=True, input=raw, text=True, capture_output=True, env=env)
        self.assertEqual(result.returncode, 0)
        self.assertIn('76%', result.stdout)
        snapshot = (self.bridge.data_dir(self.home) / 'claude-usage.json').read_text()
        self.assertNotIn('DO_NOT_SAVE', snapshot)

    def test_lost_manifest_does_not_wrap_itself_recursively(self):
        self.bridge.install(self.home)
        state = self.bridge.data_dir(self.home) / 'claude-bridge-state.json'
        state.unlink()
        before = self.settings().read_text()
        with self.assertRaises(ValueError):
            self.bridge.install(self.home)
        self.assertEqual(self.settings().read_text(), before)

if __name__ == '__main__':
    unittest.main()
