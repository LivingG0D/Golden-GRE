# GRO corrupts GRE-over-FOU → TCP collapses (UDP looks fine)

## Symptom

The tunnel is up and pings cleanly, **UDP throughput is good (hundreds of Mbit/Gbit), but TCP collapses to ~1 Mbit/s** in both directions — heavy retransmits, tiny congestion window. Multi-stream, BBR, MSS changes, bigger buffers — none of it helps.

## Root cause

**Generic Receive Offload (GRO) on the underlay NIC mis-coalesces the FOU (GRE-in-UDP) packets.** The merged super-packets are malformed for this encapsulation, so the receiver drops them at the UDP layer. You can see it directly:

```bash
nstat -n; sleep 10; nstat | grep Udp     # on the receiver, during a TCP test
# UdpInErrors climbs to ~25% of UdpInDatagrams
```

UDP test traffic is paced and doesn't trigger the same coalescing pattern, so UDP measures clean — which is what makes this so confusing. The drops are **protocol-pattern dependent, not path loss**: `tcpdump`/`ping` and paced UDP all look healthy while TCP dies.

This is a host/driver offload bug, not a network-path problem. It does **not** show up as interface errors, firewall drops, conntrack INVALID, MTU/PMTU issues, or rp_filter — all of which we ruled out before finding it.

## Fix

Disable GRO on the **physical underlay interface** (the one carrying the FOU UDP), on **both** ends. Not on `greN` — the corruption happens where the UDP arrives.

```bash
ethtool -K <underlay-iface> gro off
```

Golden GRE does this automatically: `golden-gre-up.sh` derives the underlay interface from `REMOTE_PUB` and disables GRO on it at tunnel bringup, so the fix persists across reboots.

## Verifying

```bash
# receiver:
iperf3 -s -B <overlay-ip>
# sender:
iperf3 -c <peer-overlay-ip> -P4 -t 15      # before: ~1 Mbit  /  after: hundreds of Mbit–Gbit
nstat -n; sleep 10; nstat | grep UdpInErrors   # on receiver: should stay ~0
```

Real numbers from one cross-provider tunnel (78 ms RTT): TCP **~1 Mbit → 350 Mbit/s** one way and **→ 1.04 Gbit/s** the other, `UdpInErrors` 21k/test → 0.

## Note

GRO is great for normal traffic; only the FOU underlay needs it off. If you terminate other (non-tunnel) high-throughput flows on the same NIC, you trade a little of their efficiency for a working tunnel. The offload is disabled per-interface, not system-wide.
