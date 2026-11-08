#!/usr/bin/env bash
# Fetches the Duet film (built by KNIGHTABDO/duet-film's encode workflow) into the app bundle's resources.
# Release builds require it; branch builds go on without it (Settings then hides "Play the Duet Film").
set -euo pipefail
dest=KnightMusic/Resources/Intro/duet-intro.mp4
url="https://github.com/${GITHUB_REPOSITORY:-KNIGHTABDO/knight-music}/releases/download/intro-assets/duet-intro.mp4"
mkdir -p "$(dirname "$dest")"
if curl -fsSL --retry 3 -o "$dest" "$url"; then
  ls -l "$dest"
elif [[ "${GITHUB_REF:-}" == refs/tags/* ]]; then
  echo "::error::Duet film missing at $url"; exit 1
else
  rm -f "$dest"; echo "::warning::Duet film not found; building without the intro"
fi
