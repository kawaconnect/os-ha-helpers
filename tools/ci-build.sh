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
# Build steps of the GitLab CI pipeline (.gitlab-ci.yml). Runs on the FreeBSD 15
# build runner (tag freebsd-opnsense), as an unprivileged user, never on a firewall.
#
#   tools/ci-build.sh lint       make lint (opnsense/plugins + core Mk), sh -n on every shell file
#   tools/ci-build.sh style      phpcs with OPNsense core's ruleset.xml: errors fail, warnings are listed
#   tools/ci-build.sh package    make package; the .pkg lands in dist/
#
# opnsense/plugins and opnsense/core (HA_BUILD_BRANCH, default stable/26.7) are kept
# as shallow checkouts in HA_OPNSENSE_SRC (default ~/opnsense) and refreshed per job.
# The build tree is .build/ in the repository checkout: the plugins tree's Mk, Scripts
# and Templates (symlinked), core (symlinked) and a copy of sysutils/ha-helpers.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
src=${HA_OPNSENSE_SRC:-$HOME/opnsense}
branch=${HA_BUILD_BRANCH:-stable/26.7}
case "$branch" in *[!A-Za-z0-9/._-]*) echo "unsafe branch name" >&2; exit 2 ;; esac
w=$here/.build
plugin=$w/plugins/sysutils/ha-helpers

refresh() {
    for r in plugins core; do
        if [ ! -d "$src/$r/.git" ]; then
            mkdir -p "$src"
            git clone -q --depth 1 -b "$branch" "https://github.com/opnsense/$r.git" "$src/$r"
        else
            git -C "$src/$r" fetch -q --depth 1 origin "$branch"
            git -C "$src/$r" reset -q --hard FETCH_HEAD
        fi
        echo "opnsense/$r $branch at $(git -C "$src/$r" rev-parse --short=9 HEAD)"
    done
}

tree() {
    rm -rf "$w"
    mkdir -p "$w/plugins/sysutils"
    ln -s "$src/core" "$w/core"
    for d in Mk Scripts Templates; do ln -s "$src/plugins/$d" "$w/plugins/$d"; done
    cp -Rp "$here/sysutils/ha-helpers" "$plugin"
}

# PLUGIN_HASH (product_hash in the version file): this repository's commit
hash=$(git -C "$here" rev-parse --short=9 HEAD)

case "${1:-}" in
lint)
    refresh; tree
    make -C "$plugin" lint
    rc=0
    for f in $(cd "$here" && grep -rlE '^#!/bin/(sh|bash)|^#!/usr/local/bin/bash' sysutils tools) \
             $(cd "$here" && ls sysutils/ha-helpers/+*); do
        sh -n "$here/$f" || { echo "sh -n failed: $f" >&2; rc=1; }
    done
    [ $rc -eq 0 ] && echo "lint OK"
    exit $rc
    ;;
style)
    refresh; tree
    set --
    for d in "$plugin/src/etc/inc" "$plugin/src/opnsense"; do [ -d "$d" ] && set -- "$@" "$d"; done
    phpcs --standard="$src/core/ruleset.xml" --report=summary "$@" || true
    phpcs --standard="$src/core/ruleset.xml" --warning-severity=0 "$@"
    echo "style OK (phpcs, OPNsense ruleset: no errors)"
    ;;
package)
    refresh; tree
    make -C "$plugin" package PLUGIN_HASH="$hash"
    mkdir -p "$here/dist"
    rm -f "$here"/dist/os-ha-helpers-*.pkg
    cp "$plugin"/work/pkg/os-ha-helpers-*.pkg "$here/dist/"
    ls -l "$here"/dist/
    pkg info -F "$here"/dist/os-ha-helpers-*.pkg | sed -n '1,12p'
    ;;
*)
    echo "usage: $0 lint|style|package" >&2; exit 2 ;;
esac
