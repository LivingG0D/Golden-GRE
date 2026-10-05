#!/usr/bin/env python3
"""tbrelay: carry a local UDP tunnel (WireGuard, FOU) over a protocol facade a filtered IPv4 path lets through.

  tbrelay.py --facade dns|icmp --bind <public_ip> --peer <peer_ip> --local <ip:port> [--port 53] [--itype 0]

The tunnel endpoint sends its UDP packets to --local. Each one is wrapped and sent to the peer's relay,
which unwraps it and hands it to its own local tunnel endpoint. Replies from the endpoint go back the
same way (the sender address of the last local packet is the reply address).

Facades (the path cuts any other flow after about 6 packets, see bench/filter.sh):
  dns   UDP from an ephemeral port to <peer>:53, framed as a DNS query with one question and an EDNS0 OPT
        record whose RDATA is the payload. Listens on <bind>:53.
  icmp  ICMP messages of --itype (0 = unsolicited echo reply, so no kernel answers it) between the two
        hosts, payload after the 8-byte ICMP header. Needs root (raw socket).
"""
import argparse
import socket
import struct
import sys
import threading
import time

QUESTION = b"\x05probe\x04test\x00" + struct.pack("!HH", 16, 1)  # TXT IN
DNS_OVERHEAD = 12 + len(QUESTION) + 11  # header + question + OPT record header
IDENT = 0x7462


def checksum(b):
    if len(b) % 2:
        b += b"\0"
    t = sum(struct.unpack("!%dH" % (len(b) // 2), b))
    t = (t >> 16) + (t & 0xFFFF)
    t += t >> 16
    return ~t & 0xFFFF


def dns_wrap(n, payload):
    return (struct.pack("!HHHHHH", n & 0xFFFF, 0x0100, 1, 0, 0, 1) + QUESTION
            + b"\x00" + struct.pack("!HHIH", 41, 4096, 0, len(payload)) + payload)


def dns_unwrap(frame):
    if len(frame) <= DNS_OVERHEAD or frame[12:12 + len(QUESTION)] != QUESTION:
        return None
    return frame[DNS_OVERHEAD:]


def icmp_wrap(itype, n, payload):
    body = struct.pack("!BBHHH", itype, 0, 0, IDENT, n & 0xFFFF) + payload
    return body[:2] + struct.pack("!H", checksum(body)) + body[4:]


def icmp_unwrap(frame, itype):
    m = frame[(frame[0] & 15) * 4:]  # raw sockets include the IP header
    if len(m) <= 8 or m[0] != itype or struct.unpack("!H", m[4:6])[0] != IDENT:
        return None
    return m[8:]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--facade", choices=("dns", "icmp"), required=True)
    ap.add_argument("--bind", required=True, help="this host's public IPv4 address")
    ap.add_argument("--peer", required=True, help="the other host's public IPv4 address")
    ap.add_argument("--local", required=True, help="ip:port the local tunnel endpoint sends to")
    ap.add_argument("--port", type=int, default=53, help="dns facade: UDP port on both hosts")
    ap.add_argument("--itype", type=int, default=0, help="icmp facade: ICMP type")
    a = ap.parse_args()

    lhost, lport = a.local.rsplit(":", 1)
    loc = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    loc.bind((lhost, int(lport)))
    if a.facade == "dns":
        rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        rx.bind((a.bind, a.port))
        tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        tx.bind((a.bind, 0))
        dst = (a.peer, a.port)
    else:
        rx = tx = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
        rx.bind((a.bind, 0))
        dst = (a.peer, 0)
    for s in (loc, rx, tx):
        for opt in (socket.SO_RCVBUF, socket.SO_SNDBUF):
            s.setsockopt(socket.SOL_SOCKET, opt, 4 << 20)

    state = {"reply": None, "tx": 0, "rx": 0, "bad": 0}

    def to_wire():
        n = 0
        while True:
            d, addr = loc.recvfrom(65535)
            state["reply"] = addr
            n += 1
            tx.sendto(dns_wrap(n, d) if a.facade == "dns" else icmp_wrap(a.itype, n, d), dst)
            state["tx"] += 1

    def from_wire():
        while True:
            d, addr = rx.recvfrom(65535)
            if addr[0] != a.peer:
                continue
            p = dns_unwrap(d) if a.facade == "dns" else icmp_unwrap(d, a.itype)
            if p is None:
                state["bad"] += 1
            elif state["reply"]:
                loc.sendto(p, state["reply"])
                state["rx"] += 1

    for fn in (to_wire, from_wire):
        threading.Thread(target=fn, daemon=True).start()
    print("tbrelay up: %s %s <-> %s, local %s" % (a.facade, a.bind, a.peer, a.local), flush=True)
    while True:
        time.sleep(10)
        print("tx=%d rx=%d bad=%d" % (state["tx"], state["rx"], state["bad"]), flush=True)


if __name__ == "__main__":
    sys.exit(main())
