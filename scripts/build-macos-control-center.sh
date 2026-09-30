#!/bin/sh
set -eu

# Builds the native SwiftUI Control Center into OUTPUT.app.
#
# The bundle keeps every contract the Electron window it replaces had with the
# tray and bin/model-router-tray: the io.github.codex-router.control-center
# identifier, the `Codex Router` executable, `--query-lifecycle`,
# `--quit-for-update`, and `--tray-only`. Router operations run through the
# bundled copy of apps/control-center/electron (native-bridge.mjs), so the
# window and the operations it calls are always one version.
#
#   build-macos-control-center.sh OUTPUT.app SHORT_VERSION BUILD_VERSION \
#     CONTROL_VERSION CONTROL_PROTOCOL
repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
package_dir="$repo_dir/apps/macos/ControlCenter"
electron_dir="$repo_dir/apps/control-center/electron"
assets_dir="$repo_dir/apps/control-center/src/assets"
output_dir=${1:?usage: build-macos-control-center.sh OUTPUT.app SHORT_VERSION BUILD_VERSION CONTROL_VERSION CONTROL_PROTOCOL}
short_version=${2:?short version is required}
bundle_version=${3:?bundle version is required}
control_version=${4:?control version is required}
control_protocol=${5:?control protocol is required}
configuration=${MODEL_ROUTER_TRAY_CONFIGURATION:-release}

case "$output_dir" in
  *.app) ;;
  *) printf 'The Control Center output must be an .app bundle: %s\n' "$output_dir" >&2; exit 1 ;;
esac

# The committed catalogs are generated from the renderer's locale modules.
# A stale copy would ship copy the Electron window no longer has.
node "$package_dir/scripts/generate-strings.mjs" --check 1>&2

if [ "${MODEL_ROUTER_TRAY_UNIVERSAL:-0}" = "1" ]; then
  swift build -c "$configuration" --package-path "$package_dir" \
    --arch arm64 --arch x86_64 1>&2
  binary_dir=$(swift build -c "$configuration" --package-path "$package_dir" \
    --arch arm64 --arch x86_64 --show-bin-path)
else
  swift build -c "$configuration" --package-path "$package_dir" 1>&2
  binary_dir=$(swift build -c "$configuration" --package-path "$package_dir" --show-bin-path)
fi
if [ ! -x "$binary_dir/ControlCenter" ]; then
  printf 'The native Control Center executable was not produced.\n' >&2
  exit 1
fi

rm -rf "$output_dir"
contents="$output_dir/Contents"
resources="$contents/Resources"
mkdir -p "$contents/MacOS" "$resources"
cp "$binary_dir/ControlCenter" "$contents/MacOS/Codex Router"
cp "$package_dir/Resources/Info.plist" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $short_version" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $bundle_version" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ModelRouterControlVersion string $control_version" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ModelRouterControlProtocol integer $control_protocol" "$contents/Info.plist"
if [ -f "$repo_dir/apps/macos/ModelRouterTray/Resources/AppIcon.icns" ]; then
  cp "$repo_dir/apps/macos/ModelRouterTray/Resources/AppIcon.icns" "$resources/AppIcon.icns"
fi

# SwiftPM's resource bundle for ControlCenterCore, and the catalogs at the
# path StringCatalogs looks for first in a packaged app.
if [ -d "$binary_dir/ControlCenter_ControlCenterCore.bundle" ]; then
  cp -R "$binary_dir/ControlCenter_ControlCenterCore.bundle" "$resources/"
fi
mkdir -p "$resources/Strings"
cp "$package_dir/Sources/ControlCenterCore/Resources/Strings/"*.json "$resources/Strings/"

# The renderer's provider and client marks, unchanged.
mkdir -p "$resources/Brand/providers" "$resources/Brand/clients"
for file in "$assets_dir/providers/"*.png "$assets_dir/providers/"*.svg; do
  if [ -f "$file" ]; then cp "$file" "$resources/Brand/providers/"; fi
done
for file in "$assets_dir/clients/"*.svg; do
  if [ -f "$file" ]; then cp "$file" "$resources/Brand/clients/"; fi
done

# The operation layer, laid out as it is in the checkout so ipc.mjs's
# relative imports of ../../../src resolve. Only the modules Electron Builder
# ships beside app.asar are copied; everything else is read from the
# installed checkout at run time, or from router-src below.
bridge="$resources/bridge"
mkdir -p "$bridge/apps/control-center/electron" "$bridge/src"
cp "$repo_dir/apps/control-center/package.json" "$bridge/apps/control-center/package.json"
for file in "$electron_dir/"*.mjs; do
  cp "$file" "$bridge/apps/control-center/electron/"
done
for module in spawnable-command chatgpt-login-lease file-security path-security process-identity; do
  cp "$repo_dir/src/$module.mjs" "$bridge/src/$module.mjs"
done
# Read-only helpers the desktop UI loads must match the UI version even when
# the shared service is still owned by an older checkout (ipc.mjs prefers
# this copy when the bridge is given --resources-path).
mkdir -p "$resources/router-src"
cp -R "$repo_dir/src/." "$resources/router-src/"

if [ ! -f "$bridge/apps/control-center/electron/native-bridge.mjs" ]; then
  printf 'The Control Center bridge was not bundled.\n' >&2
  exit 1
fi
printf '%s\n' "$output_dir"
