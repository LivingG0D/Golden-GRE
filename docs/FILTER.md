# What a filtered IPv4 path does, and how every method fared

Golden GRE's relay exists because of what one real IPv4 path (two servers in different countries) did to
tunnels. These are measurements, not a general claim: the filter changes, so rerun
`bench/carriers.sh` on your own path before relying on any of it.

## The path's rules

| Carrier | Result |
|---|---|
| Any UDP flow (5-tuple), any port, packet size, rate or direction, with or without replies | **cut after about 6 packets** |
| TCP | cut after the first KBs |
| Raw IP protocols 4, 41, 47, 50, 51, 94, 115, 132, 136, 137, 143, 253 | cut after about 6 packets (some pass none) |
| The same UDP flow, but a new source port every packet (or every 6) | passes (99.9%), but 60 to 80% of packets arrive out of order |
| ICMP echo request and unsolicited echo reply | passes (100% at 50 Mbit/s); reordering grows with rate (70% at 50 Mbit/s) |
| **UDP to port 53 whose payload is a valid DNS message** (query shape, or TXT-response shape) | **passes**: 100% at 20 Mbit/s for 20 s, 99.9% at 50 Mbit/s, about 0.3% reordering |
| Plain payload to port 53; DNS-shaped replies from port 53 with no query | cut after about 6 packets |

`bench/localize.sh` shows the cut happens in transit (sender NIC: 10,418 packets out; receiver NIC: 6 in).
`bench/carriers.sh` and `bench/filter.sh` produce the table.

## Methods, measured

Single TCP flow through the tunnel, 8 s, `bench/matrix.sh`. Down = server B to A, up = A to B.

| Method | Ping loss | Down | Up | Down, 4 flows | UDP 30M loss |
|---|---|---|---|---|---|
| GRE (IP proto 47) | 100% | - | - | - | - |
| IPIP (proto 4) | 100% | - | - | - | - |
| GRE-in-UDP (FOU) | 75% | 0 | 0 | 0 | - |
| GRE-in-UDP (GUE) | 70% | 0 | 0 | 0 | - |
| IPIP-in-UDP (FOU) | 70% | 0 | 0 | 0 | - |
| VXLAN | 70% | 0 | 0 | 0 | none received |
| Geneve | 70% | 0 | 0 | 0 | none received |
| WireGuard | 100% | - | - | - | - |
| GRE-in-UDP + per-packet source-port hopping (nft) | 0% | 27 | 47 | 28 | - |
| WireGuard + Python relay, DNS disguise | 0% | 108 | 122 | 84 | 0.8% |
| WireGuard + Python relay, ICMP disguise | 0% | 30 | 60 | 37 | 24% |
| WireGuard + C relay, DNS disguise | 0% | 129 | 108 | 141 | 0.8% |
| WireGuard + C relay, ICMP disguise | 0% | 27 | 111 | 84 | 0.04% |
| **GRE + C relay, DNS disguise (Golden GRE)** | **0%** | **138** | **153** | **161** | **0.014%** |
| GRE + C relay, ICMP disguise | 0% | 101 | 115 | 90 | 0% |

Mbit/s unless noted. Round trip about 82 ms. Soak, GRE + C relay, DNS disguise, 300 s: 144 Mbit/s
average, 86 to 174 per 10 s, no cutoff. The raw tables are in `results/`.

Not run method by method: proxy protocols (VLESS/Reality, Shadowsocks, Trojan, SSH, Hysteria2, TUIC,
backhaul). They ride TCP or UDP flows of the kinds the carrier tests show being cut.

## Notes from building it

- **Hopping works, but reorders.** A kernel tunnel plus an nft rule that gives each packet a random source
  port (`bench/remote/hop.sh`) passes traffic, but 60 to 80% of packets arrive out of order and TCP
  suffers. nft cannot do arithmetic on a port; the random port comes from `numgen` indexing a map.
  nft's checksum fix-up is wrong for zero UDP checksums (kernel 6.8) and for offloaded inner packets, and
  GSO must be off on the tunnel device, or one rewrite covers dozens of packets that then share a port.
- **The disguise beats hopping.** One flow per direction, no hopping, almost no reordering. The relay
  sends from an ephemeral port to `<peer>:53`; the shape is a DNS query with an EDNS0 record whose RDATA
  is the payload.
- **The relay must know where to deliver.** Left to learn the tunnel's address from its first outgoing
  packet, a relay drops everything the peer sends until the local tunnel has sent something. The relay
  takes `--reply` (the tunnel's FOU address) so delivery works from the first packet.
