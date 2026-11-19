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
# Install (or update) the packages on ONE OPNsense node from a workstation:
# os-carp-vip-dhcp (third party, for a DHCP WAN) and os-ha-helpers. Repeat for
# every node, BACKUP NODE FIRST.
#
#   tools/install.sh root@<backup-node>
#   tools/install.sh root@<master-node>
#
# Every package is checked before it is copied: SHA256SUMS must match, and
# SHA256SUMS.sig must verify with a public key whose fingerprint is pinned
# below (a key file next to a package proves nothing on its own). A node that
# runs the old opnsense-ha script kit is migrated by the os-ha-helpers package
# itself: it imports /usr/local/etc/kc-ha.conf and archives the kit's files in
# /var/backups/ha-helpers-legacy-*.tar.
#
# Where os-ha-helpers comes from:
#   default              the latest GitHub release of github.com/kawaconnect/os-ha-helpers
#                        (built and signed by GitLab CI; no token needed): the .pkg,
#                        SHA256SUMS and SHA256SUMS.sig assets
#   HA_RELEASE=vX.Y.Z    that release instead of the latest
#   HA_RELEASE_SOURCE=gitlab  the GitLab release instead (private project: needs
#                        HA_GITLAB_TOKEN_FILE)
#   HA_PKG_DIR=<dir>     a local directory with the three files instead, e.g.
#                        packages/os-ha-helpers (the hand-built 1.0_2) or a CI artifact
# A release is verified exactly like a local directory: against keys/release.pub
# from THIS checkout, whose fingerprint is pinned below. The release does not carry
# the public key; a key downloaded next to a package would prove nothing.
#
# Environment:
#   HA_NO_CARPVIPDHCP=1  skip os-carp-vip-dhcp (no DHCP WAN)
#   HA_SSH="..."         ssh command (default "ssh"), e.g. "ssh -J bastion"
#   HA_RELEASE_API=...   release API base (default https://api.github.com/repos/kawaconnect/os-ha-helpers,
#                        or https://gitlab.kawalink.com/api/v4/projects/dean%2Fos-ha-helpers for gitlab)
#   HA_GITLAB_TOKEN_FILE file holding a GitLab token with read_api (the project is
#                        private); not needed for a public project
set -eu
case "${1:-}" in
    ""|-h|--help)
        echo "usage: $0 root@<node>      (one node per run, BACKUP node first)"
        echo "  HA_NO_CARPVIPDHCP=1  skip os-carp-vip-dhcp (no DHCP WAN)"
        echo "  HA_SSH=\"...\"         ssh command to use (default: ssh)"
        echo "  HA_RELEASE=vX.Y.Z    install that release (default: the latest release)"
        echo "  HA_PKG_DIR=<dir>     install from a local directory instead of a release"
        [ -n "${1:-}" ]; exit $? ;;
esac
host=$1
SSH=${HA_SSH:-ssh}
here=$(cd "$(dirname "$0")/.." && pwd)

# sha256 of the DER public key: os-ha-helpers (keys/release.pub) and the
# os-carp-vip-dhcp author's keys/release.pub in github.com/toreamun/opnsense-plugins
PIN_ha_helpers=00514a1f00bde5bd7f71c49d6ed46acaaf729fcd86512aa9043b21ac85402bd3
PIN_carp_vip_dhcp=382960036929f4ba411516d6b699600ea5fed7f4025a6c501a8aee8895100b99

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256 -q "$1"; fi; }

# verify <dir> <public key> <pinned fingerprint>: prints the package file
verify() {
    _pkg=$(ls "$1"/*.pkg 2>/dev/null | head -1)
    [ -n "$_pkg" ] || { echo "no .pkg in $1" >&2; return 1; }
    _fp=$(openssl pkey -pubin -in "$2" -outform DER 2>/dev/null | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -d' ' -f1)
    [ "$_fp" = "$3" ] || { echo "$2 is not the pinned key ($_fp)" >&2; return 1; }
    _tmp=$(mktemp); openssl base64 -d -in "$1/SHA256SUMS.sig" -out "$_tmp"
    if ! openssl dgst -sha256 -verify "$2" -signature "$_tmp" "$1/SHA256SUMS" >/dev/null; then
        rm -f "$_tmp"; echo "$1/SHA256SUMS: bad signature" >&2; return 1
    fi
    rm -f "$_tmp"
    _base=$(basename "$_pkg")
    grep -q "^$(sha256 "$_pkg")  \(\./\)\{0,1\}$_base\$" "$1/SHA256SUMS" || { echo "$_pkg does not match $1/SHA256SUMS" >&2; return 1; }
    echo "$_pkg"
}

# install <package file>: only if the node has another version
install_pkg() {
    _base=$(basename "$1" .pkg); _ver=${_base##*-}; _name=${_base%-*}
    if [ "$($SSH "$host" "pkg query %v $_name")" = "$_ver" ]; then
        echo "$_name $_ver already installed on $host"; return 0
    fi
    echo "installing $_name $_ver on $host"
    _rtmp=$($SSH "$host" "mktemp -d /tmp/ha-helpers.XXXXXXXX")
    case "$_rtmp" in /tmp/ha-helpers.*) ;; *) echo "could not create a temporary directory on $host" >&2; return 1 ;; esac
    $SSH "$host" "cat > $_rtmp/$_base.pkg" < "$1"
    $SSH "$host" "pkg install -U -y $_rtmp/$_base.pkg; rm -rf $_rtmp"   # -U: no repository update needed for a local file
    [ "$($SSH "$host" "pkg query %v $_name")" = "$_ver" ] || { echo "$_name $_ver did not install on $host" >&2; return 1; }
}

# fetch_release <dir>: download the os-ha-helpers release assets into <dir>
fetch_release() {
    _src=${HA_RELEASE_SOURCE:-github}
    _rel=${HA_RELEASE:-latest}
    case "$_rel" in latest) ;; v[0-9]*) ;; *) echo "HA_RELEASE must be latest or vX.Y.Z" >&2; return 1 ;; esac
    case "$_rel" in *[!A-Za-z0-9._-]*) echo "unsafe HA_RELEASE" >&2; return 1 ;; esac
    _hdr=$1/.hdr; : > "$_hdr"; chmod 600 "$_hdr"
    case "$_src" in
    github)
        _api=${HA_RELEASE_API:-https://api.github.com/repos/kawaconnect/os-ha-helpers}
        case "$_rel" in latest) _path=releases/latest ;; *) _path=releases/tags/$_rel ;; esac
        _key=browser_download_url ;;
    gitlab)
        _api=${HA_RELEASE_API:-https://gitlab.kawalink.com/api/v4/projects/dean%2Fos-ha-helpers}
        case "$_rel" in latest) _path=releases/permalink/latest ;; *) _path=releases/$_rel ;; esac
        _key=url
        if [ -n "${HA_GITLAB_TOKEN_FILE:-}" ]; then
            printf 'PRIVATE-TOKEN: %s\n' "$(cat "$HA_GITLAB_TOKEN_FILE")" > "$_hdr"
        fi ;;
    *) echo "HA_RELEASE_SOURCE must be github or gitlab" >&2; return 1 ;;
    esac
    curl -sSfL -H @"$_hdr" -o "$1/release.json" "$_api/$_path" || { rm -f "$_hdr"; echo "cannot read release $_rel from $_api" >&2; return 1; }
    _n=0
    for _url in $(tr ',' '\n' < "$1/release.json" | sed -n "s/.*\"$_key\": *\"\([^\"]*\)\".*/\1/p"); do
        _f=${_url##*/}
        case "$_f" in os-ha-helpers-*.pkg|SHA256SUMS|SHA256SUMS.sig) ;; *) continue ;; esac
        [ -e "$1/$_f" ] && continue
        curl -sSfL -H @"$_hdr" -o "$1/$_f" "$_url" || { rm -f "$_hdr"; echo "download of $_f failed" >&2; return 1; }
        _n=$((_n + 1))
    done
    rm -f "$_hdr" "$1/release.json"
    [ "$_n" -eq 3 ] || { echo "release $_rel does not have the three assets (.pkg, SHA256SUMS, SHA256SUMS.sig)" >&2; return 1; }
    echo "downloaded $_src release $_rel: $(ls "$1"/*.pkg | xargs -n1 basename)" >&2
}

if [ -n "${HA_PKG_DIR:-}" ]; then
    hhdir=$HA_PKG_DIR
else
    hhdir=$(mktemp -d "${TMPDIR:-/tmp}/ha-helpers-release.XXXXXXXX")
    trap 'rm -rf "$hhdir"' EXIT
    fetch_release "$hhdir"
fi
hh=$(verify "$hhdir" "$here/keys/release.pub" "$PIN_ha_helpers")
if [ -z "${HA_NO_CARPVIPDHCP:-}" ]; then
    cv=$(verify "$here/third-party/os-carp-vip-dhcp" "$here/third-party/os-carp-vip-dhcp/release.pub" "$PIN_carp_vip_dhcp")
    install_pkg "$cv"
fi
install_pkg "$hh"
echo "-- status after install:"
$SSH "$host" "/usr/local/opnsense/scripts/OPNsense/HaHelpers/status.sh"
echo "done: $host"
