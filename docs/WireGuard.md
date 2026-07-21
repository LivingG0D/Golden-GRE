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

## Notes

- Put real keys in `/etc/wireguard/`, not in the repo.
- Use a dedicated /30 or /24 per tunnel.
- Keep the underlay routing simple and test with `ping` and `iperf3` before moving production routes.
