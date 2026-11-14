#!/usr/bin/env bash
# Full native rebuild for CI. Rebuilds every guest component that has source
# code in native/ (and the optional tools/ testers), records per-script logs,
# and writes a SHA-256 diff of the engine assets so the APK can be compared
# with the binaries shipped in the repository.
#
# Individual failures are recorded, not fatal: the APK is still assembled from
# whatever was rebuilt plus the untouched prebuilt files, and the report makes
# the exact coverage visible.

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT" || exit 1

REPORT="$ROOT/native-build-report"
ASSETS="app/src/main/assets/engines"
JNI="app/src/main/jniLibs/arm64-v8a"
rm -rf "$REPORT"
mkdir -p "$REPORT/logs"

OK=0
FAIL=0
SKIP=0

snapshot() {
  find "$ASSETS" "$JNI" -type f -print0 | sort -z | xargs -0 sha256sum > "$1"
}

run() {
  local name=$1 cwd=$2
  shift 2
  local log="$REPORT/logs/$name.log"
  printf '%-30s' "$name"
  if (cd "$cwd" && "$@") > "$log" 2>&1; then
    echo OK
    OK=$((OK + 1))
  else
    echo FAIL
    FAIL=$((FAIL + 1))
    {
      echo "=== $name ==="
      tail -30 "$log"
    } >> "$REPORT/failures.txt"
  fi
}

skip() {
  printf '%-30sSKIP (%s)\n' "$1" "$2"
  SKIP=$((SKIP + 1))
}

snapshot "$REPORT/before.sha256"

echo "== generic guest components =="
run build_all_py      native             python3 build_all.py
run apwrap            native/apwrap      sh build.sh
run audiohal          native/audiohal    sh build.sh
run camerahal         native/camerahal   sh build.sh
run glbuf             native/glbuf       sh build.sh
run gles1fix          native/gles1fix    sh build.sh
run glroute           native/glroute     sh build.sh
run glsplit           native/glsplit     sh build.sh
run glbridge32        native/glbridge    sh build32.sh
run grallocwrap23     native/grallocwrap sh build23.sh
run guestshim         native/guestshim   sh build.sh
run gueststubs        native/gueststubs  sh build.sh
run hostjni           native/hostjni     sh build.sh
run lightshal         native/lightshal   sh build.sh
run sensorshal        native/sensorshal  sh build.sh

TAGS=$(find native/guest64 -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' -printf '%f\n' | sort -n)

echo "== per-kernel engine cores (guest64) =="
for tag in $TAGS; do
  run "guest64-$tag" native/guest64 sh build.sh "$tag"
done

echo "== per-kernel HALs / bridges (only where the shipped file exists) =="
GL_TAGS=()
for d in "$ASSETS"/n64-[0-9]*; do
  [ -d "$d" ] || continue
  tag=${d##*n64-}
  case "$tag" in ''|*[!0-9]*) continue ;; esac
  [ -f "$d/system#lib64#egl#libGLES_aemu.so" ] && GL_TAGS+=("$tag")

  [ -f "$d/vendor#lib64#hw#power.default.so" ]            && run "powerhal-$tag"    native/powerhal    sh build.sh "$tag"
  [ -f "$d/vendor#lib64#hw#hwcomposer.default.so" ]       && run "hwchal-$tag"      native/hwchal      sh build.sh "$tag"
  [ -f "$d/system#lib64#hw#camera.default.so" ]           && run "camera3-$tag"     native/camerahal   sh build3.sh "$tag"
  [ -f "$d/vendor#lib64#libgralloc_aosp.so" ]             && run "grallocwrap-$tag" native/grallocwrap sh build.sh "$tag"
  [ -f "$d/vendor#lib64#hw#mapper.aemu.so" ]              && run "gralloc5-$tag"    native/gralloc5    sh build.sh "$tag"
  [ -f "$d/system#lib64#hw#lights.default.so" ]           && run "lights64-$tag"    native/lightshal   env TAG="$tag" sh build.sh
  [ -f "$d/vendor#lib64#hw#audio.primary.default.so" ]    && run "audio64-$tag"     native/audiohal    env TAG="$tag" sh build.sh
done

if [ ${#GL_TAGS[@]} -gt 0 ]; then
  run glbridge native/glbridge sh build.sh "${GL_TAGS[@]}"
else
  skip glbridge "no shipped guest driver to rebuild"
fi

echo "== standalone guest test APKs (not part of the app APK) =="
if [ "${INCLUDE_TEST_TOOLS:-true}" = "true" ]; then
  for t in guesttest guesttest-a guesttest-b; do
    if [ -f "tools/$t/build.sh" ]; then
      run "tool-$t" "tools/$t" sh build.sh
    fi
  done
else
  skip guesttest_tools "disabled by input"
fi

snapshot "$REPORT/after.sha256"

python3 - "$REPORT" <<'PY'
import os, sys
rep = sys.argv[1]
def load(name):
    out = {}
    with open(os.path.join(rep, name), encoding='utf-8', errors='replace') as f:
        for line in f:
            parts = line.rstrip('\n').split('  ', 1)
            if len(parts) == 2:
                out[parts[1]] = parts[0]
    return out
before, after = load('before.sha256'), load('after.sha256')
changed = sorted(k for k in before.keys() & after.keys() if before[k] != after[k])
added = sorted(after.keys() - before.keys())
removed = sorted(before.keys() - after.keys())
with open(os.path.join(rep, 'changed.txt'), 'w') as f:
    for k in changed: f.write('CHANGED ' + k + '\n')
    for k in added:   f.write('ADDED   ' + k + '\n')
    for k in removed: f.write('REMOVED ' + k + '\n')
with open(os.path.join(rep, 'counts.env'), 'w') as f:
    f.write('CHANGED=%d\nADDED=%d\nREMOVED=%d\n' % (len(changed), len(added), len(removed)))
print('changed=%d added=%d removed=%d' % (len(changed), len(added), len(removed)))
PY

. "$REPORT/counts.env"

{
  echo "# Full source build report"
  echo ""
  echo "| item | count |"
  echo "| --- | --- |"
  echo "| native scripts succeeded | $OK |"
  echo "| native scripts failed | $FAIL |"
  echo "| native scripts skipped | $SKIP |"
  echo "| engine binaries changed | $CHANGED |"
  echo "| engine binaries added | $ADDED |"
  echo "| engine binaries removed | $REMOVED |"
  echo ""
  echo "Per-script logs: \`native-build-report/logs/\`. Full SHA-256 diff: \`native-build-report/changed.txt\`."
  echo ""
  echo "Note: \`libqemu_arm.so\` (QEMU user engine), SwiftShader and vendor libraries have no source in this"
  echo "repository and are always taken from the prebuilt assets shipped with the repo."
  if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Failed scripts (see \`native-build-report/failures.txt\`):"
    echo '```'
    grep '^=== ' "$REPORT/failures.txt" | sed 's/^=== /- /'
    echo '```'
  fi
} > "$REPORT/summary.md"

cat "$REPORT/summary.md" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
cat "$REPORT/summary.md"

echo "::notice::Full native rebuild: $OK succeeded / $FAIL failed / $SKIP skipped; engine binaries: $CHANGED changed, $ADDED added, $REMOVED removed"

if [ "$FAIL" -gt 0 ]; then
  echo "::warning::$FAIL native build script(s) failed; inspect native-build-report/failures.txt"
fi

exit 0
