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
# Self-heal a pfsync bulk update that hangs. Run every minute by cron (hahelpers_cron).
# A bulk that never completes keeps syncok=0, and pfsync keeps CARP demoted by the
# pfsync demotion factor, so the node can stay BACKUP for good. If this node's CARP
# demotion is at or above that factor AND syncok=0 for longer than WATCHDOG_GRACE
# seconds while the pfsync peer answers on the SYNC link, re-trigger the bulk by
# toggling maxupd. A manual demotion (drill, maintenance) keeps syncok=1 and is left
# alone; a missing peer is left to the kernel's own bulk timeout.
. /usr/local/opnsense/scripts/OPNsense/HaHelpers/lib.sh
[ -n "$VHID" ] || exit 0
WATCHDOG_GRACE=90
ST=/var/run/hahelpers-pfsync-watchdog.since
dem=$(/sbin/sysctl -n net.inet.carp.demotion 2>/dev/null)
fac=$(/sbin/sysctl -n net.pfsync.carp_demotion_factor 2>/dev/null)
pfs=$(/sbin/ifconfig pfsync0 2>/dev/null)
ok=$(echo "$pfs" | awk '/syncok:/ {print $2}')
peer=$(echo "$pfs" | awk '{for(i=1;i<=NF;i++) if($i=="syncpeer:") print $(i+1)}')
mu=$(echo "$pfs" | awk '{for(i=1;i<=NF;i++) if($i=="maxupd:") print $(i+1)}')
case "${dem:-x}${fac:-x}${mu:-x}" in *[!0-9-]*) rm -f "$ST"; exit 0 ;; esac
# an IPv4 peer address only (anything else, e.g. a parse of the next field, is "no peer")
case "$peer" in *[!0-9.]*|.*|*.|*..*) peer="" ;; esac
if [ -z "$peer" ] || [ "$ok" != "0" ] || [ "$fac" -le 0 ] || [ "$dem" -lt "$fac" ]; then
    rm -f "$ST"
    exit 0
fi
now=$(date +%s)
[ -f "$ST" ] || echo "$now" > "$ST"
read -r since < "$ST"
case "$since" in ''|*[!0-9]*) echo "$now" > "$ST"; exit 0 ;; esac
[ $((now - since)) -lt "$WATCHDOG_GRACE" ] && exit 0
/sbin/ping -c1 -t1 -q "$peer" >/dev/null 2>&1 || exit 0
if [ "$mu" -lt 255 ]; then alt=$((mu + 1)); else alt=$((mu - 1)); fi
/sbin/ifconfig pfsync0 maxupd "$alt" && /sbin/ifconfig pfsync0 maxupd "$mu"
/usr/bin/logger -p daemon.warning -t hahelpers-pfsync "pfsync bulk hung for $((now - since))s (demotion $dem, syncok 0): re-triggered"
rm -f "$ST"
exit 0
