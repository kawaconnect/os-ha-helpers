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
# Write SHA256SUMS for the package in packages/os-ha-helpers/ and sign it with
# the release key (RSA, the private half of keys/release.pub), in the format
# the os-carp-vip-dhcp releases use: SHA256SUMS.sig is the base64 signature.
#
#   tools/sign.sh <private key file> [package directory]
#
# The directory defaults to packages/os-ha-helpers; CI signs dist/.
# Keep the private key out of the repository (password manager, protected CI
# variable). Verify: tools/install.sh does it before every install.
set -eu
[ $# -ge 1 ] && [ $# -le 2 ] && [ -r "$1" ] || { echo "usage: $0 <private key file> [package directory]"; exit 2; }
here=$(cd "$(dirname "$0")/.." && pwd)
dir=${2:-$here/packages/os-ha-helpers}
cd "$dir"
set -- "$1" os-ha-helpers-*.pkg
[ -f "$2" ] || { echo "no package in $dir" >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then sha256sum "$2"; else shasum -a 256 "$2"; fi | sed 's|  |  ./|' > SHA256SUMS
tmp=$(mktemp)
openssl dgst -sha256 -sign "$1" -out "$tmp" SHA256SUMS
openssl base64 -in "$tmp" -out SHA256SUMS.sig
rm -f "$tmp"
openssl base64 -d -in SHA256SUMS.sig | openssl dgst -sha256 -verify "$here/keys/release.pub" -signature /dev/stdin SHA256SUMS
cat SHA256SUMS
