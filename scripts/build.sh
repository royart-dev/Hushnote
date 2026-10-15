#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --jobs 4
bin="$(swift build -c release --show-bin-path)"
mkdir -p .cache dist
stage="$(mktemp -d "$PWD/.cache/app.XXXXXX")"
app="$stage/Hushnote.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$bin/Hushnote" "$app/Contents/MacOS/"
cp "$bin/HushnoteWorker" "$app/Contents/Helpers/"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
mkdir -p "$app/Contents/Resources/ThirdPartyNotices"
cp .build/checkouts/FluidAudio/LICENSE "$app/Contents/Resources/ThirdPartyNotices/FluidAudio-LICENSE"
cp -R .build/checkouts/FluidAudio/ThirdPartyLicenses "$app/Contents/Resources/ThirdPartyNotices/FluidAudio-dependencies"
cp README.md "$app/Contents/Resources/README.md"
for bundle in "$bin"/*.bundle; do
  if [ -d "$bundle" ]; then
    cp -R "$bundle" "$app/Contents/Resources/"
    ln -s "../Resources/$(basename "$bundle")" "$app/Contents/Helpers/$(basename "$bundle")"
  fi
done
# SwiftPM embeds the absolute build directory as a fallback path for resource bundles. The packaged app
# finds its bundles next to the worker, so overwrite that prefix with an inert string of the same length.
# This keeps the builder's user name and folders out of anything that gets distributed.
python3 - "$PWD" "$app/Contents/Helpers/HushnoteWorker" "$app/Contents/MacOS/Hushnote" <<'PY'
import sys
root, *files = sys.argv[1:]
needle = root.encode()
filler = (b"/nonexistent" + b"/" * len(needle))[:len(needle)]
for path in files:
    data = open(path, "rb").read()
    if needle in data:
        open(path, "wb").write(data.replace(needle, filler))
PY
if [ -d .cache/llama ]; then
  mkdir -p "$app/Contents/Helpers/llama"
  runtime=.cache/llama/llama-b11429
  cp "$runtime/LICENSE" "$app/Contents/Resources/ThirdPartyNotices/llama.cpp-LICENSE"
  cp "$runtime/llama-completion" "$app/Contents/Helpers/llama/"
  cp -R "$runtime"/libggml*.dylib "$runtime"/libllama.0*.dylib "$runtime"/libllama-common*.dylib "$runtime/libllama-completion-impl.dylib" "$app/Contents/Helpers/llama/"
fi
for private in "$PWD" "$HOME"; do
  if grep -rqaF -- "$private" "$app"; then
    echo "error: $private is still embedded in the bundle; refusing to package it." >&2
    exit 1
  fi
done
find "$app/Contents" -type f \( -name '*.dylib' -o -name 'llama-completion' -o -name 'llama-cli' -o -name 'HushnoteWorker' \) -exec codesign --force --sign - '{}' \;
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
if [ -d "$PWD/dist/Hushnote.app" ]; then
  mkdir -p .cache/previous-builds
  mv "$PWD/dist/Hushnote.app" ".cache/previous-builds/Hushnote-$(date +%Y%m%d-%H%M%S).app"
fi
mv "$app" "$PWD/dist/Hushnote.app"
printf '\nBuilt %s/dist/Hushnote.app\n' "$PWD"
