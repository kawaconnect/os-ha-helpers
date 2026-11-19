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
# ha-helpers: services that must run on exactly one node (MASTER_ONLY_SERVICES in
# the ha-helpers settings, e.g. miniupnpd, udpbroadcastrelay or ddclient): started on the
# master, stopped elsewhere. OPNsense restarts services on reconfigure
# regardless of role, so this also runs from cron. Boot-time false MASTER
# events are ignored (ha_master_trusted). Idempotent; a stop/start is logged
# (hahelpers-services). The service must be enabled in the config of BOTH nodes.
#
# Start = `pluginctl -s <svc> start`; if that leaves it not running (plugins
# whose config file is only rendered by their configure hook, e.g. miniupnpd
# on a node where it was never enabled before) fall back to the plugin's own
# bootup configure hook, scoped to that plugin: `pluginctl -c bootup:<svc>`
# (renders the config and starts). A start that still fails is logged as an error.
# one at a time: a CARP transition fires the hook once per VIP
. /usr/local/opnsense/scripts/OPNsense/HaHelpers/lib.sh
if [ -z "${HAHELPERS_LOCKED:-}" ]; then
    HAHELPERS_LOCKED=1 exec /usr/bin/lockf -t "$LOCK_TIMEOUT" /var/run/hahelpers-services.lock /bin/sh "$0" "$@"
fi
[ -n "$MASTER_ONLY_SERVICES" ] || exit 0
ha_load
[ -n "$IF" ] || exit 0
role=$(ha_role)
want=stopped
if [ "$role" = MASTER ]; then
    if ha_master_trusted; then want=running; else exit 0; fi
fi
state() { case "$(/usr/local/sbin/pluginctl -s "$1" status 2>/dev/null)" in *"is running"*) echo running ;; *) echo stopped ;; esac; }
for svc in $MASTER_ONLY_SERVICES; do
    [ "$(state "$svc")" = "$want" ] && continue
    if [ "$want" = running ]; then
        /usr/local/sbin/pluginctl -s "$svc" start >/dev/null 2>&1; sleep "$SERVICE_SETTLE"
        if [ "$(state "$svc")" != running ]; then
            /usr/local/sbin/pluginctl -c "bootup:$svc" >/dev/null 2>&1; sleep "$SERVICE_SETTLE"
        fi
        if [ "$(state "$svc")" = running ]; then logger -t hahelpers-services "MASTER: started $svc"
        else logger -p daemon.err -t hahelpers-services "MASTER: FAILED to start $svc (is it enabled in this node's config?)"; fi
    else
        /usr/local/sbin/pluginctl -s "$svc" stop >/dev/null 2>&1; sleep "$SERVICE_SETTLE"
        if [ "$(state "$svc")" = stopped ]; then logger -t hahelpers-services "${role:-no-carp}: stopped $svc"
        else logger -p daemon.err -t hahelpers-services "${role:-no-carp}: FAILED to stop $svc"; fi
    fi
done
exit 0
