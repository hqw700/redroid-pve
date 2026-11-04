#!/usr/bin/env python3
"""Official ReDroid/PVE runtime profile, shared by native PVE and external controllers.

Only a stopped container's current configuration is changed. Snapshots and unrelated
mounts are preserved. No container is created, started, stopped or destroyed here.
"""
import argparse
import ipaddress
import json
import os
import re
import shlex
import subprocess
import time
from pathlib import Path

API_VERSION = 1
RUNTIME_VERSION = "1.2.0"
BINDER_FILESYSTEMS = Path("/proc/filesystems")
BINDER_AUTOLOAD = Path("/etc/modules-load.d/redroid-pve.conf")
SUBUID_PATH = Path("/etc/subuid")
SUBGID_PATH = Path("/etc/subgid")
BEGIN = "# BEGIN redroid-pve runtime"
END = "# END redroid-pve runtime"
HOOK = "/usr/share/lxc/hooks/redroid-pve-hook.sh"
BOOT_TOKEN = re.compile(r"(?:androidboot|ro\.boot)\.[A-Za-z0-9_.-]+=[A-Za-z0-9_./,:+@%=-]+\Z")


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("vmid", nargs="?", type=int)
    parser.add_argument("--version", action="store_true")
    parser.add_argument("--json", action="store_true", help="machine-readable result")
    parser.add_argument("--dry-run", action="store_true", help="render without writing")
    host = parser.add_mutually_exclusive_group()
    host.add_argument("--check-host", action="store_true", help="read host BinderFS readiness without loading modules or changing files")
    host.add_argument("--prepare-host", action="store_true", help="load the host BinderFS driver and enable loading at boot; no CT changes")
    parser.add_argument("--check-dhcp", action="store_true", help="check a template's native Android DHCP support without changing a CT")
    parser.add_argument("--template", type=Path, help="PVE .tar.zst template to check with --check-dhcp")
    parser.add_argument("--no-cache", action="store_true", help="bypass cached image capability results")
    parser.add_argument("--network-status", action="store_true", help="read actual IPv4 addresses/routes from the running CT; no configuration changes")
    parser.add_argument("--wait-network", type=int, default=0, metavar="SECONDS", help="wait up to 120 seconds for an actual IPv4 address (with --network-status)")
    parser.add_argument("--cellular-iface", default="rmnet0", help="name of the cellular network interface (default: rmnet0)")
    parser.add_argument("--cellular-dns", default="", help="DNS servers for cellular network, space-separated")
    parser.add_argument("--gpu-mode", choices=("host", "guest"), default="host")
    parser.add_argument("--gpu-node", default="/dev/dri/renderD128")
    for name, default, maximum in (("width", 1080, 16384), ("height", 1920, 16384), ("dpi", 320, 2000), ("fps", 60, 240)):
        parser.add_argument("--" + name, type=int, default=default)
    parser.add_argument("--output-mode", choices=("headless", "hdmi"), default="headless")
    parser.add_argument("--device-id", default="")
    parser.add_argument("--extra-boot-args", default="")
    return parser, parser.parse_args(argv)


def check_subid_mapping(path):
    if not path.is_file():
        return False
    for line in path.read_text().splitlines():
        parts = line.strip().split(':')
        if len(parts) >= 3 and parts[0] == 'root':
            try:
                if int(parts[2]) >= 1000000:
                    return True
            except ValueError:
                pass
    return False


def prepare_subid_mapping(path):
    if not path.parent.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
    content = path.read_text() if path.is_file() else ''
    lines = [l for l in content.splitlines() if not l.startswith('root:')]
    lines.append('root:100000:1000000')
    path.write_text('\n'.join(lines) + '\n')


def host_status():
    binderfs = any(line.split()[-1:] == ['binder'] for line in BINDER_FILESYSTEMS.read_text().splitlines())
    return {'api': API_VERSION, 'version': RUNTIME_VERSION, 'kernel': os.uname().release,
            'ready': binderfs, 'binderfs': binderfs,
            'subuid': check_subid_mapping(SUBUID_PATH),
            'subgid': check_subid_mapping(SUBGID_PATH),
            'details': '' if binderfs else 'BinderFS is unavailable; run pve-configure-redroid --prepare-host on the PVE host'}


def prepare_host():
    if os.geteuid() != 0:
        raise ValueError('--prepare-host requires root on the PVE host')
    state = host_status()
    if not state['ready']:
        result = subprocess.run(['modprobe', 'binder_linux'], capture_output=True, text=True, timeout=15)
        if result.returncode:
            raise ValueError(f"Cannot load binder_linux for kernel {state['kernel']}: {result.stderr.strip()}; install matching kernel modules with CONFIG_ANDROID_BINDER_IPC and CONFIG_ANDROID_BINDERFS")
        state = host_status()
        if not state['ready']:
            raise ValueError('binder_linux loaded but BinderFS is unavailable; the host kernel must enable CONFIG_ANDROID_BINDERFS')
    # Preserve any existing administrator settings; write only when adding the module.
    text = BINDER_AUTOLOAD.read_text() if BINDER_AUTOLOAD.exists() else '# ReDroid BinderFS support\n'
    modules = [line.split('#', 1)[0].strip() for line in text.splitlines()]
    if 'binder_linux' not in modules:
        BINDER_AUTOLOAD.parent.mkdir(parents=True, exist_ok=True)
        BINDER_AUTOLOAD.write_text(text + ('' if text.endswith('\n') else '\n') + 'binder_linux\n')
    state['autoload_configured'] = True
    try:
        if not check_subid_mapping(SUBUID_PATH):
            prepare_subid_mapping(SUBUID_PATH)
        if not check_subid_mapping(SUBGID_PATH):
            prepare_subid_mapping(SUBGID_PATH)
        state['subuid'] = True
        state['subgid'] = True
    except OSError:
        state['subuid'] = check_subid_mapping(SUBUID_PATH)
        state['subgid'] = check_subid_mapping(SUBGID_PATH)
    return state


def validate(args):
    if not args.vmid or not 100 <= args.vmid <= 999999999:
        raise ValueError("VMID must be between 100 and 999999999")
    for name, maximum in (("width", 16384), ("height", 16384), ("dpi", 2000), ("fps", 240)):
        if not 1 <= getattr(args, name) <= maximum:
            raise ValueError(f"invalid {name}: expected 1..{maximum}")
    if not re.fullmatch(r"/dev/dri/renderD[0-9]+", args.gpu_node):
        raise ValueError("GPU node must be /dev/dri/renderD<number>")
    if args.device_id and not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", args.device_id):
        raise ValueError("invalid device ID")
    if any(c in args.extra_boot_args for c in "\r\n\x00"):
        raise ValueError("boot arguments cannot contain control characters")
    tokens = shlex.split(args.extra_boot_args)
    if any(not BOOT_TOKEN.fullmatch(token) for token in tokens):
        raise ValueError("extra boot arguments must be androidboot.*=value or ro.boot.*=value tokens")
    if getattr(args, 'cellular_dns', ''):
        for server in args.cellular_dns.split():
            try:
                ipaddress.IPv4Address(server)
            except ValueError:
                raise ValueError(f"invalid cellular DNS: {server}")
    return tokens


def split_current(text):
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if line.strip().startswith("["):
            return lines[:index], lines[index:]
    return lines, []


def parse_network_options(text):
    current, _ = split_current(text)
    networks = {}
    for line in current:
        line = line.strip()
        m = re.match(r"^net(\d+):\s*(.*)$", line)
        if m:
            idx = int(m.group(1))
            parts = dict(part.split('=', 1) for part in m.group(2).split(',') if '=' in part)
            networks[idx] = parts
    return networks


def cellular_options(text, cellular_iface="rmnet0"):
    networks = parse_network_options(text)
    for idx, opts in networks.items():
        if opts.get('name') == cellular_iface:
            return idx, opts
    for idx, opts in networks.items():
        if idx > 0 and (cellular_iface in opts.get('name', '') or opts.get('name', '').startswith('rmnet')):
            return idx, opts
    return None, None


def net0_options(text):
    current, _ = split_current(text)
    line = next((line.split(':', 1)[1].strip() for line in current if line.startswith('net0:')), '')
    return dict(part.split('=', 1) for part in line.split(',') if '=' in part)


DHCP_CACHE_FILE = Path('/var/cache/redroid-pve/template_dhcp_cache.json')
FALLBACK_CACHE_FILE = Path('/tmp/.redroid_dhcp_cache.json')


def _get_dhcp_cache_file():
    try:
        DHCP_CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
        return DHCP_CACHE_FILE
    except Exception:
        return FALLBACK_CACHE_FILE


def _load_dhcp_cache(cache_file=None):
    target = cache_file or _get_dhcp_cache_file()
    try:
        if target.is_file():
            return json.loads(target.read_text())
    except Exception:
        pass
    return {}


def _save_dhcp_cache(cache, cache_file=None):
    target = cache_file or _get_dhcp_cache_file()
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(cache, indent=2))
    except Exception:
        pass


def require_dhcp_support(template, use_cache=True, cache_file=None):
    if not template or not template.is_file():
        raise ValueError('--check-dhcp requires --template PATH to an existing .tar.zst image')

    resolved = template.resolve()
    st = None
    key = str(resolved)
    if use_cache:
        try:
            st = resolved.stat()
            cache = _load_dhcp_cache(cache_file)
            entry = cache.get(key)
            if entry and entry.get('size') == st.st_size and entry.get('mtime_ns') == st.st_mtime_ns:
                if entry.get('dhcp4') and entry.get('image_network_api', 0) >= 1:
                    return {'dhcp4': True, 'provider': 'android', 'image_network_api': 1, 'cached': True}
        except Exception:
            pass

    # Check the actual image rather than assuming newer host scripts can repair
    # an old ipconfigstore binary. Read only this member; never extract the image.
    probe = subprocess.run(['tar', '--zstd', '--wildcards', '--occurrence=1', '-xOf', str(template),
                            '*vendor/bin/ipconfigstore'], capture_output=True, timeout=60)
    if probe.returncode or not all(marker in probe.stdout for marker in
                                  (b'vendor.redroid.network_api', b'ro.boot.redroid_net_mode')):
        raise ValueError('DHCP requires a redroid-pve image with network API 1 (patches 0007 and 0008); update the image or use a static IPv4 address')

    if use_cache:
        try:
            if st is None:
                st = resolved.stat()
            cache = _load_dhcp_cache(cache_file)
            cache[key] = {
                'size': st.st_size,
                'mtime_ns': st.st_mtime_ns,
                'dhcp4': True,
                'provider': 'android',
                'image_network_api': 1,
                'checked_at': int(time.time()),
            }
            _save_dhcp_cache(cache, cache_file)
        except Exception:
            pass

    return {'dhcp4': True, 'provider': 'android', 'image_network_api': 1}


def configure_network(text, args=None):
    settings = net0_options(text)
    if settings.get('ip') == 'dhcp':
        if settings.get('name') != 'eth0':
            raise ValueError('ReDroid DHCP currently requires net0 name=eth0')
        if settings.get('gw'):
            raise ValueError('DHCP obtains its gateway from the DHCP server; remove the static net0 gw setting')
        # Exactly one DHCP owner: Android's IpClient owns leases, DNS and routes.
        settings.pop('host-managed', None)
        current, snapshots = split_current(text)
        current = ['net0: ' + ','.join(f'{key}={value}' for key, value in settings.items())
                   if line.startswith('net0:') else line for line in current]
        text = '\n'.join(current + ([''] + snapshots if snapshots else [])) + '\n'

    # Validate cellular configuration if present
    cell_iface = getattr(args, 'cellular_iface', 'rmnet0') if args else 'rmnet0'
    cell_idx, cell_opts = cellular_options(text, cell_iface)
    if cell_opts:
        cell_ip = cell_opts.get('ip', '')
        if cell_ip == 'dhcp':
            raise ValueError(f"Cellular interface ({cell_iface}) does not support DHCP yet; static IPv4 is required")
        if cell_ip and cell_ip != 'manual':
            try:
                ipaddress.IPv4Interface(cell_ip)
            except ValueError:
                raise ValueError(f"invalid cellular IP: {cell_ip}")
        cell_gw = cell_opts.get('gw', '')
        if cell_gw:
            try:
                ipaddress.IPv4Address(cell_gw)
            except ValueError:
                raise ValueError(f"invalid cellular gateway: {cell_gw}")
    return text


def network_status(vmid, text, cellular_iface="rmnet0"):
    settings = net0_options(text)
    configured = settings.get('ip', 'manual')
    result = {'vmid': vmid, 'mode': 'dhcp' if configured == 'dhcp' else 'static' if '/' in configured else 'manual',
              'provider': 'android' if configured == 'dhcp' else 'redroid-hook',
              'running': False, 'ready': False, 'ipv4': [], 'gateway': '', 'dns': []}
    cell_idx, cell_opts = cellular_options(text, cellular_iface)
    result['ethernet'] = {'interface': settings.get('name', 'eth0'),
                          'mode': result['mode'], 'ready': False, 'ipv4': [], 'gateway': '', 'dns': []}
    result['cellular'] = {'interface': cellular_iface, 'configured': bool(cell_opts),
                          'ready': False, 'ipv4': [], 'gateway': '', 'dns': []}
    pid_result = subprocess.run(['lxc-info', '-n', str(vmid), '-p', '-H'], capture_output=True, text=True, timeout=5)
    pid = pid_result.stdout.strip()
    if pid_result.returncode or not pid.isdigit() or int(pid) <= 1:
        return result
    # Avoid reporting or querying the host namespace if a stale PID is observed.
    namespace = Path(f'/proc/{pid}/ns/net')
    if not namespace.exists() or namespace.stat().st_ino == Path('/proc/self/ns/net').stat().st_ino:
        return result
    result['running'] = True
    def query(*args):
        response = subprocess.run(['nsenter', '-t', pid, '-n', '--', 'ip', '-j', '-4', *args],
                                  check=True, capture_output=True, text=True, timeout=5)
        return json.loads(response.stdout)
    try:
        for interface in query('addr', 'show', 'dev', settings.get('name', 'eth0'), 'scope', 'global'):
            for addr in interface.get('addr_info', []):
                address = ipaddress.ip_address(addr['local'])
                if address.version == 4 and not address.is_link_local and not address.is_loopback and not address.is_unspecified:
                    result['ipv4'].append(f"{address}/{addr['prefixlen']}")
        routes = query('route', 'show', 'table', 'all', 'default', 'dev', settings.get('name', 'eth0'))
        result['gateway'] = next((route['gateway'] for route in routes if route.get('gateway')), '')
    except Exception:
        pass
    result['ethernet']['ipv4'] = list(result['ipv4'])
    result['ethernet']['gateway'] = result['gateway']
    if configured == 'dhcp':
        try:
            response = subprocess.run(['pct', 'exec', str(vmid), '--', '/system/bin/dumpsys', 'ethernet'],
                                      capture_output=True, text=True, timeout=5).stdout
        except subprocess.TimeoutExpired:
            response = ''  # Android services may still be starting; IP inspection remains useful.
        for group in re.findall(r'DnsAddresses:\s*\[([^\]]*)\]', response):
            for address in group.replace(',', ' ').split():
                try:
                    parsed = str(ipaddress.ip_address(address.lstrip('/')))
                    if parsed not in result['dns']:
                        result['dns'].append(parsed)
                except ValueError:
                    pass
    result['ethernet']['dns'] = list(result['dns'])
    result['ready'] = bool(result['ipv4'])
    result['ethernet']['ready'] = result['ready']

    if cell_opts:
        try:
            for interface in query('addr', 'show', 'dev', cellular_iface, 'scope', 'global'):
                for addr in interface.get('addr_info', []):
                    address = ipaddress.ip_address(addr['local'])
                    if address.version == 4 and not address.is_link_local and not address.is_loopback and not address.is_unspecified:
                        result['cellular']['ipv4'].append(f"{address}/{addr['prefixlen']}")
            cell_routes = query('route', 'show', 'table', '101', 'default', 'dev', cellular_iface)
            result['cellular']['gateway'] = next((route['gateway'] for route in cell_routes if route.get('gateway')), '')
            result['cellular']['ready'] = bool(result['cellular']['ipv4'])
        except Exception:
            pass
    return result


def prepare_unprivileged_devices(device_root=Path("/dev")):
    # /dev/dri also contains directories (by-path); preserve their search bits.
    for device in (device_root / "kmsg", *(device_root / "dri").glob("*")):
        if device.is_char_device():
            device.chmod(0o666)


def profile(args, unprivileged, extra):
    boot = ["/init", "androidboot.hardware=redroid", f"androidboot.redroid_gpu_mode={args.gpu_mode}",
            f"androidboot.redroid_width={args.width}", f"androidboot.redroid_height={args.height}",
            f"androidboot.redroid_dpi={args.dpi}", f"ro.boot.redroid_fps={args.fps}"]
    if args.gpu_mode == "host":
        boot.append("androidboot.redroid_gpu_node=" + args.gpu_node)
    if args.output_mode == "hdmi":
        boot.append("androidboot.redroid_display_mode=drm")
    if args.device_id:
        boot.append("androidboot.device_id=" + args.device_id)
    boot.extend(extra)
    lines = [BEGIN, "cmode: shell", "hookscript: local:snippets/redroid-hook.sh",
             "lxc.apparmor.profile: unconfined", "lxc.cap.drop:", "lxc.cap.drop: sys_boot",
             "lxc.mount.auto: proc:rw sys:mixed cgroup:rw", "lxc.hook.mount: " + HOOK,
             "lxc.init.cmd: " + " ".join(boot), "lxc.autodev: 0",
             "lxc.mount.entry: tmpfs dev tmpfs create=dir,rw,nosuid,size=134217728,mode=755 0 0"]
    if unprivileged:
        lines += ["lxc.prlimit.nice: 40",
                  "lxc.idmap: u 0 100000 1000000",
                  "lxc.idmap: g 0 100000 1000000"]
        for major in (1, 5, 10, 226, 248):
            lines.append(f"lxc.cgroup2.devices.allow: c {major}:* rwm")
        for device in ("null", "zero", "random", "urandom", "tty", "kmsg", "uinput"):
            optional = "optional," if device == "uinput" else ""
            lines.append(f"lxc.mount.entry: /dev/{device} dev/{device} none bind,{optional}create=file 0 0")
    else:
        lines.append("lxc.cgroup2.devices.allow: a")
        for device in ("fuse", "loop-control", *(f"loop{i}" for i in range(8))):
            lines.append(f"lxc.mount.entry: /dev/{device} dev/{device} none bind,optional,create=file 0 0")
    if args.gpu_mode == "host":
        for device in ("dri", "dma_heap"):
            optional = "optional," if device == "dma_heap" else ""
            lines.append(f"lxc.mount.entry: /dev/{device} dev/{device} none bind,{optional}create=dir 0 0")
    lines.append(END)
    return lines


def render(text, args):
    extra = validate(args)
    text = configure_network(text, args)
    current, snapshots = split_current(text)
    unprivileged = any(re.fullmatch(r"unprivileged:\s*1", line.strip()) for line in current)
    if any(line.strip().startswith("lock:") for line in current):
        raise ValueError("container configuration is locked")
    filtered, inside = [], False
    managed_keys = ("cmode:", "lxc.init.cmd:", "lxc.apparmor.profile:", "lxc.cgroup2.devices.allow:",
                    "lxc.cap.drop:", "lxc.mount.auto:", "lxc.autodev:", "lxc.prlimit.nice:", "lxc.idmap:")
    # Migrate known legacy profile mounts only; never discard third-party/Agent mounts.
    sources = {"tmpfs", "/dev/dri", "/dev/dma_heap", "/dev/fuse", "/dev/loop-control", "/dev/uinput",
               "/dev/null", "/dev/zero", "/dev/random", "/dev/urandom", "/dev/tty", "/dev/kmsg"}
    sources.update(f"/dev/loop{i}" for i in range(8))
    for line in current:
        value = line.strip()
        if value == BEGIN:
            if inside:
                raise ValueError("nested runtime markers")
            inside = True
            continue
        if value == END:
            if not inside:
                raise ValueError("unmatched runtime marker")
            inside = False
            continue
        if inside:
            continue
        if value.startswith("hookscript:"):
            if value.split(":", 1)[1].strip() != "local:snippets/redroid-hook.sh":
                raise ValueError("custom PVE hookscript detected; configure hook chaining before applying the profile")
            continue
        if value.startswith("lxc.hook.mount:") and value.split(":", 1)[1].strip() == HOOK:
            continue
        if value.startswith(managed_keys):
            continue
        if value.startswith("lxc.mount.entry:"):
            fields = value.split(":", 1)[1].split()
            if fields and fields[0] in sources:
                continue
        if value.startswith("features:"):
            features = dict(item.partition("=")[::2] for item in value.split(":", 1)[1].strip().split(",") if item)
            features.update(nesting="1", mknod="1")
            line = "features: " + ",".join(f"{key}={val}" for key, val in sorted(features.items()))
        filtered.append(line)
    if inside:
        raise ValueError("unterminated runtime marker")
    if not any(line.strip().startswith("features:") for line in filtered):
        filtered.append("features: mknod=1,nesting=1")
    while filtered and not filtered[-1].strip():
        filtered.pop()
    if any(token.startswith(('androidboot.redroid_net_mode=', 'ro.boot.redroid_net_mode=')) for token in extra):
        raise ValueError('redroid_net_mode is derived from net0; do not override it with extra boot arguments')
    mode = 'dhcp' if net0_options(text).get('ip') == 'dhcp' else 'static'
    extra.append('androidboot.redroid_net_mode=' + mode)
    cell_idx, cell_opts = cellular_options(text, getattr(args, 'cellular_iface', 'rmnet0'))
    if cell_opts:
        extra.append(f"ro.boot.radio_ifname={getattr(args, 'cellular_iface', 'rmnet0')}")
        if getattr(args, 'cellular_dns', ''):
            extra.append(f"ro.boot.radio_dns={args.cellular_dns}")
    return "\n".join(filtered + profile(args, unprivileged, extra) + ([""] + snapshots if snapshots else [])) + "\n"


def main():
    parser, args = arguments()
    if args.version:
        print(json.dumps({"api": API_VERSION, "version": RUNTIME_VERSION}))
        return
    if args.check_host or args.prepare_host:
        if args.vmid is not None or args.dry_run or args.check_dhcp or args.network_status or args.wait_network:
            raise ValueError('host checks/preparation cannot be combined with CT, image or dry-run operations')
        print(json.dumps(prepare_host() if args.prepare_host else host_status()))
        return
    if args.check_dhcp:
        print(json.dumps({'api': API_VERSION, 'version': RUNTIME_VERSION, **require_dhcp_support(args.template, use_cache=not args.no_cache)}))
        return
    validate(args)
    path = Path(f"/etc/pve/lxc/{args.vmid}.conf")
    if args.network_status:
        if not 0 <= args.wait_network <= 120:
            raise ValueError('--wait-network must be between 0 and 120 seconds')
        deadline = time.monotonic() + args.wait_network
        while True:
            state = network_status(args.vmid, path.read_text(), args.cellular_iface)
            if state['ready'] or time.monotonic() >= deadline:
                print(json.dumps(state))
                if args.wait_network and not state['ready']:
                    raise ValueError('IPv4 acquisition timed out; inspect the DHCP server/VLAN and PVE task log; no static fallback was assigned')
                return
            time.sleep(1)
    if args.wait_network:
        raise ValueError('--wait-network requires --network-status')
    status = subprocess.run(["pct", "status", str(args.vmid)], check=True, capture_output=True, text=True).stdout.strip()
    if status != "status: stopped":
        raise ValueError("container must be stopped before applying runtime configuration")
    if not args.dry_run:
        for required in (Path(HOOK), Path("/usr/local/share/redroid-pve/VERSION")):
            if not required.is_file():
                raise ValueError("runtime is not installed; run deploy/install-hooks.sh first")
        if args.gpu_mode == "host" and not Path(args.gpu_node).exists():
            raise ValueError(f"GPU node {args.gpu_node} does not exist; use --gpu-mode guest for software rendering")
    original = path.read_text()
    updated = render(original, args)
    changed = original != updated
    if changed and not args.dry_run:
        # pmxcfs does not support normal filesystem atomic rename semantics.
        path.write_text(updated)
        if "unprivileged: 1" in original:
            prepare_unprivileged_devices()
    result = {"api": API_VERSION, "version": RUNTIME_VERSION, "vmid": args.vmid, "changed": changed, "started": False}
    if args.dry_run:
        result["config"] = updated
    print(json.dumps(result) if args.json or args.dry_run else f"CT {args.vmid}: runtime configured (changed={changed}); container remains stopped")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        import sys
        print(f"redroid-pve: {exc}", file=sys.stderr)
        sys.exit(1)
