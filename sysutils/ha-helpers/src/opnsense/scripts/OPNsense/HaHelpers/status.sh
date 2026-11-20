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
# One-screen HA status of this node. Machine-readable with --kv (status plus
# every setting in effect as cfg:NAME=value); --settings prints only
# the settings.
. /usr/local/opnsense/scripts/OPNsense/HaHelpers/lib.sh
ha_load
role=$(ha_role)
carp=$(/sbin/ifconfig | awk '/carp:/ {printf "%s:%s ", $4, $2}')
nm=$(printf '%s' "$carp" | grep -o MASTER | wc -l | tr -d ' '); nb=$(printf '%s' "$carp" | grep -o BACKUP | wc -l | tr -d ' ')
def=$(ha_default_route)
egress=$(/usr/bin/netstat -rn -f inet | awk '$1=="0.0.0.0/1"||$1=="128.0.0.0/1"{printf "%s>%s ", $1, $2}')
pfs=$(/sbin/ifconfig pfsync0 2>/dev/null | awk '/syncok/ {s=$2} /maxupd/ {for(i=1;i<=NF;i++) if($i=="maxupd:") m=$(i+1); for(i=1;i<=NF;i++) if($i=="version:") v=$(i+1)} END {printf "syncok=%s maxupd=%s version=%s", s, m, v}')
states=$(/sbin/pfctl -si 2>/dev/null | awk '/current entries/ {print $3}')
dem=$(/sbin/sysctl -n net.inet.carp.demotion); pre=$(/sbin/sysctl -n net.inet.carp.preempt); pdf=$(/sbin/sysctl -n net.pfsync.carp_demotion_factor)
maint=$(grep -c '<carp_maintenance' /conf/config.xml 2>/dev/null)
peer=down; ha_peer_alive && peer=alive
gwst=$(for g in $GWS; do /sbin/ping -q -c 1 -W "$GW_PING_TIMEOUT_MS" "${g%@*}" >/dev/null 2>&1 && printf '%s:up ' "${g%@*}" || printf '%s:noping ' "${g%@*}"; done)
svcs=$(for s in $MASTER_ONLY_SERVICES; do case "$(/usr/local/sbin/pluginctl -s "$s" status 2>/dev/null)" in *"is running"*) printf '%s:running ' "$s" ;; *) printf '%s:stopped ' "$s" ;; esac; done)
keeper=$(/usr/local/etc/rc.d/carpvipdhcp status 2>/dev/null | head -1)
ver=$(/usr/sbin/pkg query %v os-ha-helpers 2>/dev/null)
kconf=$(ha_keeper_conflict)
if [ "${1:-}" = "--settings" ]; then ha_settings; exit 0; fi
if [ "${1:-}" = "--kv" ]; then
    printf 'vip=%s\nvhid=%s\nhost=%s\nrole=%s\nmasters=%s\nbackups=%s\ndemotion=%s\npreempt=%s\npfsync_demotion_factor=%s\nmaintenance=%s\npfsync=%s\nstates=%s\ndefault=%s\negress=%s\npeer=%s\nuptime=%s\ngateways=%s\nservices=%s\nkeeper=%s\nkeeper_routing=%s\nversion=%s\n' \
        "$VIP" "$VHID" "$(hostname)" "$role" "$nm" "$nb" "$dem" "$pre" "$pdf" "$maint" "$pfs" "$states" "$def" "$egress" "$peer" "$(ha_uptime)" "$gwst" "$svcs" "$keeper" "$kconf" "$ver"
    ha_settings | sed 's/^/cfg:/'
    exit 0
fi
cat <<EOT
$(hostname)  ha-helpers ${ver:-unversioned}  up $(ha_uptime)s
  role (vhid $VHID on $IF, VIP $VIP): ${role:-none}   VIPs: $nm MASTER / $nb BACKUP
  carp: demotion=$dem preempt=$pre pfsync_demotion_factor=$pdf maintenance_mode=$maint
  pfsync: $pfs   states: $states   peer $PEER: $peer
  default route: ${def:-none}   backup egress: ${egress:-none}
  upstream gateways: ${gwst:-none}
  master-only services: ${svcs:-none configured}
  carp-vip-dhcp: ${keeper:-not installed}
EOT
[ -n "$kconf" ] && echo "  CONFLICT: carp-vip-dhcp keeper also manages routes ($kconf): set 'Own default route by CARP role' Off and untick 'Backup egress'"
exit 0
