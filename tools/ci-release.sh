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
# Release steps of the GitLab CI pipeline, for a protected v* tag only.
#
#   tools/ci-release.sh sign      SHA256SUMS + SHA256SUMS.sig for dist/*.pkg with the
#                                 release key from the CI variable HA_SIGNING_KEY
#   tools/ci-release.sh publish   upload dist/ to the generic package registry and
#                                 create the GitLab release with the three files as assets
#
# HA_SIGNING_KEY is a protected, masked and hidden file variable, environment scope
# "release": a file holding the base64 of the PEM private key (1Password Automation,
# "opnsense-ha release signing key (os-ha-helpers)"). The decoded key only exists in a
# 0600 temporary file for the length of the signing and is overwritten and removed.
# The public half is keys/release.pub in this repository; its fingerprint must equal
# PIN_ha_helpers in tools/install.sh, and the signature is verified before upload.
# keys/release.pub is never uploaded next to the package.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
dist=$here/dist
cd "$here"

pkgfile() {
    set -- "$dist"/os-ha-helpers-*.pkg
    [ -f "$1" ] && [ $# -eq 1 ] || { echo "expected exactly one package in $dist" >&2; exit 1; }
    echo "$1"
}

# tag vX.Y.Z must have a CHANGELOG section ## [X.Y.Z]
tagver() {
    case "${CI_COMMIT_TAG:-}" in v[0-9]*) ;; *) echo "not a v* tag pipeline" >&2; exit 1 ;; esac
    v=${CI_COMMIT_TAG#v}
    grep -q "^## \[$v\]" CHANGELOG.md || { echo "CHANGELOG.md has no section [$v]" >&2; exit 1; }
    echo "$v"
}

notes() {
    awk -v v="$1" '$0 ~ "^## \\[" v "\\]" {on=1; next} on && /^## \[/ {exit} on {print}' CHANGELOG.md
}

case "${1:-}" in
sign)
    tagver >/dev/null
    [ -n "${HA_SIGNING_KEY:-}" ] && [ -s "$HA_SIGNING_KEY" ] || { echo "HA_SIGNING_KEY is not available to this job" >&2; exit 1; }
    pin=$(sed -n 's/^PIN_ha_helpers=\([0-9a-f]*\)$/\1/p' tools/install.sh)
    fp=$(openssl pkey -pubin -in keys/release.pub -outform DER | sha256 -q)
    [ -n "$pin" ] && [ "$fp" = "$pin" ] || { echo "keys/release.pub does not match the pin in tools/install.sh" >&2; exit 1; }
    umask 077
    key=$(mktemp /tmp/ha-sign.XXXXXXXX)
    trap 'rm -P -f "$key" 2>/dev/null || rm -f "$key"' EXIT INT TERM
    openssl base64 -d -A -in "$HA_SIGNING_KEY" -out "$key"
    openssl pkey -in "$key" -pubout -outform DER | sha256 -q | grep -qx "$pin" || { echo "signing key is not the release key" >&2; exit 1; }
    tools/sign.sh "$key" "$dist" >/dev/null
    rm -P -f "$key"; trap - EXIT INT TERM
    [ "$(sha256 -q "$(pkgfile)")" = "$(sed -n 's/^\([0-9a-f]*\)  .*/\1/p' "$dist/SHA256SUMS")" ] || { echo "SHA256SUMS does not match the package" >&2; exit 1; }
    cat "$dist/SHA256SUMS"
    echo "signed and verified against keys/release.pub (pinned)"
    ;;
publish)
    v=$(tagver)
    pkg=$(pkgfile)
    base=$(basename "$pkg")
    pver=${base#os-ha-helpers-}; pver=${pver%.pkg}
    [ -f "$dist/SHA256SUMS" ] && [ -f "$dist/SHA256SUMS.sig" ] || { echo "dist/ is not signed" >&2; exit 1; }
    api=$CI_API_V4_URL/projects/$CI_PROJECT_ID
    reg=$api/packages/generic/os-ha-helpers/$pver
    for f in "$base" SHA256SUMS SHA256SUMS.sig; do
        curl -sSf -o /dev/null -H "JOB-TOKEN: $CI_JOB_TOKEN" --upload-file "$dist/$f" "$reg/$f?select=package_file"
        echo "uploaded $f"
    done
    body=$(notes "$v" | jq -Rs \
        --arg tag "$CI_COMMIT_TAG" --arg name "$CI_COMMIT_TAG (os-ha-helpers $pver)" \
        --arg reg "$reg" --arg pkg "$base" \
        '{tag_name: $tag, name: $name,
          description: ("Package os-ha-helpers " + ($pkg | sub("^os-ha-helpers-"; "") | sub("\\.pkg$"; "")) + ", built and signed by GitLab CI. Verify with keys/release.pub from the repository (fingerprint pinned in tools/install.sh), never with a key downloaded next to the package.\n" + .),
          assets: {links: [
            {name: $pkg, url: ($reg + "/" + $pkg), direct_asset_path: ("/" + $pkg), link_type: "package"},
            {name: "SHA256SUMS", url: ($reg + "/SHA256SUMS"), direct_asset_path: "/SHA256SUMS", link_type: "other"},
            {name: "SHA256SUMS.sig", url: ($reg + "/SHA256SUMS.sig"), direct_asset_path: "/SHA256SUMS.sig", link_type: "other"}]}}')
    code=$(curl -sS -o /tmp/ha-release.$$ -w '%{http_code}' -X POST -H "JOB-TOKEN: $CI_JOB_TOKEN" \
        -H 'Content-Type: application/json' --data "$body" "$api/releases")
    case "$code" in
        201) echo "release $CI_COMMIT_TAG created" ;;
        *) cat /tmp/ha-release.$$ >&2; rm -f /tmp/ha-release.$$; echo "release creation failed ($code)" >&2; exit 1 ;;
    esac
    rm -f /tmp/ha-release.$$
    ;;
*)
    echo "usage: $0 sign|publish" >&2; exit 2 ;;
esac
