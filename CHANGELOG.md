# Changelog

Versions are git tags (`vX.Y.Z`). From 1.0.0 the repository is the os-ha-helpers
OPNsense plugin; the package version is `PLUGIN_VERSION` in `sysutils/ha-helpers/Makefile`
(1.0.0 = package 1.0). 0.0.x were the loose shell script kit.

## [Unreleased]

### Changed
- Repository renamed `opnsense-ha` -> `os-ha-helpers` on GitLab and GitHub (old URLs redirect);
  `tools/install.sh` reads releases from `dean/os-ha-helpers`, `pkg-descr` WWW points at the new GitHub URL.
- `tools/install.sh` installs from the GitHub releases of kawaconnect/os-ha-helpers by default (no token);
  `HA_RELEASE_SOURCE=gitlab` keeps the GitLab route.

### Added
- CI job `github`: each `v*` release is also published as a GitHub release with the same three files,
  through the GitHub API with a repository-scoped token (no GitHub Actions). v1.0.2 was published there too.

## [1.0.2] - 2026-11-19

Package os-ha-helpers 1.0_3. First package built and signed by GitLab CI; the plugin's
files are the same as in 1.0_2, only the version file differs.

### Added
- `.gitlab-ci.yml`: `make lint`, phpcs with the OPNsense core ruleset and `make package` on
  every merge request and on `main`, on a FreeBSD 15 amd64 build runner. A protected `v*` tag
  also signs the package with the release key (protected CI variable) and publishes the
  `.pkg`, `SHA256SUMS` and `SHA256SUMS.sig` as release assets.
- `tools/ci-build.sh`, `tools/ci-release.sh`.

### Changed
- `tools/install.sh` installs os-ha-helpers from the latest release by default
  (`HA_RELEASE=vX.Y.Z` for another one, `HA_PKG_DIR` for a local directory) and verifies it
  against `keys/release.pub` from the checkout, as before.
- `tools/sign.sh` takes the package directory as an optional second argument.
- `product_hash` in the package's version file is now this repository's commit.

## [1.0.1] - 2026-11-19

Package os-ha-helpers 1.0_2. Review fixes, behaviour of the helpers unchanged.

### Fixed
- The service start/restart that an HA sync runs on the backup now renders the settings
  first (`template reload OPNsense/HaHelpers`); before, the backup applied the old values
  until a GUI save or a reboot.
- `lib.sh` reads `hahelpers.conf` instead of sourcing it: only known settings with plain
  address, name and pattern characters are taken, and a file not owned by root or writable
  by group or others is ignored (logged, helpers inert).
- The post-deinstall script leaves the rendered settings and cron jobs alone on an upgrade.
- Switching the helpers off removes their cron jobs at once.
- Import from `kc-ha.conf`: several assignments on one line are split; yes/no accepts the
  same words as the kit (`yes YES 1 on true`).
- `tools/check.sh`: `pkg check -s` judged by its exit status, the config.xml collection must
  finish on both nodes, backup egress routes must point at the reference VIP.

### Changed
- "Unusable default gateways" cannot be empty (the kit allowed `UNUSABLE_DEFAULT_GWS=""`).

## [1.0.0] - 2026-11-19

### Added
- OPNsense plugin `os-ha-helpers` (`sysutils/ha-helpers/`, opnsense/plugins layout):
  settings under System: High Availability: Failover Helpers, a status page, a log page,
  configd actions (`configctl hahelpers start|stop|status|show|egress|services`), CARP and
  boot syshooks and cron jobs registered by the plugin. Same hooks on the same events and
  the same logic as the script kit, ported unchanged apart from paths and log tags
  (`hahelpers-*`, in `/var/log/hahelpers/`).
- Settings are model fields in `config.xml`: `general` is carried by HA sync (sync item
  "CARP failover helpers"), `local` (jumbo MTU devices) never is.
- Upgrade from the script kit: the model migration imports `/usr/local/etc/kc-ha.conf`;
  the package archives the kit's files to `/var/backups/ha-helpers-legacy-*.tar` and
  removes them. Rollback steps in the README.
- `tools/install.sh` (verifies `SHA256SUMS` and the signature against pinned key
  fingerprints before installing), `tools/build.sh` (lint and package on a build host),
  `tools/sign.sh`, `tools/check.conf.sample`. Release key `keys/release.pub`.
- BSD-2-Clause `LICENSE`; credits for os-carp-vip-dhcp in the README and `pkg-descr`.

### Changed
- `check.sh` and `drill.sh` moved to `tools/` and check the plugin (package version,
  `pkg check -s`, enabled, cron jobs, no kit files left) instead of loose files. Their
  `CHECK_*` settings come from `tools/check.sh -c <file>`, `DRILL_*` from the environment;
  `KC_HA_*` variables are now `HA_*`.
- The vendored os-carp-vip-dhcp moved to `third-party/os-carp-vip-dhcp/`.

### Removed
- The script kit (`files/`, `install.sh`); it stays available at tag v0.0.3.

## [0.0.3] - 2026-11-19

Last release of the shell script kit.

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
