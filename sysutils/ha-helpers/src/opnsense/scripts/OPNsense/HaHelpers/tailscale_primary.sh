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
# ha-helpers: the Tailscale LAN subnet routes must be served by the CARP master.
# Both nodes advertise the same routes and Tailscale keeps whichever node had
# them first, so after a failover/failback the backup can still hold them;
# Tailscale then drops what the master forwards into the tailnet. On the
# BACKUP, when this node holds the routes and the other node is online in the
# tailnet, take tailscaled down long enough for Tailscale to move the routes,
# then bring it back. Runs from the CARP hook and from cron; idempotent;
# logs to hahelpers-tailscale. Off unless TAILSCALE_NODES is set in the ha-helpers settings.
. /usr/local/opnsense/scripts/OPNsense/HaHelpers/lib.sh
if [ -z "${HAHELPERS_LOCKED:-}" ]; then
    HAHELPERS_LOCKED=1 exec /usr/bin/lockf -s -t 0 /var/run/hahelpers-tailscale.lock /bin/sh "$0" "$@"
fi
TS=/usr/local/bin/tailscale
[ -n "$TAILSCALE_NODES" ] && [ -x "$TS" ] || exit 0
ha_load
[ -n "$IF" ] || exit 0
[ "$(ha_role)" = BACKUP ] || exit 0

# "<routes held by this node> <online peers holding/advertising the same routes>"
read held peer <<EOF
$($TS status --json 2>/dev/null | TAILSCALE_NODES="$TAILSCALE_NODES" /usr/local/bin/python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(0, 0); sys.exit()
me = d.get("Self", {})
held = len(me.get("PrimaryRoutes") or [])
name = (me.get("HostName") or "").lower()
nodes = {n.lower() for n in os.environ.get("TAILSCALE_NODES", "").split()}
peer = sum(1 for p in (d.get("Peer") or {}).values()
           if p.get("Online") and (p.get("HostName") or "").lower() in nodes
           and (p.get("HostName") or "").lower() != name)
print(held, peer)')
EOF
[ "${held:-0}" -gt 0 ] || exit 0
if [ "${peer:-0}" -eq 0 ]; then
    logger -t hahelpers-tailscale "BACKUP holds the Tailscale LAN routes but the master is not online in the tailnet; keeping them"
    exit 0
fi
logger -t hahelpers-tailscale "BACKUP holds the Tailscale LAN routes; handing them to the master"
# tailscaled is started again even if this script is interrupted during the
# hold: it may be the only way in to this node
ts_start() { /usr/sbin/service tailscaled start >/dev/null 2>&1; }
trap ts_start EXIT
trap 'exit 1' HUP INT TERM
/usr/sbin/service tailscaled stop >/dev/null 2>&1
sleep "$TAILSCALE_HANDOVER_HOLD"
trap - EXIT
ts_start
if /usr/sbin/service tailscaled status >/dev/null 2>&1; then
    logger -t hahelpers-tailscale "BACKUP: tailscaled back up without the primary routes"
else
    logger -p daemon.err -t hahelpers-tailscale "BACKUP: tailscaled did NOT come back after the handover (service tailscaled start)"
    exit 1
fi
exit 0
