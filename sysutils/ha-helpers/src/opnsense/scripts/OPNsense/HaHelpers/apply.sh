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
# Apply the settings now (configd "hahelpers start|reload|restart"): the same
# steps the hooks take at boot. Every step is idempotent. The only one that can
# disturb a running node is pfsync maxupd: changing it restarts the pfsync bulk
# sync, which demotes CARP for ~1 s (a MASTER hands over and preempts back), so
# on a MASTER it is left for the next boot and a warning is logged.
. /usr/local/opnsense/scripts/OPNsense/HaHelpers/lib.sh
H=/usr/local/opnsense/scripts/OPNsense/HaHelpers

# cron jobs come from hahelpers_cron(); regenerate the crontab when the helpers
# were switched on or off since it was last written
if [ -n "$VHID" ]; then want=1; else want=0; fi
have=$(/usr/bin/grep -c "$H/master_services.sh" /var/cron/tabs/root 2>/dev/null)
if [ "${have:-0}" -gt 0 ]; then have=1; else have=0; fi
[ "$want" = "$have" ] || /usr/local/sbin/configctl -dq cron restart

if [ -z "$VHID" ]; then
    echo "OK"
    exit 0
fi
$H/egress.sh
$H/jumbo_mtu.sh
$H/master_services.sh
cur=$(/sbin/ifconfig pfsync0 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="maxupd:") print $(i+1)}')
if [ -n "$PFSYNC_MAXUPD" ] && [ "$cur" != "$PFSYNC_MAXUPD" ]; then
    if /sbin/ifconfig | grep -q "carp: MASTER"; then
        /usr/bin/logger -t hahelpers-pfsync "pfsync maxupd is $cur, setting is $PFSYNC_MAXUPD; not changed on a CARP MASTER (would cause a ~1 s CARP flip), applies at the next boot"
    else
        $H/pfsync_maxupd.sh
    fi
fi
echo "OK"
