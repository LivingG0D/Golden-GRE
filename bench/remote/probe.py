#!/usr/bin/env python3
"""Carrier probe: counts packets crossing the path over one IPv4 carrier. No TCP between the hosts.

  probe.py recv <carrier> <bind_ip> <port> <secs> [key=val ...]
  probe.py send <carrier> <src_ip> <dst_ip> <port> <size> <mbit> <secs> [key=val ...]

carrier is "udp", "icmp" (echo requests; the peer kernel answers, so replies are counted as echoes)
or an IP protocol number (4, 41, 47, 50, ...; raw sockets, needs root).
Options (udp only unless noted):
  echo=1     receiver sends every packet back (64-byte reply), sender counts them
  hop=N      sender moves to a new source port every N packets
  stall=N:T  sender sleeps T seconds after every N packets (flow idle/expiry tests)
  count=K    sender stops after K packets
  sport=N    sender binds source port N
  dns=q|r    sender dresses each packet as a DNS query / TXT response
  itype=T    ICMP type to send (8 echo request, 0 unsolicited echo reply)
Prints one line:
  RX n=<packets> ooo=<out-of-order packets> persec=<n,n,...>   (recv)
  TX n=<packets> errors=<n> echoes=<n>                         (send)
persec counts received packets per second from the first packet, so a mid-test cutoff shows as zeros.
"""
import select
import socket
import struct
import sys
import time

MAGIC = 0x74626E63
MAGIC_B = struct.pack("!I", MAGIC)


def checksum(b):
    if len(b) % 2:
        b += b"\0"
    t = sum(struct.unpack("!%dH" % (len(b) // 2), b))
    t = (t >> 16) + (t & 0xFFFF)
    t += t >> 16
    return ~t & 0xFFFF


def find_seq(d):
    """Sequence number of one of our packets, wherever its payload starts in the first 64 bytes."""
    i = d.find(MAGIC_B, 0, 64)
    if i < 0 or len(d) < i + 8:
        return None
    return struct.unpack("!I", d[i + 4:i + 8])[0]


def icmp_payload(d):
    """ICMP message (IP header stripped) if it carries one of our packets, else None."""
    d = d[(d[0] & 15) * 4:]
    if len(d) < 12 or d[0] not in (0, 8) or find_seq(d) is None:
        return None
    return d


def dns_wrap(kind, n, pad):
    """A syntactically valid DNS query (q) or TXT response (r) that carries our packet."""
    body = struct.pack("!II", MAGIC, n) + pad
    question = b"\x05probe\x04test\x00" + struct.pack("!HH", 16, 1)
    if kind == "q":
        opt = b"\x00" + struct.pack("!HHIH", 41, 4096, 0, len(body)) + body  # EDNS0 OPT record
        return struct.pack("!HHHHHH", n & 0xFFFF, 0x0100, 1, 0, 0, 1) + question + opt
    rdata = b"".join(bytes([len(c)]) + c for c in (body[i:i + 255] for i in range(0, len(body), 255)))
    answer = b"\xc0\x0c" + struct.pack("!HHIH", 16, 1, 60, len(rdata)) + rdata
    return struct.pack("!HHHHHH", n & 0xFFFF, 0x8180, 1, 1, 0, 0) + question + answer


def open_sock(carrier, ip, port, send, sport=0):
    if carrier == "icmp":
        s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
        s.bind((ip, 0))
    elif carrier == "udp":
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind((ip, sport if send else port))
    else:
        s = socket.socket(socket.AF_INET, socket.SOCK_RAW, int(carrier))
        s.bind((ip, 0))
    return s


def recv(carrier, ip, port, secs, opt):
    s = open_sock(carrier, ip, port, False)
    s.settimeout(0.5)
    end = time.time() + secs
    first = None
    per = {}
    n = ooo = top = 0
    while time.time() < end:
        try:
            d, addr = s.recvfrom(65535)
        except socket.timeout:
            continue
        if carrier == "icmp":
            d = icmp_payload(d)
            if d is None:
                continue
        elif carrier != "udp":
            d = d[(d[0] & 15) * 4:]  # raw sockets include the IP header
        seq = find_seq(d)
        if seq is None:
            continue
        if opt.get("echo") and carrier == "udp":
            s.sendto(d[:64], addr)
        if seq < top:
            ooo += 1
        top = max(top, seq)
        now = time.time()
        first = first or now
        sec = int(now - first)
        per[sec] = per.get(sec, 0) + 1
        n += 1
    last = max(per) if per else -1
    print("RX n=%d ooo=%d persec=%s" % (n, ooo, ",".join(str(per.get(i, 0)) for i in range(last + 1))))


def send(carrier, src, dst, port, size, mbit, secs, opt):
    hop = int(opt.get("hop", 0))
    echo = bool(opt.get("echo")) or carrier == "icmp"
    stall_n, _, stall_t = opt.get("stall", "0:0").partition(":")
    stall_n, stall_t = int(stall_n), float(stall_t or 0)
    count = int(opt.get("count", 0))
    sport = int(opt.get("sport", 0))
    dns = opt.get("dns")
    itype = int(opt.get("itype", 8))
    s = open_sock(carrier, src, port, True, sport)
    if carrier == "udp":
        s.connect((dst, port))
        s.setblocking(False)
    pad = b"x" * max(0, size - 8)
    interval = size * 8 / (mbit * 1e6)
    t0 = time.perf_counter()
    n = errors = echoes = 0

    def drain():
        nonlocal echoes
        while select.select([s], [], [], 0)[0]:
            try:
                d = s.recv(2048)
            except OSError:
                break
            if carrier == "icmp":
                d = icmp_payload(d)
                if d is None or d[0] != 0:
                    continue
            echoes += 1

    while True:
        now = time.perf_counter() - t0
        if now >= secs:
            break
        due = int(now / interval) + 1
        if count:
            due = min(due, count)
        while n < due:
            if hop and n and n % hop == 0 and carrier == "udp":
                s.close()
                s = open_sock(carrier, src, port, True, sport)
                s.connect((dst, port))
                s.setblocking(False)
            pkt = dns_wrap(dns, n, pad) if dns else struct.pack("!II", MAGIC, n) + pad
            if carrier == "icmp":
                body = struct.pack("!BBHHH", itype, 0, 0, 0x7462, n & 0xFFFF) + pkt
                pkt = body[:2] + struct.pack("!H", checksum(body)) + body[4:]
            try:
                if carrier == "udp":
                    s.send(pkt)
                else:
                    s.sendto(pkt, (dst, 0))
            except OSError:
                errors += 1
            n += 1
            if stall_n and n % stall_n == 0:
                time.sleep(stall_t)
                t0 += stall_t
        if count and n >= count:
            break
        if echo:
            drain()
        time.sleep(0.0005)
    if echo:
        time.sleep(1)
        drain()
    print("TX n=%d errors=%d echoes=%d" % (n, errors, echoes))


if __name__ == "__main__":
    args = [x for x in sys.argv[1:] if "=" not in x]
    opts = dict(x.split("=", 1) for x in sys.argv[1:] if "=" in x)
    if args and args[0] == "recv" and len(args) == 5:
        recv(args[1], args[2], int(args[3]), float(args[4]), opts)
    elif args and args[0] == "send" and len(args) == 8:
        send(args[1], args[2], args[3], int(args[4]), int(args[5]), float(args[6]), float(args[7]), opts)
    else:
        sys.exit(__doc__)
