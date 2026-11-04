#!/usr/bin/env python3
"""Opt-in live cellular reconnect check; requires mobile data initially enabled.

Usage: python3 tests/cellular_smoke.py SERIAL --output /path/to/evidence
Temporarily toggles mobile data on the selected Android device, restoring it on exit.
"""
import argparse
import json
import subprocess
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('serial')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cycles', type=int, default=3)
    args = parser.parse_args()
    if not 1 <= args.cycles <= 10:
        parser.error('--cycles must be between 1 and 10')
    args.output.mkdir(parents=True, exist_ok=True)

    def shell(command):
        return subprocess.check_output(['adb', '-s', args.serial, 'shell', command],
                                       text=True, timeout=15)

    def wait_state(name, connected):
        deadline = time.monotonic() + 40
        while True:
            state = shell('dumpsys connectivity')
            args.output.joinpath(name + '.txt').write_text(state)
            cellular = [line for line in state.splitlines()
                        if 'NetworkAgentInfo{' in line and 'Transports: CELLULAR' in line]
            ready = any('CONNECTED ' in line and '&VALIDATED' in line
                        and '0.0.0.0/0 ->' in line and 'DnsAddresses: [ /' in line
                        for line in cellular)
            if (connected and ready) or (not connected and not cellular):
                return
            if time.monotonic() >= deadline:
                raise RuntimeError(f'{name}: expected cellular connected={connected}')
            time.sleep(2)

    if shell('settings get global mobile_data').strip() != '1':
        raise RuntimeError('Mobile data must already be enabled; no settings changed')
    wait_state('initial', True)
    completed = 0
    try:
        for cycle in range(1, args.cycles + 1):
            shell('svc data disable')
            wait_state(f'cycle-{cycle}-off', False)
            shell('svc data enable')
            wait_state(f'cycle-{cycle}-on', True)
            completed += 1
    finally:
        shell('svc data enable')
        args.output.joinpath('summary.json').write_text(json.dumps(
            {'serial': args.serial, 'completed_cycles': completed}, indent=2) + '\n')
    print(f'Passed {completed} cellular reconnect cycles')


if __name__ == '__main__':
    main()
