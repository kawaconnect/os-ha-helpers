#!/bin/sh
#
# Copyright (C) 2026 KawaConnect LLC
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice,
#    this list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
# INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
# AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
# AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
# OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
#
# Shared helpers for the ha-helpers scripts.
#   . /usr/local/opnsense/scripts/OPNsense/HaHelpers/lib.sh
# Settings come from /usr/local/etc/hahelpers.conf, which configd renders from
# the plugin settings (System: High Availability: Failover Helpers); the CARP
# VIPs, gateways and pfsync peer are read from /conf/config.xml. The defaults
# below apply when the rendered file is missing. Nothing in the scripts or
# hooks names a vhid, a device, an address, a service or a timing.
VHID=""                       # required: no default, the helpers are inert without it
BOOT_GRACE=120
MASTER_ONLY_SERVICES=""
JUMBO_MTU_IFS=""; JUMBO_MTU=9000
PFSYNC_MAXUPD=8
BACKUP_EGRESS=yes
PIN_DEFAULT_ROUTE=yes
UNUSABLE_DEFAULT_GWS="10.* 192.168.* 172.1[6-9].* 172.2[0-9].* 172.3[01].* 169.254.*"
GW_PING_TIMEOUT_MS=700
PEER_PING_TIMEOUT_MS=500
UNBOUND_RESTART_ON_MASTER=yes
DNS_CHECK_NAME=opnsense.org; DNS_CHECK_SERVER=127.0.0.1
DNS_RESTART_TRIES=2; DNS_SETTLE=4; DNS_RETRY_WAIT=3
EGRESS_HOOK_DELAY=2; SERVICES_HOOK_DELAY=3; SERVICES_BOOT_DELAY=15; SERVICE_SETTLE=1
LOCK_TIMEOUT=30
TAILSCALE_NODES=""            # Tailscale host names of both nodes; empty = tailscale_primary.sh does nothing
TAILSCALE_HANDOVER_HOLD=45
HA_SETTINGS="VHID BOOT_GRACE MASTER_ONLY_SERVICES JUMBO_MTU_IFS JUMBO_MTU PFSYNC_MAXUPD BACKUP_EGRESS PIN_DEFAULT_ROUTE UNUSABLE_DEFAULT_GWS GW_PING_TIMEOUT_MS PEER_PING_TIMEOUT_MS UNBOUND_RESTART_ON_MASTER DNS_CHECK_NAME DNS_CHECK_SERVER DNS_RESTART_TRIES DNS_SETTLE DNS_RETRY_WAIT EGRESS_HOOK_DELAY SERVICES_HOOK_DELAY SERVICES_BOOT_DELAY SERVICE_SETTLE LOCK_TIMEOUT TAILSCALE_NODES TAILSCALE_HANDOVER_HOLD"
HA_CONF=/usr/local/etc/hahelpers.conf
# the rendered file must belong to root and not be writable by others: root shells source it
if [ -r "$HA_CONF" ] && [ -z "$(/usr/bin/find "$HA_CONF" \( ! -user root -o -perm -0022 \) 2>/dev/null)" ]; then
    . "$HA_CONF"
fi
VHID=${HAHELPERS_VHID:-$VHID}
ha_on() { case "$1" in yes|YES|1|on|true) return 0 ;; esac; return 1; }
# "NAME=value" for every setting as it is in effect on this node
ha_settings() { for _v in $HA_SETTINGS; do eval "printf '%s=%s\\n' \"$_v\" \"\$$_v\""; done; }
# 0 if $1 is not usable as a default gateway by its address (missing, or matches UNUSABLE_DEFAULT_GWS)
ha_gw_unusable() {
    [ -n "$1" ] || return 0
    set -f
    for _p in $UNUSABLE_DEFAULT_GWS; do case "$1" in $_p) set +f; return 0 ;; esac; done
    set +f; return 1
}

# Sets: VIP IF (the reference CARP VIP and its device), PEER (pfsync peer IP),
# GWS ("gw@device ..." upstream IPv4 gateways, best priority first).
# The output is eval'ed by a root shell, so only values made of address and
# device-name characters are printed; anything else in config.xml reads as empty.
ha_load() {
    eval "$(/usr/local/bin/python3 - "$VHID" <<'PY'
import re, sys, xml.etree.ElementTree as ET
vhid = sys.argv[1]
safe = lambda s: s if re.match(r'^[0-9A-Za-z_.:-]*$', s or '') else ''
r = ET.parse('/conf/config.xml').getroot()
ifmap = {i.tag: (i.findtext('if') or '') for i in r.find('interfaces')}
vip = next((v for v in r.find('virtualip').iter('vip')
            if v.findtext('mode') == 'carp' and v.findtext('vhid') == vhid), None) if r.find('virtualip') is not None else None
print('VIP=%s' % safe(vip.findtext('subnet') if vip is not None else ''))
print('IF=%s' % safe(ifmap.get(vip.findtext('interface'), '') if vip is not None else ''))
print('PEER=%s' % safe(r.findtext('hasync/pfsyncpeerip') or ''))
gws = []
for it in r.find('OPNsense/Gateways').iter('gateway_item'):
    g = lambda k, d='': (it.findtext(k) or d)
    if g('disabled', '0') == '1' or g('force_down', '0') == '1' or g('defaultgw', '0') != '1':
        continue
    if g('ipprotocol', 'inet') != 'inet' or not g('gateway') or g('gateway') == 'dynamic':
        continue
    if not safe(g('gateway')) or not g('priority', '255').isdigit():
        continue
    gws.append((int(g('priority', '255')), g('gateway'), safe(ifmap.get(g('interface'), ''))))
gws.sort()
print('GWS="%s"' % ' '.join('%s@%s' % (x[1], x[2]) for x in gws))
PY
)"
}

# 0 if $1 answers one of two pings within GW_PING_TIMEOUT_MS
ha_gw_alive() { /sbin/ping -q -c 1 -W "$GW_PING_TIMEOUT_MS" "$1" >/dev/null 2>&1 || /sbin/ping -q -c 1 -W "$GW_PING_TIMEOUT_MS" "$1" >/dev/null 2>&1; }

# Device of a configured upstream gateway ("" if $1 is not one of them).
ha_gw_known() { for _g in $GWS; do [ "${_g%@*}" = "$1" ] && return 0; done; return 1; }
ha_gw_dev() { for _g in $GWS; do [ "${_g%@*}" = "$1" ] && { echo "${_g#*@}"; return 0; }; done; return 1; }

# Kernel default route as "gateway@device", empty if there is none. Read with
# route(8), not netstat: `netstat -rn` cuts long device names to the column
# width (vtnet1_vlan33 shows as vtnet1_vlan3). An interface route without a
# gateway reads as "link@<device>". Only the default entry itself counts
# (destination and mask 0.0.0.0), never a 0/1 backup-egress route.
ha_default_route() {
    /sbin/route -n get -inet default 2>/dev/null | awk '
        $1 == "destination:" { t = $2 } $1 == "mask:" { m = $2 }
        $1 == "gateway:" { g = $2 } $1 == "interface:" { d = $2 }
        END { if ((t == "0.0.0.0" || t == "default") && (m == "0.0.0.0" || m == "default") && d != "")
                  printf "%s@%s\n", (g != "" ? g : "link"), d }'
}

# CARP role of the reference VIP: MASTER, BACKUP, INIT or empty.
# (the trailing space keeps vhid 1 from matching vhid 10..19 on the same device)
ha_role() { /sbin/ifconfig "$IF" 2>/dev/null | awk -v v="vhid $VHID " '$0 ~ "carp: [A-Z]+ " v {print $2; exit}'; }

ha_uptime() { echo $(( $(date +%s) - $(/sbin/sysctl -n kern.boottime | sed -n 's/^{ sec = \([0-9]*\),.*/\1/p') )); }

# 0 if the pfsync peer answers on the SYNC link (two quick pings).
ha_peer_alive() {
    [ -n "$PEER" ] || return 1
    /sbin/ping -q -c 1 -W "$PEER_PING_TIMEOUT_MS" "$PEER" >/dev/null 2>&1 || /sbin/ping -q -c 1 -W "$PEER_PING_TIMEOUT_MS" "$PEER" >/dev/null 2>&1
}

# A MASTER role we should act on: not within BOOT_GRACE of boot while the peer
# is still alive (then it is most likely the boot-time false master).
ha_master_trusted() {
    [ "$(ha_role)" = MASTER ] || return 1
    [ "$(ha_uptime)" -ge "$BOOT_GRACE" ] && return 0
    ha_peer_alive && return 1
    return 0
}
