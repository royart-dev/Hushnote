#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .cache/llama
archive=.cache/llama-b11429-bin-macos-arm64.tar.gz
if [ ! -f "$archive" ]; then
  curl --fail --location --retry 2 'https://github.com/ggml-org/llama.cpp/releases/download/b11429/llama-b11429-bin-macos-arm64.tar.gz' -o "$archive"
fi
printf '%s  %s\n' '740288ec6887be94280a5dfa25b5e23a78285cab104519e6c7e218904ee82459' "$archive" | shasum -a 256 -c -
tar -xzf "$archive" -C .cache/llama
