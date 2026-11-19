# opnsense-ha: os-ha-helpers

An OPNsense plugin, **os-ha-helpers** ("CARP failover helpers", System: High Availability:
Failover Helpers), that makes an HA pair (CARP + pfsync + config sync) fail over cleanly in
cases stock OPNsense does not cover: a WAN with **one ISP-assigned (DHCP) public address**,
a backup node that needs internet access of its own, and services that must run on the
master only. Written for OPNsense 26.7 and checked with live failover drills (takeover
under a second, no lost packets or DNS failures, clean failback).

The repository holds the plugin source in the layout of the
[opnsense/plugins](https://github.com/opnsense/plugins) ports tree
(`sysutils/ha-helpers/`), the signed package built from it (`packages/os-ha-helpers/`),
the third-party `os-carp-vip-dhcp` package it works with for a DHCP WAN
(`third-party/os-carp-vip-dhcp/`), and workstation tools to install, check, drill and
build (`tools/`). Releases up to v0.0.3 were a set of loose shell scripts (the "script
kit"); installing the plugin over them migrates a node (see
[Upgrade from the script kit](#upgrade-from-the-script-kit)).

## Credits

The DHCP WAN part rests on [os-carp-vip-dhcp](https://github.com/toreamun/opnsense-plugins/tree/main/net/os-carp-vip-dhcp)
by Tore Amundsen ([toreamun](https://github.com/toreamun)), from
<https://github.com/toreamun/opnsense-plugins>. It keeps the ISP's DHCP lease on the
CARP VIP's virtual MAC, so the public address lives on the VIP and fails over with it.
Thank you. It is BSD-2-Clause licensed and used here unmodified, as the author's signed
release package (see [Third-party package](#third-party-package-os-carp-vip-dhcp)).

## What it does

| Problem | What the plugin does |
|---|---|
| A DHCP WAN leases its address to the node's own MAC, so the address cannot float | Not this plugin: `os-carp-vip-dhcp` (above) requests the lease with the CARP VIP's virtual MAC on both nodes. Follow mode rewrites VIP and gateway if the ISP hands out a new address |
| On the BACKUP every WAN gateway monitor reads *down* (dpinger can only probe through the VIPs), so OPNsense installs no or a wrong default route; a fresh master forwards nothing until the monitors recover, and the backup node has no internet | **Routing**: pins the kernel default route to an upstream gateway (by priority; on MASTER the first that answers a ping) on that gateway's device whenever OPNsense left none, a LAN one, or one on the wrong device. On BACKUP it adds `0/1` + `128/1` via the master's reference CARP address so the node gets updates, NTP, blocklists. Runs on every CARP event and at boot, serialised with `lockf` |
| Unbound on the new master answers SERVFAIL from failures it cached as backup | **DNS**: on the reference VIP's MASTER event, restart Unbound and verify that it resolves |
| Services that must run on one node only (UPnP, mDNS/SSDP relay, ddclient) run on both | **Master-only services**: started on MASTER, stopped otherwise (CARP event, boot, cron every 2 minutes) |
| With both nodes advertising the same Tailscale subnets, the backup can stay the active subnet router | **Tailscale**: the BACKUP stops `tailscaled` for a moment so the routes move to the MASTER. Off unless the Tailscale nodes are set |
| Standby TCP state windows too stale to survive a planned failover | **pfsync**: `pfsync0 maxupd` (default 8) at boot |
| A VLAN on a disabled parent interface stays at MTU 1500 | **Jumbo MTU** (per node, opt-in): forces the listed devices to the jumbo MTU at boot; refuses a WAN device |

Same events, same order and the same logic as the script kit: CARP hooks
`10-hahelpers-egress`, `20-hahelpers-unbound`, `30-hahelpers-services`,
`60-hahelpers-tailscale`; boot hooks `95-hahelpers-pfsync`, `96-hahelpers-egress`,
`97-hahelpers-mtu`, `98-hahelpers-services`; scripts in
`/usr/local/opnsense/scripts/OPNsense/HaHelpers/`. Logs: System: High Availability:
Failover Helpers Log (`/var/log/hahelpers/`, tags `hahelpers-egress`, `-dns`,
`-services`, `-tailscale`, `-mtu`, `-pfsync`).

## Requirements

- Two OPNsense 26.7 nodes already set up as an HA pair: CARP VIPs, pfsync on a dedicated
  SYNC link, config sync. The plugin does not create that setup.
- For a DHCP WAN: `os-carp-vip-dhcp` (vendored here, built for OPNsense 26.7, FreeBSD 15,
  amd64). It is an optional dependency: the helpers work without it.
- For the tools: root SSH (key login) from a workstation to both nodes; `sh`, `ssh`,
  `openssl`, `tar`. `tools/drill.sh` also needs `ping`, `dig`, `curl` 7.84 or newer and
  GNU `date`, and must sit on a LAN behind the pair.

## Install

```sh
git clone https://github.com/kawaconnect/opnsense-ha.git && cd opnsense-ha
tools/install.sh root@<backup-node>      # backup node first
tools/install.sh root@<master-node>
```

`tools/install.sh` verifies each package (`SHA256SUMS`, and `SHA256SUMS.sig` against a
public key whose fingerprint is pinned in the script), installs `os-carp-vip-dhcp`
(skip with `HA_NO_CARPVIPDHCP=1`) and `os-ha-helpers` when the node has another version,
and prints the node status. Without the tools: copy the `.pkg` to the node and run
`pkg install -U -y ./os-ha-helpers-<version>.pkg`.

Then, on the master, open System: High Availability: Failover Helpers, tick **Enable**,
set the **Reference VHID** (the LAN-side CARP VIP) and whatever else applies, **Apply**.
Add "CARP failover helpers" to the HA sync items (System: High Availability: Settings) and
synchronise, or make the same settings on the backup. The "This node only" settings are
never synchronised; set them on each node.

Check the pair (read-only) and, in a maintenance window, drill a real failover:

```sh
tools/check.sh [-c site-check.conf] root@<node-a> root@<node-b>
tools/drill.sh root@<master> root@<backup>
```

For a DHCP WAN also add a keeper in Services: CARP VIP DHCP (synced by HA) for the WAN
VIP as in `examples/carpvipdhcp-settings.xml`; `examples/keeper.conf.rendered` is what
the plugin renders from it (documentation addresses, RFC 5737).

## Settings

| GUI field | Script name | Default | |
|---|---|---|---|
| Enable, Reference VHID | `VHID` | off, none | reference LAN-side CARP VIP; nothing happens without it |
| Boot grace | `BOOT_GRACE` | 120 | seconds after boot a MASTER event is distrusted while the peer answers |
| Backup egress | `BACKUP_EGRESS` | on | `0/1` + `128/1` via the master on the BACKUP |
| Pin default route | `PIN_DEFAULT_ROUTE` | on | keep the default route on a usable upstream gateway and its device |
| Unusable default gateways | `UNUSABLE_DEFAULT_GWS` | RFC 1918 + link-local patterns | unconfigured default gateways treated as unusable |
| Gateway / peer ping timeout | `GW_PING_TIMEOUT_MS`, `PEER_PING_TIMEOUT_MS` | 700, 500 | probe timeouts (ms) |
| Routing delay, Lock timeout | `EGRESS_HOOK_DELAY`, `LOCK_TIMEOUT` | 2, 30 | hook timing |
| Restart Unbound on takeover, Check name/server, Restart attempts, Settle time, Check delay | `UNBOUND_RESTART_ON_MASTER`, `DNS_*` | on, opnsense.org, 127.0.0.1, 2, 4, 3 | Unbound restart and check |
| Master-only services, Settle time, Event delay, Boot delay | `MASTER_ONLY_SERVICES`, `SERVICE_SETTLE`, `SERVICES_HOOK_DELAY`, `SERVICES_BOOT_DELAY` | none, 1, 3, 15 | services on the master only |
| Tailscale nodes, Handover hold | `TAILSCALE_NODES`, `TAILSCALE_HANDOVER_HOLD` | none, 45 | Tailscale route handover |
| pfsync maxupd | `PFSYNC_MAXUPD` | 8 (0 = leave alone) | set at boot; on a running MASTER only at the next boot |
| Jumbo MTU interfaces, Jumbo MTU (this node only) | `JUMBO_MTU_IFS`, `JUMBO_MTU` | none, 9000 | devices forced to a jumbo MTU at boot |

The settings live in `config.xml` under `OPNsense/HaHelpers`: `general` (HA-synced) and
`local` (per node). configd renders them to `/usr/local/etc/hahelpers.conf` for the
scripts. On the console: `configctl hahelpers show` (node state, as on the Failover Helpers
Status page), `configctl hahelpers settings` (settings in effect), and dry runs that change
nothing: `configctl hahelpers routes dryrun` (route commands), `routes show`,
`services dryrun` (master-only services), `dns dryrun` (Unbound on takeover),
`tailscale dryrun` (route handover).

## Upgrade from the script kit

Installing the package on a node that runs the script kit (`/usr/local/sbin/kc-ha-*`,
`/usr/local/etc/kc-ha.conf`):

1. The model migration imports every setting from `kc-ha.conf` (read as text, never
   executed; an invalid value keeps the default) and enables the helpers if `VHID` was set.
   `CHECK_*` and `DRILL_*` were settings of the workstation tools: they move to a
   `tools/check.sh -c` file (`tools/check.conf.sample`) and the `DRILL_*` environment.
2. The kit's files (scripts, hooks, cron files, `kc-ha.conf`, version stamp) are archived
   to `/var/backups/ha-helpers-legacy-<time>.tar` and removed, then the settings are
   applied (`configctl hahelpers start`): the same live steps `install.sh` took.
3. `tools/check.sh` fails while any kit file is left.

Do it backup node first, then the master, with probes running. **Rollback** on a node:

```sh
pkg delete -y os-ha-helpers
tar -xpf /var/backups/ha-helpers-legacy-<time>.tar -C /
/usr/local/sbin/kc-ha-egress; /usr/local/sbin/kc-ha-master-services
```

(or `git checkout v0.0.3 && ./install.sh root@<node>`). The plugin's settings stay in
`config.xml`, so a later reinstall keeps them.

## Uninstall

`pkg delete os-ha-helpers` on each node, backup first. It removes the backup egress routes,
the cron jobs and the rendered settings; the settings stay in `config.xml`. pfsync
`maxupd` and any jumbo MTU go back to the OPNsense defaults at the next reboot.

## Build and sign

```sh
tools/build.sh root@<build-host>         # OPNsense 26.7 build VM, never a production firewall
tools/sign.sh <private key file>         # SHA256SUMS + SHA256SUMS.sig in packages/os-ha-helpers
```

`tools/build.sh` copies `sysutils/ha-helpers` into a checkout of `opnsense/plugins` and
`opnsense/core` (`stable/26.7`) on the build host and runs `make lint` and `make package`
there. The private key never goes in the repository. Verify a package by hand:

```sh
cd packages/os-ha-helpers
sha256sum -c SHA256SUMS
openssl base64 -d -in SHA256SUMS.sig -out /tmp/sig.bin
openssl dgst -sha256 -verify ../../keys/release.pub -signature /tmp/sig.bin SHA256SUMS
openssl pkey -pubin -in ../../keys/release.pub -outform DER | sha256sum   # must equal PIN_ha_helpers in tools/install.sh
```

## What HA config sync does not carry (edit on every node)

Gateways and gateway groups, system tunables, Suricata, CrowdSec, Tailscale, interface
settings, and the plugin's "This node only" settings. The plugin's general settings are
carried when "CARP failover helpers" is ticked in the sync items.

## Security notes

- The helpers run as **root on the firewall**, from CARP events, at boot and from cron.
  The rendered `/usr/local/etc/hahelpers.conf` is only sourced when it belongs to root
  and is not writable by others; every value has passed the model's masks.
- The routing helper changes the kernel routing table (default route, `0/1` + `128/1` on
  the backup). It never touches firewall rules, NAT or `config.xml`.
- The Tailscale handover stops `tailscaled` on the backup for the hold time. If Tailscale
  is your only way in to that node, keep another one.
- The tools need root SSH to both nodes: key login from an admin workstation, SSH limited
  to the management network.
- No credentials, keys or site addresses are stored in this repository or written by the
  plugin. The release signing key is kept outside it.

## Troubleshooting

| Symptom | Look at |
|---|---|
| Status shows the helpers not running | Enable and Reference VHID in the settings, then Apply |
| `tools/check.sh`: `files of the old script kit are still present` | the package did not archive them (see the install output), or old copies (`*.bak`): archive and remove them |
| Backup node has no internet | Failover Helpers Status: role BACKUP, two backup egress routes |
| New master forwards nothing right after takeover | the default route must be an upstream gateway on its WAN device; the log shows what was pinned |
| DNS fails after a takeover | `hahelpers-dns` lines in the log; the check name must resolve from the firewall |
| A master-only service does not start | `hahelpers-services` lines; the service must be enabled in the config of **both** nodes |

## Interface layout for a DHCP WAN

- Node addresses on the WAN interface: a private /29 (169.254.255.1 / .2), **not** DHCP.
  The interface still needs `<gateway>` set to the WAN gateway or OPNsense adds no
  `reply-to` to that WAN's rules and replies leave via the other WAN.
- Public address: a CARP VIP (own vhid, skew 0 on the master / 100 on the backup).
  Alias `wan1_carp_vip` is kept equal to the current address by the keeper.
- Gateway for that WAN: static, the ISP router, Upstream = yes, a unique priority,
  monitoring on, **kill states on failure off** (on the backup node every WAN is "down";
  it would purge the synced state table).
- Second WAN with a static address: plain CARP VIP, no keeper.
- Outbound NAT: translate to the VIP, plus one rule for the node /29 itself.

## Boot-time false MASTER (known, partly mitigated)

A node that boots while the peer is healthy can time out to MASTER on its VLAN VIPs for
~30 s before it is able to hear the real master (seen in the field on 26.1: the pf
ruleset is not fully loaded yet; demotion does not prevent a timeout). During that window
both nodes are MASTER and clients that learn the booting node's MAC lose connectivity.

Mitigation in this kit: a MASTER event within `BOOT_GRACE` seconds of boot while the pfsync
peer still answers on the SYNC link is treated as false by the Unbound restart and the
master-only services (no restart, no service start). the routing part still acts (removing
the backup-egress routes on a false master is harmless and they come back on the BACKUP
event). `tools/check.sh` warns on "master timed out" in the log. Prefer rebooting a node while the
*other* one is master and expect a short blip; test it in a window before relying on it.

## Failover test

```sh
sysctl net.inet.carp.demotion=240     # on the master: hand over
# ... probe ping / DNS / a WAN-bound service from the LAN ...
sysctl net.inet.carp.demotion=-240    # relative counter: undo with the negative, not 0
```

## Field notes (converting a live single firewall with static WANs to a pair)

- **Device names must match on both nodes** for every WAN: synced states carry
  `route-to <gw>@<device>` (pfsync 1400+). With WAN2 on `vtnet1` on one node and `vtnet2`
  on the other, every established connection stalled for the whole failover while ping/DNS
  to the VIP looked fine. `tools/check.sh` fails on differing device names.
- **Converting a live gateway to a CARP VIP**, per interface on the primary: change the
  interface address `.1` → `.2`, add CARP VIP `.1` (skew 0), `configctl interface
  reconfigure <opt>`, `configctl filter reload`. ~3 s in BACKUP then MASTER; routed traffic
  keeps flowing. Add the secondary's VIP only after the primary is MASTER, or the
  secondary times out to MASTER and duplicates the address.
- **After the first VIP, reload the filter**: `interface reconfigure` alone does not add the
  automatic `pass proto carp` rules; without them the node drops the peer's advertisements
  and both stay MASTER. `tools/check.sh` counts those rules.
- **Reconfiguring an interface or pfsync on the master demotes it** (pfsync bulk start,
  factor 240) until "bulk done": a ~1 s handover and back when both nodes run the same
  version. With mismatched versions the bulk handshake can stall (`syncok: 0`, no "bulk
  done"); the node stays demoted and the peer takes over. Clear with
  `sysctl net.inet.carp.demotion=-240`, or set `net.pfsync.carp_demotion_factor=0` for the
  duration of a conversion. `syncok` alone is not a health signal: compare state counts.
- **Outbound NAT in hybrid/automatic mode** translates to the interface address, which
  becomes the private /29 node address: add a manual rule per WAN to the VIP **before**
  converting the interface. Rules using the `<if>ip` macro change meaning the same way.
- `configctl filter reload` does not trigger config sync; run
  `/usr/local/etc/rc.filter_synchronize` after CLI changes on the primary.
- sshd keeps listening only on the addresses present when it started; restart it after
  the conversion. Keep an out-of-band path (Proxmox guest agent) for `sysctl` on a node
  whose addresses just moved.
- Hot-added Proxmox virtio NICs enumerate in arrival order until a cold boot: verify
  device-to-MAC after a power cycle before relying on names.
- ISC DHCP failover needs tcp 519-520 allowed between the node addresses on each VLAN;
  role follows the VIP skew. Config sync of `dhcpd` and `virtualip` is safe.
- WireGuard: set `carp_depend_on` through the model (VIP UUID); the first sync may deliver
  it empty (VIP UUIDs not yet present), sync twice; run `configctl template reload
  OPNsense/Wireguard` on the secondary or `wg0.conf` stays empty; add a static-port
  outbound NAT rule for the tunnel port.
- Tailscale: with both nodes advertising the same subnets, the control plane keeps the
  routes on whichever node had them first, so after a failover or failback the backup can
  be the active subnet router and Tailscale drops what the master forwards. Approve the
  subnet routes for both nodes in the admin console and set "Tailscale nodes" so the
  helpers hand them back to the master. For a 1:1 NAT that sends LAN
  traffic to a single tailnet host, assign `tailscale0` as an interface on both nodes
  (same `optN`), allow it, and add an outbound NAT rule on it to that host with the
  interface address as target, so replies come back to the node that sent them.
- A configured upstream gateway may be a private address (a cellular or CPE router LAN
  such as `192.168.4.1`): the routing helper and `tools/check.sh` accept a default route through
  any *configured* upstream gateway, whatever its address, so a WAN failover OPNsense
  has already made is not undone by a CARP event.
- Services that must run on one node only (UPnP/miniupnpd, mDNS/SSDP relay, ddclient):
  list them under "Master-only services", for example
  `miniupnpd`. The service must be *enabled* in the config of
  **both** nodes (UPnP settings are not HA-synced; with UPnP disabled on one node,
  nothing serves it after a failover). `tools/check.sh` compares the UPnP section.
- An mDNS relay (os-udpbroadcastrelay): install the plugin and configure the same
  relay on **both** nodes, then add `udpbroadcastrelay` to the master-only services and
  `OPNsense/udpbroadcastrelays` to `CHECK_COMPARE_CONFIG`. Do not add a separate
  CARP hook or cron job for it: two managers for one service fight.

## Adding a WAN

1. Add the NIC to both VMs, assign on both nodes, node IPs from a private /29.
2. CARP VIP for the public address (new vhid); DHCP WAN → add a keeper on both nodes.
3. Gateway on both nodes: Upstream, unique priority, kill-states off. the routing helper
   picks the primary by priority on its own, no edit needed.
4. Outbound NAT rules for the new VIP; decide which policy routes / gateway groups may
   use it.

## Third-party package: os-carp-vip-dhcp

`third-party/os-carp-vip-dhcp/` holds the package `tools/install.sh` installs:
`os-carp-vip-dhcp-1.18.4`, built for OPNsense 26.7 (ABI `FreeBSD:15:amd64`, pure Python and
PHP, no dependencies). It is third-party software (BSD 2-Clause) by Tore Amundsen from
<https://github.com/toreamun/opnsense-plugins> and is not in the OPNsense repos. The files
are the upstream release assets of tag `v1.18.4`, unchanged:

| File | What it is |
|---|---|
| `os-carp-vip-dhcp-1.18.4.pkg` | the package |
| `SHA256SUMS` | its checksum, as published upstream |
| `SHA256SUMS.sig` | the author's RSA signature of `SHA256SUMS` (base64) |
| `release.pub` | copy of the author's public key `keys/release.pub` from the upstream repository |

Verify against the author's key, taken from the upstream repository rather than from
this directory:

```sh
cd third-party/os-carp-vip-dhcp
curl -fsSLo /tmp/upstream-release.pub \
  https://raw.githubusercontent.com/toreamun/opnsense-plugins/v1.18.4/keys/release.pub
cmp /tmp/upstream-release.pub release.pub          # the vendored copy is the author's key
sha256sum -c SHA256SUMS
openssl base64 -d -in SHA256SUMS.sig -out /tmp/SHA256SUMS.sig.bin
openssl dgst -sha256 -verify /tmp/upstream-release.pub -signature /tmp/SHA256SUMS.sig.bin SHA256SUMS
```

The upstream key has not changed since v1.0. `tools/install.sh` checks `SHA256SUMS` and the signature before every install, with the key
fingerprint pinned in the script.

### Upgrading the plugin

1. Download the release assets of the new tag (`gh release download vX.Y.Z -R
   toreamun/opnsense-plugins`), verify them as above, read the release notes between the
   two versions (model migrations, HA notes), and replace the files here.
2. Upgrade **both nodes before the next HA config sync** of the `carpvipdhcp` item: a node
   on an older version does not understand settings migrated by a newer one. Do not run a
   scheduled "HA update and reconfigure backup" job in between.
3. Backup node first (`tools/install.sh root@<backup>`): on 1.14 and later a BACKUP keeper sends
   nothing on the WAN, so check its log says `initial CARP role ...: BACKUP` and the
   heartbeat shows `bound=-`. Then the master right after: the keeper restarts, renews at
   once (`DHCP BOUND` in its log) and the VIP never leaves the interface.
4. From 1.18.3 the master corrects a VIP prefix or WAN gateway that differs from its lease
   right after the upgrade (a prefix change costs one short CARP failover per node). Compare
   the VIP prefix and gateway with the `mask=` and `gw=` of the last `DHCP reply: ACK` line
   in `/var/log/carpvipdhcp-*.log` beforehand; if they match, nothing changes.
5. `tools/check.sh` must say `ALL OK`; compare the `OPNsense/CarpVipDhcp` section of both
   `config.xml` files (only `persisted_at` may differ).
