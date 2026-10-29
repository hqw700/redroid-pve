#!/bin/bash
# Official runtime bootstrap. Does not create/start containers or download images.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$(id -u)" = 0 ] || { echo 'Run as root on the PVE host' >&2; exit 1; }
command -v pvesm >/dev/null
command -v python3 >/dev/null
# Read the existing local storage configuration instead of replacing its content list.
readarray -t STORAGE < <(python3 - <<'PY'
from pathlib import Path
block = False
settings = {}
for line in Path('/etc/pve/storage.cfg').read_text().splitlines():
    if line and not line[0].isspace():
        block = line.strip() == 'dir: local'
    elif block and line.strip():
        key, _, value = line.strip().partition(' ')
        settings[key] = value.strip()
if not settings.get('path'):
    raise SystemExit('local directory storage is required for the PVE hookscript')
contents = set(filter(None, settings.get('content', '').split(',')))
contents.add('snippets')
print(settings['path'])
print(','.join(sorted(contents)))
PY
)
[ "${#STORAGE[@]}" -eq 2 ] || { echo 'Cannot read local PVE storage configuration' >&2; exit 1; }
pvesm set local --content "${STORAGE[1]}"
install -d "${STORAGE[0]}/snippets" /usr/share/lxc/hooks /usr/local/bin /usr/local/share/redroid-pve
install -m 0755 "${SCRIPT_DIR}/redroid-hook.sh" "${STORAGE[0]}/snippets/redroid-hook.sh"
install -m 0755 "${SCRIPT_DIR}/redroid-pve-hook.sh" /usr/share/lxc/hooks/redroid-pve-hook.sh
install -m 0755 "${SCRIPT_DIR}/pve-create-redroid.sh" /usr/local/bin/pve-create-redroid
install -m 0755 "${SCRIPT_DIR}/pve-configure-redroid.py" /usr/local/bin/pve-configure-redroid
install -m 0644 "${SCRIPT_DIR}/VERSION" /usr/local/share/redroid-pve/VERSION
pve-configure-redroid --version
