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
# ha-helpers: after this node becomes CARP MASTER, restart Unbound so it drops any
# upstream failures it cached while it was BACKUP (seen in the failover test:
# the new master answered SERVFAIL until Unbound was restarted), then verify
# resolution and retry. Only acts for the reference VIP (VHID in the settings)
# so one failover triggers one restart, not one per VIP. Logs to syslog
# (hahelpers-dns). Ignores the boot-time false MASTER (ha_master_trusted).
#
# Usage: unbound_master.sh [<vhid>@<iface>]   (the carp hook passes its event;
# events of other VIPs exit here, before config.xml is parsed)
# Settings (lib.sh names): UNBOUND_RESTART_ON_MASTER, DNS_CHECK_NAME,
# DNS_CHECK_SERVER, DNS_RESTART_TRIES, DNS_SETTLE, DNS_RETRY_WAIT, BOOT_GRACE.
. /usr/local/opnsense/scripts/OPNsense/HaHelpers/lib.sh
if [ "${1:-}" = "--dry-run" ]; then
    # what a MASTER event of the reference VIP would do now; changes nothing
    ha_load
    if ! ha_on "$UNBOUND_RESTART_ON_MASTER"; then echo "Unbound restart on takeover is off"
    elif [ -z "$IF" ]; then echo "no CARP VIP with vhid ${VHID:-unset}: nothing to do"
    elif [ "$(ha_role)" != MASTER ]; then echo "$(ha_role): a MASTER event of vhid $VHID would restart Unbound and check $DNS_CHECK_NAME @$DNS_CHECK_SERVER"
    elif ! ha_master_trusted; then echo "MASTER within boot grace while the peer answers: the event would be ignored"
    else echo "MASTER: a MASTER event of vhid $VHID would restart Unbound and check $DNS_CHECK_NAME @$DNS_CHECK_SERVER"; fi
    /usr/bin/drill -Q "$DNS_CHECK_NAME" @"$DNS_CHECK_SERVER" 2>/dev/null | grep -qE '^[0-9a-f:.]+$' && echo "resolving $DNS_CHECK_NAME @$DNS_CHECK_SERVER now: ok" || echo "resolving $DNS_CHECK_NAME @$DNS_CHECK_SERVER now: FAILED"
    exit 0
fi
ha_on "$UNBOUND_RESTART_ON_MASTER" || exit 0
[ -z "${1:-}" ] || [ "${1%%@*}" = "$VHID" ] || exit 0
ha_load
[ -n "$IF" ] || exit 0
[ "$(ha_role)" = MASTER ] || exit 0
if ! ha_master_trusted; then
    logger -t hahelpers-dns "MASTER event $(ha_uptime)s after boot while peer $PEER is alive: ignored (boot grace ${BOOT_GRACE}s)"
    exit 0
fi
sleep "$DNS_SETTLE"    # let egress.sh settle the routes first
ok() { /usr/bin/drill -Q "$DNS_CHECK_NAME" @"$DNS_CHECK_SERVER" 2>/dev/null | grep -qE '^[0-9a-f:.]+$'; }
try=1
while [ "$try" -le "$DNS_RESTART_TRIES" ]; do
    /usr/local/sbin/configctl unbound restart >/dev/null 2>&1
    sleep "$DNS_RETRY_WAIT"
    if ok; then logger -t hahelpers-dns "MASTER: unbound restarted, resolving ok (try $try)"; exit 0; fi
    try=$((try + 1))
done
logger -p daemon.err -t hahelpers-dns "MASTER: unbound restarted $DNS_RESTART_TRIES time(s) but still NOT resolving $DNS_CHECK_NAME @$DNS_CHECK_SERVER"
exit 1
