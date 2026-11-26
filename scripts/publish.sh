#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ref=${1:-}
if [[ ! "$ref" =~ ^release-(staging|check)/(v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))$ ]]; then
  echo 'Expected a versioned release staging or check branch.' >&2
  exit 1
fi
mode=${BASH_REMATCH[1]}
tag=${BASH_REMATCH[2]}
version=${tag#v}
windows="Toast-$version-windows-x64-setup.exe"
mac=Toast.app.tar.gz
files=("$mac" "$mac.sig" Toast-macos-arm64.zip "$windows" "$windows.sig" latest.json)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

verify() {
  local platform=$1 file=$2
  local url="https://github.com/Paori852/Toast/releases/download/$tag/$file"
  jq -e --arg platform "$platform" --arg version "$version" --arg url "$url" \
    --rawfile signature "release/$file.sig" \
    '.version == $version and .platforms[$platform] == {url: $url, signature: ($signature | rtrimstr("\n") | rtrimstr("\r"))}' \
    release/latest.json >/dev/null
  base64 --decode "release/$file.sig" > "$scratch/update.minisig"
  minisign -Vm "release/$file" -p scripts/updater.pub -x "$scratch/update.minisig"
  awk -F '\t' -v expected="version:$version" \
    '/^trusted comment: / { for (i=1;i<=NF;i++) if ($i==expected) found=1 } END { exit !found }' "$scratch/update.minisig"
}

for file in "${files[@]}" notes.md; do
  [[ -s "release/$file" ]] || { echo "Missing release/$file" >&2; exit 1; }
done
verify darwin-aarch64 "$mac"
verify windows-x86_64 "$windows"
unzip -tq release/Toast-macos-arm64.zip
if [[ "$mode" == check ]]; then
  echo "Verified the distribution handoff for $tag."
  exit 0
fi

[[ "$GH_REPO" == Paori852/Toast ]]
latest=$(gh api "repos/$GH_REPO/releases/latest" --jq .tag_name)
if [[ "$tag" != "$latest" && "$(printf '%s\n%s\n' "$tag" "$latest" | sort -V | tail -1)" != "$tag" ]]; then
  echo "Release $tag is earlier than $latest." >&2
  exit 1
fi
if draft=$(gh release view "$tag" --json isDraft --jq .isDraft 2>/dev/null); then
  [[ "$draft" == true ]] || { echo "Release $tag is already published." >&2; exit 1; }
else
  gh release create "$tag" --draft --target main --title "Toast $version" --notes-file release/notes.md
fi
paths=()
for file in "${files[@]}"; do paths+=("release/$file"); done
gh release upload "$tag" "${paths[@]}" --clobber
gh release download "$tag" --dir "$scratch/download"
for file in "${files[@]}"; do cmp "release/$file" "$scratch/download/$file"; done
gh release edit "$tag" --draft=false --latest
gh api --method DELETE "repos/$GH_REPO/git/refs/heads/$ref"
