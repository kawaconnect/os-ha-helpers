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
# Jumbo frames for interfaces OPNsense does not size itself. Opt-in: does
# nothing unless JUMBO_MTU_IFS is set in the ha-helpers settings (a parent
# device and its VLAN; MTU from JUMBO_MTU).
#
# Background: when a VLAN sits on a parent interface that is assigned but
# disabled, OPNsense does not apply the parent's MTU, so the VLAN stays capped
# at 1500 while the hosts on it use 9000. Oversized frames are then dropped on
# receive without an ICMP error, which hangs routed TLS traffic. Netmap-based
# IPS also resets these MTUs.
#
# Device names are per node and a device that carries an upstream gateway (a
# WAN) is refused whatever the settings say: an MTU change re-inits it.
# Idempotent: only sets what differs. HAHELPERS_DRY=1 prints instead of acting.
. /usr/local/opnsense/scripts/OPNsense/HaHelpers/lib.sh
[ -n "$JUMBO_MTU_IFS" ] || exit 0
ha_load
say() { if [ -n "${HAHELPERS_DRY:-}" ]; then echo "$*"; else /usr/bin/logger -t hahelpers-mtu "$*"; fi; }
for i in $JUMBO_MTU_IFS; do
    wan=""
    for g in $GWS; do [ "${g#*@}" = "$i" ] && wan=${g%@*}; done
    if [ -n "$wan" ]; then
        say "REFUSED: $i carries upstream gateway $wan (a WAN); remove it from JUMBO_MTU_IFS"
        continue
    fi
    cur=$(/sbin/ifconfig "$i" 2>/dev/null | awk 'NR==1{for(n=1;n<=NF;n++) if($n=="mtu") print $(n+1)}')
    if [ -z "$cur" ]; then say "$i: no such interface"; continue; fi
    [ "$cur" = "$JUMBO_MTU" ] && continue
    if [ -n "${HAHELPERS_DRY:-}" ]; then say "+ ifconfig $i mtu $JUMBO_MTU   (now $cur)"
    else /sbin/ifconfig "$i" mtu "$JUMBO_MTU" && say "$i MTU $cur -> $JUMBO_MTU"; fi
done
exit 0
