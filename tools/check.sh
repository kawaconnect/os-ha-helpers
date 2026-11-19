#!/bin/sh
# Verify the HA pair end to end. Run after every OPNsense update or config change:
#   tools/check.sh [-c check.conf] root@<node-a> root@<node-b>
# Exit 0 = everything as expected. Any FAIL line: fix it, usually tools/install.sh <node>.
# HA_NO_CARPVIPDHCP=1 skips the carp-vip-dhcp checks (sites without a DHCP WAN).
# HA_SSH overrides the ssh command (default "ssh"), as in install.sh.
# Settings for this check (CHECK_*, see tools/check.conf.sample) come from the
# file given with -c, or HA_CHECK_CONF; the defaults below apply otherwise.
set -u
SSH=${HA_SSH:-ssh}
CHECK_STATE_TOLERANCE_PCT=20; CHECK_KEEPER_MAX_AGE=600
CHECK_KEA_URL=http://127.0.0.1:8000/
CHECK_MASTER_ONLY_ANCHORS=""  # default: the names in the master-only services
CHECK_REPLY_TO_IFS=""         # default: every interface with an enabled upstream gateway
CHECK_DEVICES_MAY_DIFFER=""   # logical interfaces whose device name may differ between the nodes
CHECK_COMPARE_CONFIG="installedpackages/miniupnpd/config"; CHECK_COMPARE_IGNORE="overridewanip"
conf=${HA_CHECK_CONF:-}
if [ "${1:-}" = "-c" ]; then conf=${2:-}; shift 2 || true; fi
[ $# -eq 2 ] || { echo "usage: $0 [-c check.conf] root@<node-a> root@<node-b>   (read-only; exit 0 = ALL OK, 1 = FAIL lines, 2 = could not check)"; exit 2; }
if [ -n "$conf" ]; then
    [ -r "$conf" ] || { echo "cannot read $conf"; exit 2; }
    . "$conf"
fi
here=$(cd "$(dirname "$0")/.." && pwd)
hhbase=$(basename "$(ls "$here"/packages/os-ha-helpers/*.pkg 2>/dev/null | head -1)" .pkg); hhver=${hhbase##*-}
plugdir=$here/third-party/os-carp-vip-dhcp
pkgbase=$(basename "$(ls "$plugdir"/*.pkg 2>/dev/null | head -1)" .pkg); pkgver=${pkgbase##*-}; pkgname=${pkgbase%-*}
H=/usr/local/opnsense/scripts/OPNsense/HaHelpers
fails=0
ok()   { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
warn() { echo "  warn $*"; }

# One ssh per node; the remote side runs sh (login shell is csh). Prints KEY=VALUE lines.
collect() {
    # env, not VAR=value: the login shell on the node is csh
    $SSH "$1" "env PKGNAME='$pkgname' CHECK_KEA_URL='$CHECK_KEA_URL' CHECK_MASTER_ONLY_ANCHORS='$CHECK_MASTER_ONLY_ANCHORS' CHECK_REPLY_TO_IFS='$CHECK_REPLY_TO_IFS' CHECK_COMPARE_CONFIG='$CHECK_COMPARE_CONFIG' CHECK_COMPARE_IGNORE='$CHECK_COMPARE_IGNORE' sh -s" <<'REMOTE'
H=/usr/local/opnsense/scripts/OPNsense/HaHelpers
echo "hostname=$(hostname)"
echo "version=$(opnsense-version -v)"
. $H/lib.sh 2>/dev/null
echo "pkg=$(pkg query %v "$PKGNAME")"
echo "hhpkg=$(pkg query %v os-ha-helpers)"
if pkg check -sq os-ha-helpers >/dev/null 2>&1; then echo "hhcheck=ok"; else echo "hhcheck=$(pkg check -s os-ha-helpers 2>&1 | tail -3 | tr '\n' ' ')"; fi
echo "hhenabled=$(/usr/local/sbin/configctl hahelpers status)"
# settings synced by HA (all but the per-node interface list) must match across the pair
echo "conf=$($H/status.sh --settings 2>/dev/null | grep -v -E '^JUMBO_MTU(_IFS)?=' | tr '\n' ' ')"
echo "localconf=$($H/status.sh --settings 2>/dev/null | grep -E '^JUMBO_MTU(_IFS)?=' | tr '\n' ' ')"
echo "kitfiles=$(ls /usr/local/sbin/kc-ha-* /usr/local/sbin/kc-unbound-master /usr/local/etc/rc.syshook.d/*/*-kc-* /usr/local/etc/rc.syshook.d/start/95-pfsync-maxupd /etc/cron.d/kc-ha-* /usr/local/etc/kc-ha.conf 2>/dev/null | tr '\n' ' ')"
echo "cron=$(crontab -l 2>/dev/null | grep -c "$H/")"
$H/status.sh --kv 2>/dev/null | sed 's/^/st:/'
echo "keeper_hb_age=$(( $(date +%s) - $(stat -f %m /var/run/carpvipdhcp-*.hb 2>/dev/null || echo 0) ))"
echo "keeper_last=$(grep -h 'INFO' /var/log/carpvipdhcp-*.log 2>/dev/null | tail -1 | cut -c1-120)"
# jumbo interfaces come from the per-node setting (JUMBO_MTU_IFS); "if=mtu/wanted" per interface
echo "jumbo=$(. $H/lib.sh 2>/dev/null; for i in $JUMBO_MTU_IFS; do printf '%s=%s/%s ' "$i" "$(ifconfig "$i" 2>/dev/null | awk 'NR==1{for(n=1;n<=NF;n++) if($n=="mtu") print $(n+1)}')" "$JUMBO_MTU"; done)"
echo "wandevs=$(. $H/lib.sh 2>/dev/null; ha_load 2>/dev/null; for g in $GWS; do printf '%s ' "${g#*@}"; done)"
echo "kea=$(curl -s -m 3 -X POST -H 'Content-Type: application/json' -d '{"command":"status-get","service":["dhcp4"]}' "$CHECK_KEA_URL" | /usr/local/bin/python3 -c 'import sys,json; h=json.load(sys.stdin)[0]["arguments"]["high-availability"][0]["ha-servers"]; print(h["local"]["role"], h["local"]["state"], "remote", h["remote"]["last-state"], "in-touch", h["remote"]["in-touch"])' 2>/dev/null)"
echo "carprules=$(pfctl -sr 2>/dev/null | grep -c 'proto carp')"
# anchors of master-only services legitimately exist on the master only
# (CHECK_MASTER_ONLY_ANCHORS, default: the names in MASTER_ONLY_SERVICES)
anch=$(echo ${CHECK_MASTER_ONLY_ANCHORS:-$MASTER_ONLY_SERVICES} | tr ' ' '|'); [ -n "$anch" ] || anch='-none-'
echo "rules=$(pfctl -sr 2>/dev/null | grep -v -E "^(nat-|rdr-)?anchor \"($anch)\"" | wc -l | tr -d ' ') nat=$(pfctl -sn 2>/dev/null | grep -v -E "^(nat-|rdr-)?anchor \"($anch)\"" | wc -l | tr -d ' ')"
export CHECK_REPLY_TO_IFS CHECK_COMPARE_CONFIG CHECK_COMPARE_IGNORE
echo "hooks=$(ls /usr/local/etc/rc.syshook.d/carp /usr/local/etc/rc.syshook.d/start | sort | tr '\n' ' ')"
# newest system log by mtime: the latest.log link can point at another day's file after a boot with a wrong clock
echo "timedout=$(grep -h -c 'master timed out' "$(ls -t /var/log/system/system_*.log 2>/dev/null | head -1)" 2>/dev/null)"
/usr/local/bin/python3 - <<'PY'
import xml.etree.ElementTree as ET
r=ET.parse("/conf/config.xml").getroot()
ifs=r.find("interfaces")
print("devices=" + ";".join("%s=%s" % (i.tag, i.findtext("if")) for i in ifs if i.findtext("if")))
print("ifgw=" + ";".join("%s=%s" % (i.tag, i.findtext("gateway")) for i in ifs if i.findtext("gateway")))
print("gateways=" + ";".join("%s/%s/%s/prio%s/up%s/ks%s/fd%s/far%s/dis%s" % (g.findtext("name"),g.findtext("interface"),g.findtext("gateway"),g.findtext("priority"),g.findtext("defaultgw") or 0,g.findtext("monitor_killstates") or 0,g.findtext("force_down") or 0,g.findtext("fargw") or 0,g.findtext("disabled") or 0) for g in r.find("OPNsense/Gateways").iter("gateway_item")), end="")
s=r.find("system"); print(" gw_switch_default=%s skip_rules_gw_down=%s" % (s.findtext("gw_switch_default"), s.findtext("skip_rules_gw_down")))
print("vips=" + ";".join("%s/%s/%s/skew%s" % (v.findtext("interface"),v.findtext("subnet"),v.findtext("vhid"),v.findtext("advskew")) for v in r.find("virtualip").iter("vip") if v.findtext("mode")=="carp"))
print("sysctl=" + ";".join("%s=%s" % (i.findtext("tunable"), i.findtext("value")) for i in r.find("sysctl").iter("item") if (i.findtext("value") or "") not in ("", "default")))
h=r.find("hasync"); print("hasync=pfsyncif=%s pfsyncversion=%s preempt_disabled=%s" % (h.findtext("pfsyncinterface"), h.findtext("pfsyncversion"), h.findtext("disablepreempt")))
import os
ign=set(os.environ.get("CHECK_COMPARE_IGNORE","").split())
cmpd=[]
for path in os.environ.get("CHECK_COMPARE_CONFIG","").split():
    # an entry with child elements (a plugin's list of instances) compares by its children's values
    val=lambda c: "(" + ",".join("%s=%s" % (x.tag, (x.text or "").strip()) for x in c if x.tag not in ign) + ")" if len(c) else (c.text or "")
    u=r.find(path); cmpd.append(path+"{"+(";".join("%s=%s" % (c.tag, val(c)) for c in u if c.tag not in ign) if u is not None else "none")+"}")
print("cmpconfig=" + " ".join(cmpd))
want=os.environ.get("CHECK_REPLY_TO_IFS","").split() or sorted({g.findtext("interface") for g in r.find("OPNsense/Gateways").iter("gateway_item") if (g.findtext("disabled") or "0")!="1" and (g.findtext("defaultgw") or "0")=="1" and (g.findtext("ipprotocol") or "inet")=="inet"})
print("replyto=" + " ".join("%s:%s" % (i, "set" if (ifs.find(i) is not None and ifs.find(i).findtext("gateway")) else "MISSING") for i in want))
print("keepers=%d" % len(list(r.find("OPNsense/CarpVipDhcp/keepers").iter("keeper"))) if r.find("OPNsense/CarpVipDhcp/keepers") is not None else "keepers=0")
print("pyok=1")
PY
REMOTE
}
get() { printf '%s\n' "$2" | sed -n "s|^$1=||p" | head -1; }

A=$(collect "$1"); B=$(collect "$2")
for n in A B; do
    eval "D=\$$n"
    [ -n "$(get hostname "$D")" ] && [ -n "$(get st:role "$D")$(get st:masters "$D")" ] || { echo "could not collect status from one of the nodes (ssh failed, or os-ha-helpers is not installed there): nothing was checked"; exit 2; }
done
for n in A B; do
    eval "D=\$$n"
    [ "$(get pyok "$D")" = 1 ] || { echo "the config.xml part of the collection failed on $(get hostname "$D"): nothing was checked"; exit 2; }
    host=$(get hostname "$D"); echo "== $host ($(get version "$D")) os-ha-helpers $(get hhpkg "$D")"
    [ "$(get hhpkg "$D")" = "$hhver" ] && ok "os-ha-helpers $hhver" || fail "os-ha-helpers is '$(get hhpkg "$D")', repo has $hhver"
    [ "$(get hhcheck "$D")" = ok ] && ok "installed files match the package (pkg check -s)" || fail "pkg check -s os-ha-helpers: $(get hhcheck "$D")"
    case "$(get hhenabled "$D")" in *"is running"*) ok "helpers enabled with a reference VHID" ;; *) fail "helpers disabled or no reference VHID (System: High Availability: Failover Helpers)" ;; esac
    [ "$(get cron "$D")" = 2 ] && ok "2 cron jobs (master-only services, Tailscale handover)" || fail "$(get cron "$D") ha-helpers cron jobs, want 2 (configctl hahelpers restart)"
    [ -z "$(get kitfiles "$D")" ] && ok "no files of the old script kit" || fail "files of the old script kit are still present: $(get kitfiles "$D")"
    if [ -z "${HA_NO_CARPVIPDHCP:-}" ]; then
        [ "$(get pkg "$D")" = "$pkgver" ] && ok "$pkgname $pkgver" || fail "$pkgname is '$(get pkg "$D")', repo has $pkgver"
        case "$(get st:keeper "$D")" in *"is running"*) ok "keeper: $(get st:keeper "$D")" ;; *) fail "keeper not running" ;; esac
        [ "$(get keeper_hb_age "$D")" -lt "$CHECK_KEEPER_MAX_AGE" ] 2>/dev/null && ok "keeper heartbeat $(get keeper_hb_age "$D")s old; last: $(get keeper_last "$D")" || fail "keeper heartbeat stale ($(get keeper_hb_age "$D")s): $(get keeper_last "$D")"
        [ "$(get keepers "$D")" -ge 1 ] 2>/dev/null && ok "$(get keepers "$D") keeper(s) configured" || fail "no keeper configured"
    fi
    ok "settings: $(get conf "$D") $(get localconf "$D")"
    # the pfsync protocol version follows the OPNsense release (1400 on 26.1, 1500 on 26.7): only compared across the pair below
    mx=$(get st:cfg:PFSYNC_MAXUPD "$D")
    case "$(get st:pfsync "$D")" in "syncok=1 maxupd=${mx:-?*} version="?*) ok "pfsync $(get st:pfsync "$D")" ;; *) fail "pfsync: $(get st:pfsync "$D") (want syncok=1${mx:+ maxupd=$mx})" ;; esac
    [ "$(get st:demotion "$D")" = 0 ] && ok "carp demotion 0" || fail "carp demotion is $(get st:demotion "$D") (a drill left it set, or pfsync bulk stuck: check 'syncok')"
    [ "$(get st:preempt "$D")" = 1 ] && ok "carp preempt on" || fail "carp preempt off"
    [ "$(get st:maintenance "$D")" = 0 ] && ok "not in persistent CARP maintenance mode" || fail "persistent CARP maintenance mode is on"
    [ "$(get st:peer "$D")" = alive ] && ok "pfsync peer answers on SYNC" || fail "pfsync peer does not answer on SYNC"
    [ "$(get carprules "$D")" -ge 2 ] 2>/dev/null && ok "$(get carprules "$D") 'proto carp' rules loaded" || fail "no 'proto carp' pass rules loaded (run: configctl filter reload)"
    [ "$(get timedout "$D")" = 0 ] && ok "no 'master timed out' events in today's log" || warn "$(get timedout "$D") 'master timed out' event(s) in today's log (boot-time dual master?)"
    jm=$(get jumbo "$D")
    if [ -z "$jm" ]; then ok "no jumbo interfaces configured (JUMBO_MTU_IFS empty)"; else
        for e in $jm; do i=${e%%=*}; v=${e#*=}
            case " $(get wandevs "$D") " in *" $i "*) fail "JUMBO_MTU_IFS lists $i, which carries an upstream gateway (a WAN); the hook refuses it" ;; esac
            [ "${v%/*}" = "${v#*/}" ] && ok "$i mtu ${v%/*}" || fail "$i mtu '${v%/*}', want ${v#*/} (run /usr/local/etc/rc.syshook.d/start/97-hahelpers-mtu)"
        done
    fi
    case "$(get kea "$D")" in *"in-touch True"*) ok "kea HA: $(get kea "$D")" ;; "") warn "kea HA status not available (not using Kea HA?)" ;; *) fail "kea HA: $(get kea "$D")" ;; esac
    nm=$(get st:masters "$D"); nb=$(get st:backups "$D"); eg=$(get st:egress "$D"); def=$(get st:default "$D")
    if [ "$nm" -gt 0 ] && [ "$nb" -gt 0 ]; then fail "mixed CARP roles: $nm MASTER / $nb BACKUP"
    elif [ "$nm" -gt 0 ]; then [ -z "$eg" ] && ok "MASTER ($nm VIPs), no backup-egress routes" || fail "MASTER still has egress routes: $eg"
    elif [ "$nb" -gt 0 ]; then vip=$(get st:vip "$D"); [ "$(printf '%s' "$eg" | wc -w)" -eq 2 ] && [ "$eg" = "0.0.0.0/1>$vip 128.0.0.0/1>$vip " ] && ok "BACKUP ($nb VIPs), egress via master: $eg" || fail "BACKUP egress routes are '$eg', want 0/1 and 128/1 via $vip"
    else fail "no CARP VIPs"; fi
    # a configured gateway may be private (CPE / cellular router LAN): judge it by its device, not its address
    dgw=${def%@*}; known=no; [ -n "$dgw" ] && case ";$(get gateways "$D");" in *"/$dgw/"*) known=yes ;; esac
    bad=no; [ -z "$dgw" ] && bad=yes
    if [ "$known" = no ]; then set -f; for pat in $(get st:cfg:UNUSABLE_DEFAULT_GWS "$D"); do case "$dgw" in $pat) bad=yes ;; esac; done; set +f; fi
    case "$bad" in yes) fail "default route is '${def:-none}'" ;;
        *) dev=${def#*@}; gw=${def%@*}; want=$(printf '%s\n' "$(get devices "$D")" | tr ';' '\n' | sed -n "s/^$(printf '%s' "$(get gateways "$D")" | tr ';' '\n' | grep "/$gw/" | cut -d/ -f2)=//p")
           if [ -n "$want" ] && [ "$want" != "$dev" ]; then fail "default route $gw is on $dev, its WAN device is $want"; else ok "default route $def"; fi ;;
    esac
    case "$(get gateways "$D")" in *"/ks1/"*) fail "a gateway has kill-states on" ;; esac
    case "$(get gateways "$D")" in *"gw_switch_default=1"*) ok "gw_switch_default on" ;; *) warn "gw_switch_default off (no automatic WAN failover of the default route)" ;; esac
    # reply-to needs the interface gateway on every WAN interface (CHECK_REPLY_TO_IFS, default: interfaces with an enabled upstream gateway)
    for e in $(get replyto "$D"); do [ "${e#*:}" = set ] && ok "${e%%:*} interface has its gateway set (reply-to)" || fail "${e%%:*} interface has no gateway (no reply-to on its rules)"; done
done
echo "== pair"
for k in devices ifgw gateways vips sysctl hasync hooks conf cmpconfig; do   # conf = synced ha-helpers settings; cmpconfig = CHECK_COMPARE_CONFIG sections
    va=$(get $k "$A"); vb=$(get $k "$B")
    case $k in
        vips) va=$(printf '%s' "$va" | sed 's/skew[0-9]*//g'); vb=$(printf '%s' "$vb" | sed 's/skew[0-9]*//g') ;;   # skew differs by design
        devices)   # drop the interfaces listed in CHECK_DEVICES_MAY_DIFFER, and compare in name order
            md=" $CHECK_DEVICES_MAY_DIFFER "
            flt() { printf '%s\n' "$1" | tr ';' '\n' | grep . | while IFS= read -r e; do case "$md" in *" ${e%%=*} "*) ;; *) echo "$e" ;; esac; done | sort | tr '\n' ';'; }
            va=$(flt "$va"); vb=$(flt "$vb")
            for w in $md; do case " $(get wandevs "$A" | tr ' ' '\n' | while read -r d; do printf '%s' "$(get devices "$A")" | tr ';' '\n' | sed -n "s/=$d\$//p"; done | tr '\n' ' ') " in *" $w "*) fail "CHECK_DEVICES_MAY_DIFFER lists $w, which carries an enabled upstream gateway: its device must match" ;; esac; done ;;
    esac
    [ "$va" = "$vb" ] && ok "$k identical on both nodes" || { fail "$k differ (not HA-synced; edit both):"; echo "    A: $va"; echo "    B: $vb"; }
done
[ "$(get version "$A")" = "$(get version "$B")" ] && ok "same OPNsense version" || fail "versions differ: $(get version "$A") vs $(get version "$B")"
pa=$(get st:pfsync "$A"); pb=$(get st:pfsync "$B")
[ "${pa##*version=}" = "${pb##*version=}" ] && ok "same pfsync protocol version (${pa##*version=})" || fail "pfsync protocol versions differ: ${pa##*version=} vs ${pb##*version=}"
[ "$(get rules "$A")" = "$(get rules "$B")" ] && ok "same loaded rule/NAT counts ($(get rules "$A"))" || fail "rule/NAT counts differ: $(get rules "$A") vs $(get rules "$B")"
sa=$(get st:states "$A"); sb=$(get st:states "$B"); d=$((sa - sb)); [ $d -lt 0 ] && d=$((-d))
tol=$CHECK_STATE_TOLERANCE_PCT
[ $((d * 100)) -le $(( (sa + 1) * tol )) ] && ok "state tables within ${tol}% ($sa / $sb)" || fail "state tables differ by more than ${tol}% ($sa / $sb): pfsync not replicating?"
ma=$(get st:masters "$A"); mb=$(get st:masters "$B")
[ "$ma" -gt 0 ] && [ "$mb" -gt 0 ] && fail "both nodes MASTER (split brain)"
[ "$ma" -eq 0 ] && [ "$mb" -eq 0 ] && fail "no node is MASTER"
[ "$((ma + $(get st:backups "$A")))" -eq "$((mb + $(get st:backups "$B")))" ] && ok "same number of CARP VIPs ($((ma + $(get st:backups "$A"))))" || fail "VIP count differs"
echo; [ $fails -eq 0 ] && echo "ALL OK" || echo "$fails FAIL(s)"
exit $((fails > 0))
