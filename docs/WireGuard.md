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

## Notes

- Put real keys in `/etc/wireguard/`, not in the repo.
- Use a dedicated /30 or /24 per tunnel.
- Keep the underlay routing simple and test with `ping` and `iperf3` before moving production routes.
