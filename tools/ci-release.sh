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
#   tools/ci-release.sh github    create the same release on GitHub (GITHUB_RELEASE_REPO,
#                                 default kawaconnect/os-ha-helpers) with the three files
#                                 attached, once the push mirror has carried the tag there
#
# GITHUB_RELEASE_TOKEN: protected, masked and hidden file variable, environment scope
# "github-release", holding a fine-grained GitHub token for that one repository with
# Contents read/write (1Password Automation "GitHub os-ha-helpers release token").
# Without it the github step exits 3 (a warning in the pipeline, the GitLab release stands).
# The same step runs by hand: CI_COMMIT_TAG=vX.Y.Z CI_COMMIT_SHA=<commit>
# GITHUB_RELEASE_TOKEN=<token file> tools/ci-release.sh github, with the signed files in dist/.
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

sha() { if command -v sha256 >/dev/null 2>&1; then sha256 -q "$1"; else sha256sum "$1" | cut -d' ' -f1; fi; }

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
github)
    v=$(tagver)
    pkg=$(pkgfile)
    base=$(basename "$pkg")
    pver=${base#os-ha-helpers-}; pver=${pver%.pkg}
    [ -f "$dist/SHA256SUMS" ] && [ -f "$dist/SHA256SUMS.sig" ] || { echo "dist/ is not signed" >&2; exit 1; }
    [ "$(sha "$pkg")" = "$(sed -n 's/^\([0-9a-f]*\)  .*/\1/p' "$dist/SHA256SUMS")" ] || { echo "SHA256SUMS does not match the package" >&2; exit 1; }
    if [ -z "${GITHUB_RELEASE_TOKEN:-}" ] || [ ! -s "$GITHUB_RELEASE_TOKEN" ]; then
        echo "GITHUB_RELEASE_TOKEN is not available: GitHub release not published" >&2; exit 3
    fi
    repo=${GITHUB_RELEASE_REPO:-kawaconnect/os-ha-helpers}
    case "$repo" in *[!A-Za-z0-9/._-]*) echo "unsafe repo name" >&2; exit 2 ;; esac
    gh=https://api.github.com/repos/$repo
    tmp=$(mktemp -d /tmp/ha-gh.XXXXXXXX)
    trap 'rm -rf "$tmp"' EXIT INT TERM
    umask 077
    printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28\n' "$(tr -d '\r\n' < "$GITHUB_RELEASE_TOKEN")" > "$tmp/h"
    ghc() { curl -sS -H @"$tmp/h" "$@"; }
    # the push mirror carries the tag; wait for it (up to 15 minutes) and check it is this commit
    i=0
    while :; do
        ghc -o "$tmp/ref" "$gh/git/ref/tags/$CI_COMMIT_TAG" || true
        obj=$(jq -r '.object.sha // empty' "$tmp/ref" 2>/dev/null)
        if [ -n "$obj" ]; then
            if [ "$(jq -r .object.type "$tmp/ref")" = tag ]; then
                ghc -o "$tmp/tag" "$gh/git/tags/$obj"; obj=$(jq -r .object.sha "$tmp/tag")
            fi
            break
        fi
        i=$((i + 1)); [ $i -lt 90 ] || { echo "tag $CI_COMMIT_TAG did not reach GitHub within 15 minutes" >&2; exit 1; }
        sleep 10
    done
    [ "$obj" = "$CI_COMMIT_SHA" ] || { echo "GitHub tag $CI_COMMIT_TAG is $obj, not $CI_COMMIT_SHA" >&2; exit 1; }
    code=$(ghc -o "$tmp/rel" -w '%{http_code}' "$gh/releases/tags/$CI_COMMIT_TAG")
    if [ "$code" = 404 ]; then
        notes "$v" | jq -Rs --arg tag "$CI_COMMIT_TAG" --arg name "$CI_COMMIT_TAG (os-ha-helpers $pver)" --arg pv "$pver" \
            '{tag_name: $tag, name: $name, draft: false, prerelease: false, make_latest: "true",
              body: ("Package os-ha-helpers " + $pv + ", built and signed by GitLab CI. Verify with keys/release.pub from the repository (fingerprint pinned in tools/install.sh), never with a key downloaded next to the package.\n" + .)}' > "$tmp/body"
        code=$(ghc -o "$tmp/rel" -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data @"$tmp/body" "$gh/releases")
        [ "$code" = 201 ] || { cat "$tmp/rel" >&2; echo "GitHub release creation failed ($code)" >&2; exit 1; }
        echo "GitHub release $CI_COMMIT_TAG created"
    elif [ "$code" != 200 ]; then
        cat "$tmp/rel" >&2; echo "GitHub release lookup failed ($code)" >&2; exit 1
    fi
    id=$(jq -r .id "$tmp/rel")
    for f in "$base" SHA256SUMS SHA256SUMS.sig; do
        have=$(jq -r --arg n "$f" '.assets[] | select(.name == $n) | .digest // "present"' "$tmp/rel")
        if [ -n "$have" ]; then
            # no digest in the API answer: the download check below compares the content
            [ "$have" = present ] || [ "$have" = "sha256:$(sha "$dist/$f")" ] || { echo "GitHub asset $f exists with another content ($have)" >&2; exit 1; }
            echo "asset $f already there"; continue
        fi
        code=$(ghc -o "$tmp/up" -w '%{http_code}' -X POST -H 'Content-Type: application/octet-stream' \
            --data-binary @"$dist/$f" "https://uploads.github.com/repos/$repo/releases/$id/assets?name=$f")
        [ "$code" = 201 ] || { cat "$tmp/up" >&2; echo "upload of $f failed ($code)" >&2; exit 1; }
        echo "uploaded $f"
    done
    # check what anyone downloads, without a token
    ghc -o "$tmp/rel" "$gh/releases/$id"
    for f in "$base" SHA256SUMS SHA256SUMS.sig; do
        url=$(jq -r --arg n "$f" '.assets[] | select(.name == $n) | .browser_download_url' "$tmp/rel")
        curl -sSfL -o "$tmp/dl" "$url"
        [ "$(sha "$tmp/dl")" = "$(sha "$dist/$f")" ] || { echo "downloaded $f differs from dist/$f" >&2; exit 1; }
    done
    echo "GitHub release $CI_COMMIT_TAG: 3 assets, downloads match dist/"
    ;;
*)
    echo "usage: $0 sign|publish|github" >&2; exit 2 ;;
esac
