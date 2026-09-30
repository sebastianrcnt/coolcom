#!/bin/sh
# Pinned source-only macOS Venus stack. All downloads, builds and licenses stay
# in gitignored vendor/venus. Homebrew supplies build tools, never runtime libs.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# Separate immutable generator inputs from the macOS renderer stack.
# Default/--generator [--test] are usable without Xcode or host libraries.
case "${1:---generator}" in
    generator|--generator)
        if [ "$#" -gt 0 ]; then shift; fi
        exec python3 "$ROOT/tools/venus/vendor.py" "$@" ;;
    --test|--help|-h) exec python3 "$ROOT/tools/venus/vendor.py" "$@" ;;
    host|--host) shift ;;
    *) echo "Unknown Venus section: $1 (use --generator [--test] or --host)" >&2; exit 2 ;;
esac
[ "$#" -eq 0 ] || { echo 'Host section takes no options' >&2; exit 2; }
V=$ROOT/vendor/venus
P=$V/install
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || { echo 'Venus host build requires Apple Silicon macOS' >&2; exit 1; }
for tool in meson ninja pkg-config cmake; do
    command -v "$tool" >/dev/null || { echo "Install build tool: brew install $tool" >&2; exit 1; }
done
mkdir -p "$P/lib" "$P/include" "$V/logs"
python3 - "$ROOT/tools/venus-deps.json" "$V" <<'PY'
import concurrent.futures, hashlib, json, pathlib, subprocess, sys, urllib.request
entries=json.load(open(sys.argv[1])); root=pathlib.Path(sys.argv[2]); (root/'downloads').mkdir(exist_ok=True)
def fetch(e):
    archive=root/'downloads'/(e['name']+'.tar.gz')
    if not archive.exists():
        temp=archive.with_suffix('.part')
        with urllib.request.urlopen(e['url'], timeout=120) as r: temp.write_bytes(r.read())
        temp.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest()!=e['sha256']:
        raise RuntimeError('SHA256 mismatch: '+str(archive))
    return archive
def extract(e, archive):
    dest=root/e['dest']
    stamp=dest/'.coolvm-source-sha256'
    if not stamp.exists():
        dest.mkdir(parents=True,exist_ok=True)
        subprocess.run(['tar','-xzf',str(archive),'-C',str(dest),'--strip-components','1'],check=True)
        stamp.write_text(e['sha256'])
    elif stamp.read_text()!=e['sha256']:
        raise RuntimeError('Source pin changed; remove '+str(dest)+' and rebuild')
    license_dir=root/'licenses'/e['name']; license_dir.mkdir(parents=True,exist_ok=True)
    licenses=[p for p in dest.iterdir() if p.is_file() and p.name.upper().startswith(('LICENSE','COPYING','NOTICE','COPYRIGHT'))]
    if e['name']=='venus-protocol':
        licenses=[dest/'vn_protocol.py', dest/'templates/banner.in']
    if not licenses: raise RuntimeError('Missing license: '+str(dest))
    for p in licenses: (license_dir/p.name).write_bytes(p.read_bytes())
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool: archives=list(pool.map(fetch, entries))
# Parents before nested sources (SPIRV-Headers lives in SPIRV-Tools).
for e, archive in sorted(zip(entries,archives),key=lambda pair: pair[0]['dest'].count('/')):
    extract(e,archive)
PY
run() {
    log=$V/logs/$1.log; shift
    echo "Building $log" >&2
    "$@" >"$log" 2>&1 || { tail -60 "$log" >&2; exit 1; }
}
export PKG_CONFIG_PATH="$P/lib/pkgconfig"
export CFLAGS="-I$P/include"
export LDFLAGS="-L$P/lib -Wl,-rpath,$P/lib"
if [ ! -f "$P/lib/libepoxy.dylib" ]; then
    run epoxy-setup meson setup --reconfigure "$V/libepoxy/build" "$V/libepoxy" --prefix="$P" --libdir=lib -Dtests=false -Dx11=false -Dglx=no -Degl=no
    run epoxy-build meson compile -C "$V/libepoxy/build"
    run epoxy-install meson install -C "$V/libepoxy/build"
fi
M=$V/MoltenVK
if [ ! -f "$P/lib/libMoltenVK.dylib" ]; then
    unzip -o -q "$M/Templates/spirv-tools/build.zip" -d "$M/External/SPIRV-Tools"
    run moltenvk-deps xcodebuild -project "$M/ExternalDependencies.xcodeproj" -scheme ExternalDependencies-macOS -configuration Release -destination generic/platform=macOS -derivedDataPath "$M/External/build/Intermediates/macOS" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES KEEP_CACHE=Y build
    run moltenvk-build xcodebuild -project "$M/MoltenVKPackaging.xcodeproj" -scheme 'MoltenVK Package (macOS only)' -configuration Release -destination generic/platform=macOS -derivedDataPath "$M/build" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES KEEP_CACHE=Y build
    cp "$M/Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" "$P/lib/"
    install_name_tool -id "$P/lib/libMoltenVK.dylib" "$P/lib/libMoltenVK.dylib"
    codesign --force --sign - "$P/lib/libMoltenVK.dylib"
fi
cp -R "$M/External/Vulkan-Headers/include/" "$P/include/"
# krunkit's fork links MoltenVK directly. Replace its Homebrew-only header path;
# preserve the protocol snapshot bundled in the pinned renderer archive.
python3 - "$V/virglrenderer/meson.build" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); s=p.read_text(); s=s.replace("   add_project_arguments('-I/opt/homebrew/opt/molten-vk/libexec/include', language : 'c')", "   # Vulkan headers are supplied by the vendored prefix via CFLAGS.")
p.write_text(s)
PY
# Reproducible host-only Metal image bridge on the pinned renderer source.
patch_file=$ROOT/tools/venus/virgl-metal.patch
if ! patch --batch --fuzz=0 --dry-run -R -p1 -d "$V/virglrenderer" < "$patch_file" >/dev/null 2>&1; then
    patch --batch --fuzz=0 -p1 -d "$V/virglrenderer" < "$patch_file"
fi
run virgl-setup meson setup --reconfigure "$V/virglrenderer/build" "$V/virglrenderer" --prefix="$P" --libdir=lib -Dvenus=true -Drender-server=false -Ddrm=disabled -Dplatforms=[]
run virgl-build meson compile -C "$V/virglrenderer/build"
run virgl-install meson install -C "$V/virglrenderer/build"
echo "$P"
