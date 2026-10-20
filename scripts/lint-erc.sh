#!/usr/bin/env bash
# Lints ERCS/*.md the way the ethereum/ERCs repository's CI does (its .github/workflows/ci.yml, "eipw-validator"):
# every EIP and ERC is made resolvable as ERCS/eip-N.md, then eipw runs with that repository's config/eipw.toml
# (copied here as eipw.toml). Each draft is linted as ERCS/erc-<its eip number>.md. The number in a draft's preamble is
# a placeholder until the ERC editors assign one.
#
# Usage: scripts/lint-erc.sh            (clones ethereum/ERCs and ethereum/EIPs, sparse and shallow)
#        ERCS_REPO=/path EIPS_REPO=/path scripts/lint-erc.sh   (reuses existing checkouts; nothing in them is changed)
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ -n "${ERCS_REPO:-}" ]; then
  mkdir -p "$work/ERCs" && cp -r "$ERCS_REPO/ERCS" "$ERCS_REPO/config" "$work/ERCs/"
else
  git clone -q --depth 1 --filter=blob:none --sparse https://github.com/ethereum/ERCs.git "$work/ERCs"
  git -C "$work/ERCs" sparse-checkout set ERCS config
fi
if [ -n "${EIPS_REPO:-}" ]; then
  eips="$EIPS_REPO/EIPS"
else
  git clone -q --depth 1 --filter=blob:none --sparse https://github.com/ethereum/EIPs.git "$work/EIPs"
  git -C "$work/EIPs" sparse-checkout set EIPS
  eips="$work/EIPs/EIPS"
fi

cp -p "$eips"/eip-*.md "$work/ERCs/ERCS/"
for f in "$work"/ERCs/ERCS/erc-*.md; do cp -p "$f" "$work/ERCs/ERCS/eip-${f##*/erc-}"; done

files=()
for src in "$here"/ERCS/*.md; do
  n=$(sed -n 's/^eip: *//p' "$src" | head -1)
  [ -n "$n" ] || { echo "no eip number in $src" >&2; exit 1; }
  cp "$src" "$work/ERCs/ERCS/erc-$n.md"
  cp "$src" "$work/ERCs/ERCS/eip-$n.md"
  files+=("ERCS/erc-$n.md")
done

cd "$work/ERCs"
eipw --config "$here/eipw.toml" "${files[@]}"
