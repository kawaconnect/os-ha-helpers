# Changelog

Versions are git tags (`vX.Y.Z`); `install.sh` stamps the node with `git describe`.

## [Unreleased]

Re-run `install.sh` on both nodes to pick these up (`check.sh` reports the changed
files as `differs from repo` until then).

### Security
- `install.sh` checks the plugin package against `SHA256SUMS` before installing it,
  uploads it to a private `mktemp` directory on the node instead of a fixed name in
  `/tmp`, and confirms the version afterwards.
- `install.sh` copies files only (no directory entries) and unpacks them as root-owned.
  Run by a non-root user, the old `tar` pipe gave `/usr`, `/etc` and the scripts that
  user's uid and directory modes on the firewall.
- `kc-ha-lib`: values read from `config.xml` are only passed to the shell when they
  are made of address and device-name characters.

### Fixed
- `kc-ha-egress` and `kc-ha-status` read the default route's device with `route -n get`
  (new `kc_ha_default_route` in `kc-ha-lib`) instead of `netstat -rn`, which cuts long
  device names (`vtnet1_vlan33` showed as `vtnet1_vlan3`). With the default route on
  such a VLAN WAN, `kc-ha-egress` re-pinned a correct default route to the first
  gateway and `check.sh` reported a false "default route ... is on" FAIL.
- `check.sh`: `CHECK_COMPARE_CONFIG` also compares sections whose entries have child
  elements (plugin instance lists such as `OPNsense/udpbroadcastrelays`); before, such
  entries compared as empty.
- `kc-ha-tailscale-primary` starts `tailscaled` again when it is interrupted during the
  handover hold, and logs an error if the service does not come back.
- `drill.sh`: the hook log filter did nothing and used GNU-only `date -d`; it now
  prints the last log lines. Hold and demotion must be whole numbers.
- `check.sh` works on a workstation without `md5sum` (macOS, BSD).

### Changed
- Vendored `os-carp-vip-dhcp` 1.13.8 -> 1.18.4 (upstream signed release asset, signature
  checked with the author's `keys/release.pub`; `sig.bin` dropped, `SHA256SUMS.sig` is the
  upstream file). Highlights: a BACKUP keeper sends no DHCP on the WAN any more (no switch
  MAC flap), follow mode also follows the lease's prefix and router, short stop-gap leases
  are ignored (`minLeaseTime`, 60 s), DHCP identity values are kept off the command line.
  The keeper model migrates 1.1.0 -> 1.4.1 on install (`followIp` -> `leasePolicy`,
  client-id/vendor class -> `clientIdentifier`/Send Options, same packets on the wire).
  Upgrade both nodes before the next HA config sync of `carpvipdhcp`; see README
  "Upgrading the plugin". `examples/` updated to the new settings.
- `drill.sh` asks before demoting the master when run on a terminal (`KC_HA_YES=1`
  skips the question; without a terminal it runs as before).
- `install.sh -h` prints usage; a missing plugin package is reported instead of
  failing later.
- README: requirements, quick start, security notes, troubleshooting, uninstall,
  plugin source and verification. Site-specific names removed from the docs and
  examples.

## [0.0.2] - 2026-11-02

### Added
- `kc-ha-tailscale-primary` (carp hook `60-kc-ha-tailscale`, cron every 2 min):
  with both nodes advertising the same Tailscale subnets, Tailscale keeps the
  routes on whichever node had them first, so after a failover or failback the
  BACKUP could stay the active subnet router and Tailscale dropped what the
  MASTER forwarded. On the BACKUP, when it holds the routes and the other node
  is online in the tailnet, tailscaled is stopped for `TAILSCALE_HANDOVER_HOLD`
  seconds so the routes move to the MASTER. Off unless `TAILSCALE_NODES` is set
  in `kc-ha.conf`.
- README: how to send LAN traffic to a single tailnet host through a 1:1 NAT
  (assign `tailscale0`, allow it, outbound NAT to the host on it).

## [0.0.1] - 2026-10-28

### Fixed
- `kc-ha-lib`: the CARP role lookup matched the reference vhid as a prefix, so
  with `VHID=1` a VIP with vhid 10-19 on the same device listed first was read
  as the role (for example BACKUP while vhid 1 was MASTER). It now matches the
  exact vhid. A pair with one VIP per device was not affected.
  Re-run `install.sh` on both nodes to pick it up (`check.sh` reports
  `kc-ha-lib differs from repo` until then).
