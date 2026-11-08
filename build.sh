#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
out="$(dirname "$root")/Собака на столе.app"
stage="$(mktemp -d "${TMPDIR:-/tmp}/desktopdog-build.XXXXXX")"
cleanup() {
  if [[ ! -e "$out" && -e "$stage/previous.app" ]]; then
    mv "$stage/previous.app" "$out" || return
  fi
  rm -rf "$stage"
}
trap cleanup EXIT
bundle="$stage/Собака на столе.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$root/Info.plist" "$bundle/Contents/Info.plist"
photos="$bundle/Contents/Resources/Photo"
mkdir -p "$photos/Motion"
cp "$root/Assets/Photo/"{Portraits,Rest}.png "$photos/"
cp "$root/Assets/Photo/Motion/"{Side,Near,Far,Axial,Action,Wag,Bed}.png "$photos/Motion/"
cp "$root/Assets/Photo/Motion/Atlas.json" "$photos/Motion/"
if [[ -f "$root/Assets/DesktopDog.icns" ]]; then
  cp "$root/Assets/DesktopDog.icns" "$bundle/Contents/Resources/"
fi
arch="$(uname -m)"
xcrun swiftc -swift-version 5 -O -target "$arch-apple-macos13.0" \
  "$root"/Sources/{BedLife,Behavior,DesktopFolders,DogView,PhotoAppearance,PhotoSurface,main}.swift \
  -o "$bundle/Contents/MacOS/DesktopDog"
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
if [[ -e "$out" && ! -f "$out/Contents/MacOS/DesktopDog" ]]; then
  echo "This path contains a different app: $out" >&2
  exit 1
fi
if [[ -e "$out" ]]; then
  mv "$out" "$stage/previous.app"
fi
if ! mv "$bundle" "$out" || ! codesign --verify --strict "$out"; then
  if [[ -e "$out" ]]; then mv "$out" "$stage/failed.app"; fi
  if [[ -e "$stage/previous.app" ]]; then mv "$stage/previous.app" "$out"; fi
  exit 1
fi
printf '%s\n' "$out"
