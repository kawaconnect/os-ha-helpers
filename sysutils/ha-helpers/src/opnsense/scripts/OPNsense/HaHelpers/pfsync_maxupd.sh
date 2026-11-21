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
# HA: keep standby TCP state windows fresh so connections survive a planned
# failover (default maxupd 128 left them too stale; tested 2026-09-23 with 8).
# The value is PFSYNC_MAXUPD in the ha-helpers settings; empty = leave pfsync alone.
# Idempotent: changing maxupd restarts pfsync's bulk sync, which demotes CARP
# for ~1 s (a MASTER would hand over and preempt back), so only touch it when
# the value really differs.
#
#   pfsync_maxupd.sh early   early boot hook, before OPNsense configures pfsync. Acts
#                            only while pfsync0 has no syncdev: setting maxupd then
#                            starts no bulk update, so the only bulk at boot is the one
#                            OPNsense starts while the node is still BACKUP. Without it
#                            the start hook changed maxupd right after the node had
#                            preempted to MASTER, which started a second bulk during a
#                            CARP transition (seen to hang with demotion 240). syslog is
#                            not running yet: the result goes to EARLY_MARK and the next
#                            run without "early" logs it.
#   pfsync_maxupd.sh         start hook and apply.sh: set maxupd if it differs.
. /usr/local/opnsense/scripts/OPNsense/HaHelpers/lib.sh
EARLY_MARK=/var/run/hahelpers-pfsync.early
[ -n "$PFSYNC_MAXUPD" ] || exit 0
cur=$(/sbin/ifconfig pfsync0 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="maxupd:") print $(i+1)}')
if [ "${1:-}" = "early" ]; then
    /sbin/ifconfig pfsync0 >/dev/null 2>&1 || exit 0
    /sbin/ifconfig pfsync0 | /usr/bin/grep -q "syncdev:" && exit 0
    if [ "$cur" != "$PFSYNC_MAXUPD" ]; then
        /sbin/ifconfig pfsync0 maxupd "$PFSYNC_MAXUPD" || exit 0
    fi
    echo "${cur:-unset} $PFSYNC_MAXUPD" > "$EARLY_MARK"
    exit 0
fi
if [ -f "$EARLY_MARK" ]; then
    read -r _was _set < "$EARLY_MARK"
    rm -f "$EARLY_MARK"
    /usr/bin/logger -t hahelpers-pfsync "early boot: pfsync maxupd $_was -> $_set before syncdev"
fi
[ "$cur" = "$PFSYNC_MAXUPD" ] || /sbin/ifconfig pfsync0 maxupd "$PFSYNC_MAXUPD"
