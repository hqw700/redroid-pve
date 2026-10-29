import importlib.util
import subprocess
import tempfile
import unittest
import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('runtime', ROOT / 'deploy/pve-configure-redroid.py')
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


def options(**changes):
    values = dict(vmid=201, gpu_mode='guest', gpu_node='/dev/dri/renderD128', width=720,
                  height=1280, dpi=320, fps=60, output_mode='headless', device_id='', extra_boot_args='')
    values.update(changes)
    return SimpleNamespace(**values)


class RuntimeTests(unittest.TestCase):
    def test_host_check_is_read_only_and_observes_binderfs(self):
        with tempfile.TemporaryDirectory() as directory:
            filesystem = Path(directory) / 'filesystems'
            with patch.object(runtime, 'BINDER_FILESYSTEMS', filesystem), patch.object(runtime.subprocess, 'run') as run:
                filesystem.write_text('nodev\tproc\nnodev\ttmpfs\n')
                self.assertFalse(runtime.host_status()['ready'])
                filesystem.write_text('nodev\tproc\nnodev\tbinder\n')
                self.assertTrue(runtime.host_status()['ready'])
                run.assert_not_called()

    def test_host_preparation_loads_binder_and_preserves_autoload_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            filesystem = Path(directory) / 'filesystems'
            autoload = Path(directory) / 'modules-load.d/redroid-pve.conf'
            autoload.parent.mkdir()
            original = '# Administrator settings\nuinput\n'
            autoload.write_text(original)
            autoload.chmod(0o640)
            filesystem.write_text('nodev\tproc\n')
            def load(command, **kwargs):
                self.assertEqual(command, ['modprobe', 'binder_linux'])
                filesystem.write_text('nodev\tproc\nnodev\tbinder\n')
                return SimpleNamespace(returncode=0, stderr='')
            with patch.object(runtime, 'BINDER_FILESYSTEMS', filesystem), patch.object(runtime, 'BINDER_AUTOLOAD', autoload), \
                    patch.object(runtime.os, 'geteuid', return_value=0), patch.object(runtime.subprocess, 'run', side_effect=load) as run:
                self.assertTrue(runtime.prepare_host()['ready'])
                self.assertEqual(autoload.read_text(), original + 'binder_linux\n')
                modified = autoload.stat().st_mtime_ns
                self.assertTrue(runtime.prepare_host()['autoload_configured'])
                self.assertEqual(autoload.stat().st_mtime_ns, modified)
                self.assertEqual(autoload.stat().st_mode & 0o777, 0o640)
                run.assert_called_once()

    def test_missing_binder_module_or_binderfs_cannot_report_host_ready(self):
        with tempfile.TemporaryDirectory() as directory:
            filesystem = Path(directory) / 'filesystems'
            autoload = Path(directory) / 'redroid-pve.conf'
            filesystem.write_text('nodev\tproc\n')
            for code, message in ((1, 'Cannot load binder_linux'), (0, 'BinderFS is unavailable')):
                with self.subTest(exit=code), patch.object(runtime, 'BINDER_FILESYSTEMS', filesystem), \
                        patch.object(runtime, 'BINDER_AUTOLOAD', autoload), patch.object(runtime.os, 'geteuid', return_value=0), \
                        patch.object(runtime.subprocess, 'run', return_value=SimpleNamespace(returncode=code, stderr='module not found')):
                    with self.assertRaisesRegex(ValueError, message):
                        runtime.prepare_host()
                    self.assertFalse(autoload.exists())

    def test_host_preparation_rejects_non_root_and_mixed_ct_operations(self):
        with patch.object(runtime.os, 'geteuid', return_value=1000), patch.object(runtime.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'requires root'):
                runtime.prepare_host()
            run.assert_not_called()
        for args in (['--check-host', '201'], ['--prepare-host', '--dry-run'], ['--prepare-host', '--check-dhcp']):
            result = subprocess.run(['python3', str(ROOT / 'deploy/pve-configure-redroid.py'), *args], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'cannot be combined', result.stderr)

    def test_dhcp_uses_android_native_lifecycle_and_preserves_snapshots(self):
        original = 'unprivileged: 1\nnet0: name=eth0,bridge=vmbr7,ip=dhcp,host-managed=1,hwaddr=02:00:00:00:00:01,tag=20\n\n[snap_init]\nnet0: name=eth0,ip=192.0.2.10/24,gw=192.0.2.1\n'
        result = runtime.render(original, options())
        settings = runtime.net0_options(result)
        self.assertEqual(settings['ip'], 'dhcp')
        self.assertNotIn('host-managed', settings)
        self.assertIn('androidboot.redroid_net_mode=dhcp', result)
        self.assertEqual(settings['tag'], '20')
        self.assertEqual(settings['hwaddr'], '02:00:00:00:00:01')
        self.assertNotIn('gw', settings)
        self.assertIn('[snap_init]\nnet0: name=eth0,ip=192.0.2.10/24,gw=192.0.2.1', result)
        self.assertEqual(runtime.render(result, options()), result)

    def test_dhcp_rejects_conflicting_gateway_and_unsupported_interface(self):
        for network in ('name=eth0,ip=dhcp,gw=192.0.2.1', 'name=ens18,ip=dhcp'):
            with self.subTest(network=network), self.assertRaises(ValueError):
                runtime.render('net0: ' + network + '\n', options())

    def test_native_dhcp_capability_check_rejects_old_images(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / 'image.tar.zst'
            image.touch()
            with patch.object(runtime.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=b'old ipconfigstore')):
                with self.assertRaisesRegex(ValueError, 'network API 1'):
                    runtime.require_dhcp_support(image)
            with patch.object(runtime.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=b'vendor.redroid.network_api\0ro.boot.redroid_net_mode')):
                self.assertEqual(runtime.require_dhcp_support(image)['provider'], 'android')
        with self.assertRaisesRegex(ValueError, '--template'):
            runtime.require_dhcp_support(None)

    def test_stopped_dhcp_ct_does_not_report_an_old_lease_as_ready(self):
        with patch.object(runtime.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout='0\n')):
            state = runtime.network_status(201, 'net0: name=eth0,ip=dhcp,host-managed=0\n')
        self.assertFalse(state['ready'])
        self.assertFalse(state['running'])
        self.assertEqual(state['ipv4'], [])
        self.assertEqual(state['mode'], 'dhcp')

    def test_static_network_configuration_is_preserved(self):
        original = 'net0: name=eth0,bridge=vmbr0,ip=192.0.2.10/24,gw=192.0.2.1\n'
        self.assertEqual(runtime.configure_network(original), original)
        self.assertNotIn('host-managed', runtime.net0_options(runtime.render(original, options())))

    def test_dhcp_creation_checks_capability_before_allocating_resources(self):
        import os
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            calls = directory / 'calls'
            for name, body in [('pct', 'echo "pct $*" >> "' + str(calls) + '"\n[ "$1" != status ]'),
                               ('pve-configure-redroid', 'echo "configure $*" >> "' + str(calls) + '"\nexit 1')]:
                command = directory / name
                command.write_text('#!/bin/sh\n' + body + '\n')
                command.chmod(0o755)
            image = directory / 'redroid.tar.zst'
            image.touch()
            result = subprocess.run(['bash', str(ROOT / 'deploy/pve-create-redroid.sh'), '202',
                                     'dhcp', '-', '4', '4096', '0', '32', str(image), '1', 'guest', '--no-start'],
                                    env=dict(os.environ, PATH=str(directory) + ':' + os.environ['PATH']), capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('configure --check-dhcp', calls.read_text())
            self.assertNotIn('pct create', calls.read_text())

    def test_dhcp_creation_has_no_static_gateway_or_second_client(self):
        import os
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            calls = directory / 'calls'
            for name, body in [('pct', 'echo "pct $*" >> "' + str(calls) + '"\n[ "$1" != status ]'),
                               ('pve-configure-redroid', 'echo "configure $*" >> "' + str(calls) + '"')]:
                command = directory / name
                command.write_text('#!/bin/sh\n' + body + '\n')
                command.chmod(0o755)
            image = directory / 'redroid.tar.zst'
            image.touch()
            result = subprocess.run(['bash', str(ROOT / 'deploy/pve-create-redroid.sh'), '202',
                                     'dhcp', '-', '4', '4096', '0', '32', str(image), '1', 'guest', '--no-start'],
                                    env=dict(os.environ, PATH=str(directory) + ':' + os.environ['PATH']), capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            command = next(line for line in calls.read_text().splitlines() if line.startswith('pct create'))
            self.assertIn('ip=dhcp', command)
            self.assertNotIn('host-managed', command)
            self.assertNotIn('gw=', command)
            self.assertNotIn('dhclient', calls.read_text())

    def test_device_permissions_preserve_directories_and_regular_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'dri/by-path').mkdir(parents=True, mode=0o755)
            for name in ('kmsg', 'dri/renderD128', 'dri/metadata'):
                (root / name).touch(mode=0o640)
            with patch.object(Path, 'is_char_device', autospec=True,
                              side_effect=lambda path: path.name in ('kmsg', 'renderD128')):
                runtime.prepare_unprivileged_devices(root)
            self.assertEqual((root / 'kmsg').stat().st_mode & 0o777, 0o666)
            self.assertEqual((root / 'dri/renderD128').stat().st_mode & 0o777, 0o666)
            self.assertEqual((root / 'dri/by-path').stat().st_mode & 0o777, 0o755)
            self.assertEqual((root / 'dri/metadata').stat().st_mode & 0o777, 0o640)

    def test_idempotent_profile_preserves_user_mounts_and_snapshots(self):
        original = 'unprivileged: 1\nfeatures: fuse=1\nlxc.mount.entry: /srv/data data/local/user none bind,create=dir 0 0\n\n[snap_init]\nlxc.init.cmd: /init old=1\n'
        result = runtime.render(original, options())
        self.assertEqual(result, runtime.render(result, options()))
        self.assertIn('fuse=1', result)
        self.assertIn('/srv/data data/local/user', result)
        self.assertIn('[snap_init]\nlxc.init.cmd: /init old=1', result)
        self.assertIn('lxc.prlimit.nice: 40', result)
        self.assertIn('/dev/uinput', result)
        self.assertNotIn('/var/lib/cloudphone', result)
        self.assertNotIn('androidboot.redroid_gpu_node=', result)

    def test_mode_matches_existing_ct_and_host_profile(self):
        result = runtime.render('unprivileged: 0\n', options(gpu_mode='host'))
        self.assertIn('androidboot.redroid_gpu_node=/dev/dri/renderD128', result)
        self.assertIn('lxc.cgroup2.devices.allow: a', result)
        self.assertNotIn('lxc.prlimit.nice', result)
        self.assertIn('unprivileged: 0', result)

    def test_rejects_config_injection_and_custom_hook(self):
        for bad in ['foo\nlxc.hook.pre-start: /bin/sh', 'androidboot.test=$(id)', 'androidboot.test=x;id',
                    'androidboot.redroid_net_mode=static', 'ro.boot.redroid_net_mode=dhcp']:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                runtime.render('unprivileged: 1\n', options(extra_boot_args=bad))
        with self.assertRaises(ValueError):
            runtime.render('hookscript: local:snippets/my-hook.sh\n', options())
        with self.assertRaises(ValueError):
            runtime.render('lock: snapshot\n', options())

    def test_existing_vmid_is_never_stopped_or_destroyed(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            log = directory / 'calls'
            pct = directory / 'pct'
            pct.write_text('#!/bin/sh\necho "$*" >> "' + str(log) + '"\nexit 0\n')
            pct.chmod(0o755)
            import os
            env = dict(os.environ, PATH=str(directory) + ':' + os.environ['PATH'])
            result = subprocess.run(['bash', str(ROOT / 'deploy/pve-create-redroid.sh'), '201'], env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(log.read_text().strip(), 'status 201')

    def test_no_start_leaves_lifecycle_to_caller(self):
        import os
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            log = directory / 'calls'
            for name, body in [('pct', 'echo "pct $*" >> "' + str(log) + '"\n[ "$1" != status ]'),
                               ('pve-configure-redroid', 'echo "configure $*" >> "' + str(log) + '"')]:
                command = directory / name
                command.write_text('#!/bin/sh\n' + body + '\n')
                command.chmod(0o755)
            image = directory / 'redroid.tar.zst'
            image.touch()
            env = dict(os.environ, PATH=str(directory) + ':' + os.environ['PATH'])
            result = subprocess.run(['bash', str(ROOT / 'deploy/pve-create-redroid.sh'), '202',
                                     '192.168.1.202/24', '192.168.1.1', '4', '4096', '0', '32', str(image),
                                     '1', 'guest', '--no-start', '--storage', 'my-zfs', '--bridge', 'vmbr7'], env=env, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = log.read_text()
            self.assertIn('pct create 202', calls)
            self.assertIn('--rootfs my-zfs:32', calls)
            self.assertIn('bridge=vmbr7', calls)
            self.assertIn('configure 202 --gpu-mode guest --json', calls)
            self.assertNotIn('pct start', calls)
            self.assertNotIn('pct destroy', calls)

    @unittest.skipUnless(__import__('sys').platform.startswith('linux'), 'PVE installer uses Linux Bash')
    def test_installer_preserves_existing_storage_contents(self):
        import os
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            for source in (ROOT / 'deploy').iterdir():
                if source.is_file():
                    shutil.copy2(source, directory / source.name)
            storage = directory / 'storage.cfg'
            storage.write_text('dir: local\n    path ' + str(directory / 'vz') + '\n    content images,rootdir,iso,vztmpl,backup\n')
            script = (directory / 'install-hooks.sh').read_text().replace('/etc/pve/storage.cfg', str(storage))
            for path in ['/usr/local/bin', '/usr/local/share/redroid-pve', '/usr/share/lxc/hooks']:
                script = script.replace(path, str(directory) + path)
            (directory / 'install-hooks.sh').write_text(script)
            filesystem = directory / 'filesystems'
            filesystem.write_text('nodev\tbinder\n')
            profile = directory / 'pve-configure-redroid.py'
            profile.write_text(profile.read_text().replace('Path("/proc/filesystems")', 'Path(' + repr(str(filesystem)) + ')')
                               .replace('Path("/etc/modules-load.d/redroid-pve.conf")', 'Path(' + repr(str(directory / 'redroid-pve.conf')) + ')')
                               .replace('os.geteuid()', '0'))
            mockbin = directory / 'mockbin'
            mockbin.mkdir()
            for name, content in [('id', 'echo 0'), ('pvesm', 'echo "$*" >> "' + str(directory / 'storage-calls') + '"')]:
                path = mockbin / name
                path.write_text('#!/bin/sh\n' + content + '\n')
                path.chmod(0o755)
            env = dict(os.environ, PATH=str(directory / 'usr/local/bin') + ':' + str(mockbin) + ':' + os.environ['PATH'])
            subprocess.run(['bash', str(directory / 'install-hooks.sh')], env=env, check=True, capture_output=True)
            self.assertIn('backup,images,iso,rootdir,snippets,vztmpl', (directory / 'storage-calls').read_text())
            self.assertTrue((directory / 'vz/snippets/redroid-hook.sh').is_file())

    def test_version_is_machine_readable_and_matches_bundle(self):
        import json
        result = subprocess.check_output(['python3', str(ROOT / 'deploy/pve-configure-redroid.py'), '--version'])
        version = json.loads(result)
        self.assertEqual(version['api'], 1)
        self.assertEqual(version['version'], (ROOT / 'deploy/VERSION').read_text().strip())


if __name__ == '__main__':
    unittest.main()
