# WireGuard Fallback

Golden GRE is built around GRE-in-UDP. In some filtered networks, that still gets throttled hard.

WireGuard is the practical fallback:

- encrypted
- UDP-based
- simpler packet path than GRE-over-FOU
- usually better throughput on censorship-heavy or DPI-heavy links

## Suggested starting point

- MTU: `1320`
- Port: `443` if it works, otherwise any open UDP port
- Keepalive: `25`

## Example

See `examples/wireguard.conf.example`.

## When the tunnel goes silent

Symptom: `wg show` reports a `latest handshake` that keeps aging, frozen transfer counters, and 100%
packet loss across the tunnel. Both ends still look healthy — `PersistentKeepalive` means they retry
forever and never log an error.

That pattern is usually the underlay, not WireGuard: the UDP port has been filtered on the path.
Restarting the interface will not fix it.

### Diagnose first

Confirm packets leave and never arrive. Run on both ends:

```sh
timeout 30 tcpdump -ni any "udp port <PORT> and host <PEER>"
```

Sent > 0 and received == 0 on *both* ends means the path is dropping them.

Then find a port that still passes. Test each direction separately — filtering is often asymmetric:

```sh
# receiver: capture on candidate ports
for P in 8443 2408 51820 1194 5060 8080; do
  setsid timeout 40 socat -u UDP4-RECVFROM:$P,reuseaddr,fork OPEN:/tmp/probe_$P,creat,append &
done

# sender: fire at the same list
for P in 8443 2408 51820 1194 5060 8080; do echo probe | socat -u STDIN UDP4-SENDTO:<PEER>:$P; done

# receiver: anything with bytes is open
for f in /tmp/probe_*; do [ -s "$f" ] && echo "$f open"; done
```

Reading the result:

- Run it both ways. A port open A→B can still be blocked B→A.
- You cannot probe the port WireGuard currently binds — the listener will not bind. Test the others.
- Unsolicited inbound dropped while replies on an established flow pass is a stateful firewall, not
  a port block. WireGuard survives that, since its keepalive holds the pinhole open — provided the
  port itself is not filtered.

### Move the tunnel

Change it live on both ends first, so a bad guess costs nothing (SSH is unaffected):

```sh
wg set <IFACE> listen-port <NEW> peer <PEER_PUBKEY> endpoint <PEER_IP>:<NEW>
```

Verify a fresh handshake and ping, then persist. `wg set` does **not** write the config file, so a
reboot or `wg-quick` restart would drop back to the dead port:

```sh
sed -i "s/^ListenPort = <OLD>/ListenPort = <NEW>/; s/:<OLD>$/:<NEW>/" /etc/wireguard/<IFACE>.conf
```

Avoid a port another interface already binds. Once the tunnel is healthy it can also carry other
UDP services whose own ports are filtered — a QUIC-based proxy that cannot reach its server directly
will usually work pointed at the peer's tunnel address.

## Bonding several tunnels past a UDP policer

Some transit paths police **per flow** rather than per host. The tell, measured between the two
public IPs with no tunnel involved:

```sh
iperf3 -c <PEER_PUB>            # 1 stream
iperf3 -c <PEER_PUB> -P 4       # 4 streams
iperf3 -c <PEER_PUB> -u -b 500M # UDP, watch the loss column
```

One stream far below four streams, and UDP losing 50-65% at any rate, means a single tunnel cannot
win — WireGuard is one UDP 5-tuple, so it lands in one policing bucket. Kernel tuning does not move
this; the ceiling is the bucket, not the host.

The fix is more buckets: run N tunnels on **different ports**, each with its own keypair and /30.

```sh
# per tunnel N: unique iface, port, subnet, keypair
[Interface]
Address = 10.200.20N.1/30
ListenPort = <PORT_N>
PrivateKey = <UNIQUE_KEY_N>
MTU = 1420

[Peer]
PublicKey = <PEER_PUBKEY_N>
AllowedIPs = 10.200.20N.2/32
Endpoint = <PEER_PUB>:<PORT_N>
PersistentKeepalive = 25
```

Each tunnel needs its **own keypair** — a peer is identified by its public key, so two tunnels
sharing one keypair cannot be told apart. Verify the gain by driving all tunnels at once, each
against its own `iperf3 -s -p <PORT>` (one server accepts one client at a time, so concurrent
clients against a single port report zeros that look like tunnel failure).

ECMP will not split a single connection: it hashes per flow, so one QUIC/TCP session pins to one
tunnel. Spread work across the tunnels at the layer above instead — a proxy with one outbound per
tunnel and a round-robin balancer over them. Aggregate throughput scales with N; a single stream
stays at one tunnel's rate.

### Xray balancer: fallbackTag needs an observatory

A balancer whose `fallbackTag` is non-empty requires an `observatory` block. Without one, xray
refuses to start with a message that names neither field:

```
Failed to start: main: failed to create server > core: not all dependencies are resolved.
```

Either leave `fallbackTag` empty, or define the observatory. Prefer the observatory if a panel owns
the config — panels re-add `fallbackTag` on save, so blanking it only holds until the next save.
`subjectSelector` is a prefix match, so one entry covers a whole family of outbound tags, and it
buys health-checking as well: the balancer skips a tunnel that stops answering.

```json
"observatory": {
  "subjectSelector": ["<OUTBOUND_TAG_PREFIX>"],
  "probeURL": "https://www.gstatic.com/generate_204",
  "probeInterval": "60s"
}
```

Validate before restarting anything that serves users — this parses the file without touching the
running instance:

```sh
xray run -test -c /path/to/config.json    # expect "Configuration OK"
```

## Notes

- Put real keys in `/etc/wireguard/`, not in the repo.
- Use a dedicated /30 or /24 per tunnel.
- Keep the underlay routing simple and test with `ping` and `iperf3` before moving production routes.
