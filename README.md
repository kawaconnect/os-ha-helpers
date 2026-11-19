# opnsense-ha

Scripts and hooks that make an OPNsense HA pair (CARP + pfsync + config sync) fail over
cleanly in two cases stock OPNsense does not cover: a WAN with **one ISP-assigned (DHCP)
public address**, and a backup node that needs internet access of its own. Written for
OPNsense 26.1 / 26.7 and checked with live failover drills (takeover under a second, no
lost packets or DNS failures, clean failback).

Everything is plain `sh` plus the Python that OPNsense already ships. The same files are
installed unchanged on both nodes; one config file, `/usr/local/etc/kc-ha.conf`, holds
every site value.

## What it adds

| Problem | Fix | Files |
|---|---|---|
| A DHCP WAN leases its address to the node's own MAC, so the address cannot float to the other node | `os-carp-vip-dhcp` plugin: a lease keeper on **both** nodes requests the lease with the CARP VIP's virtual MAC (`00:00:5e:00:01:<vhid>`); the ISP sees one client, the address lives on the VIP and moves with CARP. Follow mode rewrites VIP + gateway if the ISP ever hands out a new address | `plugins/os-carp-vip-dhcp/`, `examples/carpvipdhcp-settings.xml` |
| On the BACKUP node every WAN gateway monitor reads *down* (dpinger can only probe through the VIPs), so OPNsense installs no / a wrong default route. A fresh master forwards nothing until monitors recover; the backup node itself has no internet | `kc-ha-egress`: pins the kernel default route to an upstream gateway whenever OPNsense left none or a LAN one. Candidates come from the config (upstream gateways by priority); on MASTER the first one that answers a ping wins, so a dead primary WAN is not pinned during a takeover. On BACKUP it adds `0/1` + `128/1` via the master's LAN VIP (found by vhid in the config) so the backup gets updates, NTP, CrowdSec etc. Runs on every CARP event and at boot, serialised with `lockf`; `--show` prints what it sees, `--dry-run` what it would do | `files/usr/local/sbin/kc-ha-egress`, hooks `carp/10-kc-ha-egress`, `start/96-kc-ha-egress` |
| Unbound on the new master cached SERVFAILs while it was backup | `kc-unbound-master`: on the LAN VIP's MASTER event, restart Unbound and verify resolution | `files/usr/local/sbin/kc-unbound-master`, hook `carp/20-kc-unbound-master` |
| Services that must run on one node only (UPnP, mDNS/SSDP relay, ddclient) run on both | `kc-ha-master-services`: starts `MASTER_ONLY_SERVICES` on the master, stops them elsewhere (CARP hook, boot, cron every 2 min) | `files/usr/local/sbin/kc-ha-master-services`, hooks `carp/30-...`, `start/98-...` |
| With both nodes advertising the same Tailscale subnets, the backup can end up as the active subnet router | `kc-ha-tailscale-primary`: the BACKUP hands the routes to the MASTER. Off unless `TAILSCALE_NODES` is set | `files/usr/local/sbin/kc-ha-tailscale-primary`, hook `carp/60-kc-ha-tailscale` |

Two smaller boot hooks, use if they apply:

- `start/95-pfsync-maxupd`: `pfsync0 maxupd 8` so standby TCP state windows are fresh
  enough for connections to survive a planned failover (default 128 was too stale).
- `start/97-kc-jumbo-mtu`: re-applies MTU 9000 on a VLAN whose (disabled) parent
  interface OPNsense never sizes. Opt-in: it only touches the interfaces listed in
  `JUMBO_MTU_IFS` in `kc-ha.conf` (none by default) and refuses any device that carries
  an upstream gateway, so it is safe to install on every site.

## Requirements

On the firewalls:

- Two OPNsense nodes (26.1 or 26.7) already set up as an HA pair: CARP VIPs, pfsync on a
  dedicated SYNC link, config sync. This kit does not create that setup.
- Root SSH from your workstation to both nodes (key login; the root shell may stay csh).
- For a DHCP WAN: the vendored `os-carp-vip-dhcp` package is built for OPNsense 26.7
  (FreeBSD 15, amd64). On another release build it from its source (see
  [Plugin package](#plugin-package)) and point `KC_HA_PLUGIN_DIR` at it, or set
  `KC_HA_NO_PLUGIN=1` if no WAN is DHCP.

On the workstation (Linux or macOS): `sh`, `ssh`, `tar`, `git` (or a `VERSION` file next
to `install.sh`). `drill.sh` also needs `ping`, `dig`, `curl` 7.84 or newer and GNU `date`,
and must sit on a LAN behind the pair, because it probes through the firewall.

## Quick start

```sh
git clone https://github.com/kawaconnect/opnsense-ha.git && cd opnsense-ha

# 1. install on the BACKUP node first, then the master (see "Install" for why)
./install.sh root@<backup-node>
./install.sh root@<master-node>

# 2. on BOTH nodes: set VHID in /usr/local/etc/kc-ha.conf to the vhid of the LAN-side
#    CARP VIP (the kit does nothing until it is set), then run install.sh again
#    (every setting is described in the file; MASTER_ONLY_SERVICES, JUMBO_MTU_IFS and
#    TAILSCALE_NODES only if they apply to you)

# 3. acceptance test of the pair (read-only)
./check.sh root@<node-a> root@<node-b>

# 4. optional, in a maintenance window: a real failover and failback with probes
./drill.sh root@<master> root@<backup>
```

For a DHCP WAN, also add a keeper in the GUI (Services > CARP VIP DHCP, synced by HA) for
the WAN VIP as in `examples/carpvipdhcp-settings.xml`; `examples/keeper.conf.rendered` is
what the plugin renders from it. The addresses in `examples/` are documentation addresses
(RFC 5737), replace them with yours.

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

## What HA config sync does not carry (edit on every node)

Gateways and gateway groups, system tunables, `rc.syshook.d` hooks, Suricata,
CrowdSec, Tailscale, interface settings. `install.sh` covers the hook/script part.

## Contents

| Path | Purpose |
|---|---|
| `files/usr/local/sbin/kc-ha-lib` | shared helpers: reads `kc-ha.conf` + `config.xml` (reference VIP by vhid, its device, pfsync peer, upstream gateways with devices), role, uptime, peer-alive, boot-grace gate |
| `kc-ha-egress` | default route / backup egress (above) |
| `kc-unbound-master` | Unbound restart on a trusted MASTER event |
| `kc-ha-master-services` | start/stop `MASTER_ONLY_SERVICES` by role (carp hook, boot, cron every 2 min) |
| `kc-ha-status` | one-screen status of a node (`--kv` for scripts) |
| `kc-ha-tailscale-primary` | the BACKUP hands the Tailscale LAN routes to the MASTER (carp hook, cron every 2 min); off unless `TAILSCALE_NODES` is set |
| `files/usr/local/etc/kc-ha.conf.sample` | every setting with its default and what it does; copied to `kc-ha.conf` once |
| `install.sh` | idempotent install of plugin + files + version stamp, then live apply and status |
| `check.sh` | acceptance test of the pair (below) |
| `drill.sh` | controlled failover/failback with probes of existing flows |

Nothing is hardcoded: the same files are installed unchanged on every node of every
site, and `kc-ha.conf` (identical on both nodes) is the only place where behaviour is
set. No script or hook names a vhid, a VIP, a device, an address, a service or a timing;
the defaults all sit in one block at the top of `kc-ha-lib` and every one can be
overridden.

### Settings (`kc-ha.conf`)

| Setting | Default | What it controls |
|---|---|---|
| `VHID` | *(none, required)* | reference LAN-side CARP VIP; empty = kit inert |
| `BOOT_GRACE` | 120 | seconds after boot a MASTER event is distrusted while the peer is alive |
| `MASTER_ONLY_SERVICES`, `SERVICE_SETTLE` | empty, 1 | services run on the master only; wait before verifying a start/stop |
| `BACKUP_EGRESS` | yes | 0/1 + 128/1 routes via the master on the BACKUP node |
| `PIN_DEFAULT_ROUTE` | yes | keep the default route on a usable upstream gateway and its device |
| `UNUSABLE_DEFAULT_GWS` | RFC 1918 + link-local patterns | unconfigured default gateways treated as unusable |
| `GW_PING_TIMEOUT_MS`, `PEER_PING_TIMEOUT_MS` | 700, 500 | probe timeouts |
| `UNBOUND_RESTART_ON_MASTER` | yes | restart Unbound on takeover |
| `DNS_CHECK_NAME`, `DNS_CHECK_SERVER`, `DNS_RESTART_TRIES`, `DNS_SETTLE`, `DNS_RETRY_WAIT` | opnsense.org, 127.0.0.1, 2, 4, 3 | how resolution is verified after the restart |
| `PFSYNC_MAXUPD` | 8 | `pfsync0 maxupd` at boot; empty = leave it |
| `JUMBO_MTU_IFS`, `JUMBO_MTU` | empty, 9000 | interfaces forced to a jumbo MTU at boot; WAN devices refused |
| `EGRESS_HOOK_DELAY`, `SERVICES_HOOK_DELAY`, `SERVICES_BOOT_DELAY`, `LOCK_TIMEOUT` | 2, 3, 15, 30 | hook timing |
| `CHECK_*` | see sample | `check.sh`: state tolerance, keeper age, Kea URL, master-only anchors, reply-to interfaces, interfaces whose device may differ, config sections compared across nodes |
| `TAILSCALE_NODES`, `TAILSCALE_HANDOVER_HOLD` | empty, 45 | Tailscale host names of both nodes (empty = off); seconds `tailscaled` stays down on the BACKUP to hand the routes over |
| `DRILL_*` | see sample | `drill.sh`: demotion, hold, probe address, DNS name, HTTPS URL |

`kc-ha-status --settings` prints what is in effect on a node; `check.sh` fails if the
two nodes' `kc-ha.conf` differ. The cron interval of `kc-ha-master-services` is the one
value kept in a file of its own (`/etc/cron.d/kc-ha-master-services`), because cron reads
it from there.

## Install / re-apply / verify

```sh
./install.sh root@<backup-node>     # backup node first
./install.sh root@<master-node>
./check.sh   root@<node-a> root@<node-b>
```

Environment for all three scripts:

| Variable | Meaning |
|---|---|
| `KC_HA_SSH` | ssh command to use (default `ssh`), for example `ssh -J bastion` for a jump host |
| `KC_HA_NO_PLUGIN=1` | skip the `os-carp-vip-dhcp` plugin and its checks (no DHCP WAN) |
| `KC_HA_PLUGIN_DIR` | directory with the plugin `.pkg` and its `SHA256SUMS` (default `plugins/os-carp-vip-dhcp`) |
| `KC_HA_YES=1` | `drill.sh` only: do not ask before demoting the master |

`install.sh` is idempotent. It checks the plugin package against `SHA256SUMS` and installs
it only when the node has a different version, copies the scripts, hooks and cron files
(as root-owned files), creates `kc-ha.conf` from the sample if the node has none (an
existing one is never overwritten), stamps the version, applies the hooks live and prints
`kc-ha-status`. A node upgraded from a release that kept the vhid or the jumbo interface
names inside the scripts gets them carried into `kc-ha.conf`. The one live step that can disturb a node
is `pfsync0 maxupd` when it is still at the default (changing it restarts the pfsync bulk
sync, which demotes CARP for ~1 s and makes a MASTER hand over and preempt back), so the
script refuses to change it live on a MASTER and leaves it for the next reboot. That is
why the backup node goes first.

`check.sh` is the acceptance test and changes nothing. Per node: kc-ha version stamp,
plugin version, every
file byte-identical to the repo, keeper running with a fresh heartbeat, pfsync `syncok` +
`maxupd 8`, CARP demotion 0 / preempt on / not in maintenance mode, peer answering on the
SYNC link, `proto carp` pass rules loaded, no "master timed out" in today's log, every
`JUMBO_MTU_IFS` interface at its MTU and none of them a WAN device, one role
per node, backup-egress routes only on the BACKUP, default route on a real gateway **and
on that gateway's WAN device**, no kill-states on gateways, wan interface gateway set, Kea
HA in touch. Pair: interface **device names**, interface gateways, gateways, VIPs (minus
skew), tunables, hasync items, hook directories and `kc-ha.conf` identical; same OPNsense
version and pfsync protocol version (1400 on 26.1, 1500 on 26.7; not judged per node);
same loaded rule/NAT counts; state tables within 20%; exactly one MASTER.
Exit 0 = `ALL OK`, 1 = at least one `FAIL` line, 2 = a node could not be reached or has no
kit installed. `warn` lines do not fail the check.

`drill.sh root@<master> root@<backup> [hold] [probe-ip] [dns-vip] [https-url]` pre-flights
both nodes, asks for confirmation, probes an existing
ping flow, DNS at the VIP and one persistent HTTPS connection from the workstation, demotes
the master **detached on the node** (so it fails back by itself even if you lose it), and
reports losses per phase plus the hook log lines. Expect 0-1 lost pings and 0 DNS/HTTPS
failures. It is a real failover: run it in a maintenance window.

On a node, `kc-ha-status` prints one screen of state (`--kv` for scripts, `--settings` for
the settings in effect), `kc-ha-egress --show` prints what the routing script sees and
`kc-ha-egress --dry-run` the route commands it would run.

### After an OPNsense update

Files under `/usr/local/sbin` and `rc.syshook.d` are not owned by any package, so minor
updates keep them. A major upgrade (new ABI, e.g. 26.7 to 27.1) may drop or break the
vendored `os-carp-vip-dhcp` package (it is not in the OPNsense repos and will not be
re-installed by the firmware health check). Procedure, one node at a time, backup first:

1. Update the backup node, reboot it, `./check.sh`, fix anything with `./install.sh`.
2. Hand over (`sysctl net.inet.carp.demotion=240` on the master), confirm services on the
   new master, update the old master, reboot, `./install.sh` if needed, fail back
   (`=-240`), `./check.sh`.

### Uninstall

On each node, backup first:

```sh
rm -f /usr/local/sbin/kc-ha-* /usr/local/sbin/kc-unbound-master \
      /usr/local/etc/rc.syshook.d/carp/*-kc-* /usr/local/etc/rc.syshook.d/start/*-kc-* \
      /usr/local/etc/rc.syshook.d/start/95-pfsync-maxupd \
      /etc/cron.d/kc-ha-* /usr/local/etc/kc-ha.conf* /usr/local/etc/kc-ha.version
route delete -net 0.0.0.0/1; route delete -net 128.0.0.0/1     # backup-egress routes, if present
pkg delete os-carp-vip-dhcp                                    # only if no keeper is in use
```

The pfsync `maxupd` value and any jumbo MTU go back to the OPNsense defaults at the next
reboot.

## Security notes

- Everything here runs as **root on the firewall**, from CARP events, at boot and from
  cron. `kc-ha.conf` is sourced by those root shells: keep it owned by root and not
  writable by anyone else (`install.sh` creates it that way), and treat an edit of it as
  a change to the firewall.
- `install.sh`, `check.sh` and `drill.sh` need root SSH to both nodes. Use key login from
  an admin workstation, limit SSH on the firewall to the management network, and do not
  put a password in `KC_HA_SSH`.
- `kc-ha-egress` changes the kernel routing table (default route, `0/1` + `128/1` on the
  backup). It never touches firewall rules, NAT or `config.xml`. `BACKUP_EGRESS=no` and
  `PIN_DEFAULT_ROUTE=no` turn the two parts off.
- `kc-ha-tailscale-primary` stops `tailscaled` on the backup node for
  `TAILSCALE_HANDOVER_HOLD` seconds. If Tailscale is your only way in to that node, keep
  another one.
- The plugin package is third-party code installed as root; see below for where it comes
  from and how to verify it.
- No credentials, API keys or site addresses are stored in this repo or written by it.

## Troubleshooting

| Symptom | Look at |
|---|---|
| `install.sh` / `check.sh` say `VHID is not set` | set `VHID` in `/usr/local/etc/kc-ha.conf` on both nodes; the kit is inert until then |
| `check.sh`: `could not collect status from one of the nodes` | `ssh root@<node> kc-ha-status` by hand: ssh failing, or `install.sh` never ran on that node |
| `check.sh`: `/usr/local/... differs from repo` | the node runs another version of the kit: `./install.sh root@<node>` |
| `check.sh`: `carp demotion is N` | a drill or a manual `sysctl net.inet.carp.demotion=N` was left set (undo with `=-N`), or the pfsync bulk sync is stuck (`ifconfig pfsync0`) |
| `check.sh`: `no 'proto carp' pass rules loaded` | `configctl filter reload` on that node |
| Backup node has no internet | `kc-ha-egress --show` on it: role must be BACKUP and `egress_routes=2` |
| New master forwards nothing right after takeover | `kc-ha-egress --show` on it: the default route must be an upstream gateway on its WAN device; `grep kc-ha-egress` in the system log shows what was pinned |
| DNS fails after a takeover | `grep kc-ha-dns` in the system log; `DNS_CHECK_NAME` must resolve from the firewall |
| A master-only service does not start | `grep kc-ha-services` in the system log; the service must be enabled in the config of **both** nodes |

The scripts log to syslog with the tags `kc-ha-egress`, `kc-ha-dns`, `kc-ha-services`,
`kc-ha-tailscale` and `kc-jumbo-mtu` (System > Log Files > General, or
`/var/log/system/system_*.log`).

## Boot-time false MASTER (known, partly mitigated)

A node that boots while the peer is healthy can time out to MASTER on its VLAN VIPs for
~30 s before it is able to hear the real master (seen in the field on 26.1: the pf
ruleset is not fully loaded yet; demotion does not prevent a timeout). During that window
both nodes are MASTER and clients that learn the booting node's MAC lose connectivity.

Mitigation in this kit: a MASTER event within `BOOT_GRACE` seconds of boot while the pfsync
peer still answers on the SYNC link is treated as false by `kc-unbound-master` and
`kc-ha-master-services` (no restart, no service start). `kc-ha-egress` still acts (removing
the backup-egress routes on a false master is harmless and they come back on the BACKUP
event). `check.sh` warns on "master timed out" in the log. Prefer rebooting a node while the
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
  to the VIP looked fine. `check.sh` fails on differing device names.
- **Converting a live gateway to a CARP VIP**, per interface on the primary: change the
  interface address `.1` → `.2`, add CARP VIP `.1` (skew 0), `configctl interface
  reconfigure <opt>`, `configctl filter reload`. ~3 s in BACKUP then MASTER; routed traffic
  keeps flowing. Add the secondary's VIP only after the primary is MASTER, or the
  secondary times out to MASTER and duplicates the address.
- **After the first VIP, reload the filter**: `interface reconfigure` alone does not add the
  automatic `pass proto carp` rules; without them the node drops the peer's advertisements
  and both stay MASTER. `check.sh` counts those rules.
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
  subnet routes for both nodes in the admin console and set `TAILSCALE_NODES` so
  `kc-ha-tailscale-primary` hands them back to the master. For a 1:1 NAT that sends LAN
  traffic to a single tailnet host, assign `tailscale0` as an interface on both nodes
  (same `optN`), allow it, and add an outbound NAT rule on it to that host with the
  interface address as target, so replies come back to the node that sent them.
- A configured upstream gateway may be a private address (a cellular or CPE router LAN
  such as `192.168.4.1`): `kc-ha-egress` and `check.sh` accept a default route through
  any *configured* upstream gateway, whatever its address, so a WAN failover OPNsense
  has already made is not undone by a CARP event.
- Services that must run on one node only (UPnP/miniupnpd, mDNS/SSDP relay, ddclient):
  list them in `MASTER_ONLY_SERVICES` in `kc-ha.conf`, for example
  `MASTER_ONLY_SERVICES="miniupnpd"`. The service must be *enabled* in the config of
  **both** nodes (UPnP settings are not HA-synced; with UPnP disabled on one node,
  nothing serves it after a failover). `check.sh` compares the UPnP section.
- An mDNS relay (os-udpbroadcastrelay): install the plugin and configure the same
  relay on **both** nodes, then add `udpbroadcastrelay` to `MASTER_ONLY_SERVICES` and
  `OPNsense/udpbroadcastrelays` to `CHECK_COMPARE_CONFIG`. Do not add a separate
  CARP hook or cron job for it: two managers for one service fight.
## Adding a WAN

1. Add the NIC to both VMs, assign on both nodes, node IPs from a private /29.
2. CARP VIP for the public address (new vhid); DHCP WAN → add a keeper on both nodes.
3. Gateway on both nodes: Upstream, unique priority, kill-states off. `kc-ha-egress`
   picks the primary by priority on its own, no edit needed.
4. Outbound NAT rules for the new VIP; decide which policy routes / gateway groups may
   use it.

## Plugin package

`plugins/os-carp-vip-dhcp/` holds the package `install.sh` installs:
`os-carp-vip-dhcp-1.13.8`, built for OPNsense 26.7 (FreeBSD 15, amd64). It is third-party
software (BSD 2-Clause) from <https://github.com/toreamun/opnsense-plugins> and is not in
the OPNsense repos. `SHA256SUMS` records its checksum, `sig.bin` is a signature of
`SHA256SUMS` and `release.pub` the key it was made with (`SHA256SUMS.sig` is the same
signature in base64). To verify by hand:

```sh
cd plugins/os-carp-vip-dhcp
sha256sum -c SHA256SUMS
openssl dgst -sha256 -verify release.pub -signature sig.bin SHA256SUMS
```

The key sits next to the package, so this proves the files belong together, not who
built them. Compare with the upstream release if that matters to you.
