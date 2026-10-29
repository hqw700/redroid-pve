#!/usr/bin/env python3
"""Short-lease DHCP/DNS fixture for an isolated PVE acceptance network.

Run only inside the test server's private network namespace. Never attach this
fixture to a production bridge. A sibling `pause` file suppresses DHCP replies
for expiry/recovery tests; DNS continues to answer pve-dhcp.test.
"""
import argparse
import json
import selectors
import socket
import struct
import time
from pathlib import Path


def serve(interface, directory):
    directory = Path(directory)
    events = directory / 'events.jsonl'
    server = socket.inet_aton('192.0.2.1')
    offered = socket.inet_aton('192.0.2.50')
    dhcp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    dhcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    dhcp.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    dhcp.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, interface.encode() + b'\0')
    dhcp.bind(('', 67))
    dns = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    dns.bind(('192.0.2.1', 53))
    selector = selectors.DefaultSelector()
    selector.register(dhcp, selectors.EVENT_READ)
    selector.register(dns, selectors.EVENT_READ)
    with events.open('a', buffering=1) as log:
        while True:
            for event, _ in selector.select(timeout=1):
                sock = event.fileobj
                data, peer = sock.recvfrom(4096)
                if sock is dns:
                    # The test zone resolves to the isolated gateway, with no upstream DNS.
                    end = 12
                    while end < len(data) and data[end]:
                        end += data[end] + 1
                    end += 5
                    if end > len(data):
                        continue
                    ipv4_question = struct.unpack('!H', data[end - 4:end - 2])[0] == 1
                    reply = data[:2] + struct.pack('!HHHHH', 0x8180, 1, int(ipv4_question), 0, 0) + data[12:end]
                    if ipv4_question:
                        reply += b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 1, 4) + server
                    sock.sendto(reply, peer)
                    log.write(json.dumps({'time': time.time(), 'type': 'DNS', 'peer': peer[0]}) + '\n')
                    continue
                if len(data) < 240 or data[236:240] != b'\x63\x82\x53\x63':
                    continue
                options, pos = {}, 240
                while pos < len(data):
                    code = data[pos]
                    pos += 1
                    if code == 255:
                        break
                    if code == 0:
                        continue
                    if pos >= len(data):
                        break
                    length = data[pos]
                    pos += 1
                    options[code] = data[pos:pos + length]
                    pos += length
                message = options.get(53, b'\0')[0]
                paused = (directory / 'pause').exists()
                log.write(json.dumps({'time': time.time(), 'type': message, 'client_ip': socket.inet_ntoa(data[12:16]),
                                      'peer': peer[0], 'paused': paused, 'mac': data[28:34].hex(':')}) + '\n')
                if paused or message not in (1, 3):
                    continue
                header = bytearray(data[:236])
                header[0] = 2
                header[16:20] = offered
                header[20:24] = server
                def option(code, value):
                    return bytes([code, len(value)]) + value
                reply = bytes(header) + b'\x63\x82\x53\x63'
                reply += option(53, bytes([2 if message == 1 else 5]))
                reply += option(54, server) + option(1, socket.inet_aton('255.255.255.0'))
                reply += option(3, server) + option(6, server)
                # Android clamps leases to at least 60 seconds; shorter leases
                # make server/client expiry expectations disagree.
                reply += option(51, struct.pack('!I', 60)) + option(58, struct.pack('!I', 30)) + option(59, struct.pack('!I', 52))
                reply += b'\xff'
                # Renewing clients listen on their existing address; initial
                # clients have no address yet and need a broadcast response.
                destination = socket.inet_ntoa(data[12:16]) if data[12:16] != b'\0' * 4 else '255.255.255.255'
                sock.sendto(reply, (destination, 68))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('interface')
    parser.add_argument('directory')
    args = parser.parse_args()
    serve(args.interface, args.directory)
