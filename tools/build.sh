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
# Build os-ha-helpers on an OPNsense (or FreeBSD with pkg) build host and copy
# the package to packages/os-ha-helpers/. Never use a production firewall.
#
#   tools/build.sh root@<build-host>
#
# The host needs git, make and pkg. It builds in a fresh checkout of
# opnsense/plugins and opnsense/core (branch HA_BUILD_BRANCH, default
# stable/26.7) under /root/ha-helpers-build, or in HA_BUILD_TREE (a directory
# on the host that holds plugins/ and core/ checkouts, for hosts without
# internet access). Runs `make lint` before `make package`; a lint error stops
# the build. Sign the result with tools/sign.sh.
set -eu
[ $# -eq 1 ] || { echo "usage: $0 root@<build-host>"; exit 2; }
host=$1
SSH=${HA_SSH:-ssh}
here=$(cd "$(dirname "$0")/.." && pwd)
branch=${HA_BUILD_BRANCH:-stable/26.7}
tree=${HA_BUILD_TREE:-}
case "$branch$tree" in *[!A-Za-z0-9/._-]*) echo "unsafe branch or tree name" >&2; exit 2 ;; esac
out=$here/packages/os-ha-helpers

( cd "$here" && tar -cf - sysutils/ha-helpers ) | $SSH "$host" "env BRANCH='$branch' TREE='$tree' sh -c 'cat > /tmp/ha-helpers-src.tar'"
$SSH "$host" "env BRANCH='$branch' TREE='$tree' sh -s" <<'REMOTE'
set -eu
if [ -z "$TREE" ]; then
    TREE=/root/ha-helpers-build
    rm -rf "$TREE"; mkdir -p "$TREE"
    git clone -q --depth 1 -b "$BRANCH" https://github.com/opnsense/plugins.git "$TREE/plugins"
    git clone -q --depth 1 -b "$BRANCH" https://github.com/opnsense/core.git "$TREE/core"
fi
cd "$TREE/plugins"
rm -rf sysutils/ha-helpers
tar -xf /tmp/ha-helpers-src.tar && rm -f /tmp/ha-helpers-src.tar
cd sysutils/ha-helpers
make lint
make package
ls work/pkg/os-ha-helpers-*.pkg
REMOTE
pkg=$($SSH "$host" "sh -c 'ls ${tree:-/root/ha-helpers-build}/plugins/sysutils/ha-helpers/work/pkg/os-ha-helpers-*.pkg'" | tail -1)
base=$(basename "$pkg")
case "$base" in os-ha-helpers-*.pkg) ;; *) echo "no package built" >&2; exit 1 ;; esac
mkdir -p "$out"
rm -f "$out"/os-ha-helpers-*.pkg "$out/SHA256SUMS" "$out/SHA256SUMS.sig"
$SSH "$host" "cat $pkg" > "$out/$base"
echo "built $out/$base; now sign it: tools/sign.sh <private key>"
