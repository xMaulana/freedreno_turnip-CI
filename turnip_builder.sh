#!/bin/bash -e
set -o pipefail

# MODO DE USO: ./turnip_builder.sh [STD|YUCK] [VERSAO_NUMERO]
# Exemplo: ./turnip_builder.sh STD 11 -> Gera V11
# Exemplo: ./turnip_builder.sh YUCK 11 -> Gera V11+Yuck

BUILD_MODE=$1
VERSION_NUM=$2

if [ -z "$BUILD_MODE" ]; then BUILD_MODE="STD"; fi
if [ -z "$VERSION_NUM" ]; then VERSION_NUM="11"; fi

# CONFIGURAÇÃO DE BRANCHES
if [ "$BUILD_MODE" == "YUCK" ]; then
    HACKS_BRANCH="gen8-yuck"
    VERSION_SUFFIX="+Yuck"
    DIR_SUFFIX="_YUCK"
else
    HACKS_BRANCH="gen8-hacks"
    VERSION_SUFFIX=""
    DIR_SUFFIX="_STD"
fi

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="meson ninja patchelf unzip curl pip flex bison zip git perl"
workdir="$(pwd)/turnip_workdir${DIR_SUFFIX}"

# --- REPOSITÓRIOS ---
ndkver="android-ndk-r28"
target_sdk="36"

base_repo="https://gitlab.freedesktop.org/robclark/mesa.git"
base_branch="tu/gen8"

hacks_repo="https://github.com/whitebelyash/mesa-tu8.git"
# A branch de hacks é dinâmica (gen8-hacks ou gen8-yuck)

# Commit que quebra o DXVK
bad_commit="2f0ea1c6"

check_deps(){
	echo "Checking dependencies..."
	for dep in $deps; do
		if ! command -v $dep >/dev/null 2>&1; then echo -e "$red Missing: $dep$nocolor" && exit 1; fi
	done
	pip install mako &> /dev/null || true
}

prepare_ndk(){
	mkdir -p "$workdir" && cd "$workdir"
	if [ ! -d "$ndkver" ]; then
		curl -L "https://dl.google.com/android/repository/${ndkver}-linux.zip" -o ndk.zip &> /dev/null
		unzip -q ndk.zip &> /dev/null
	fi
    export ANDROID_NDK_HOME="$workdir/$ndkver"
}

prepare_source(){
	echo "Preparing Mesa source (Mode: $BUILD_MODE | Branch: $HACKS_BRANCH)..."
	cd "$workdir"
	rm -rf mesa
	git clone --branch "$base_branch" "$base_repo" mesa
	cd mesa

    git config user.email "ci@turnip.builder"
    git config user.name "Turnip CI Builder"

    # 1. HACKS (Dinâmico: Hacks ou Yuck)
    echo -e "${green}Merging hacks from branch: $HACKS_BRANCH...${nocolor}"
    git remote add hacks "$hacks_repo"
    git fetch hacks "$HACKS_BRANCH"
    
    # Merge com estratégia "Theirs" (Hacks ganham do Rob Clark em conflito)
    if ! git merge --no-edit -X theirs "hacks/$HACKS_BRANCH" --allow-unrelated-histories; then
        echo "Merge Conflict detected. Forcing Hacks ($HACKS_BRANCH)..."
        git checkout --theirs .
        git add .
        git commit -m "Auto-resolved conflicts by accepting $HACKS_BRANCH"
    fi

    # 2. CORREÇÃO SINTAXE PYTHON (Vírgula A825)
    # Aplicamos em ambos pois o erro costuma existir nas duas branches do whitebelyash
    perl -i -p0e 's/(\n\s*a8xx_825)/,$1/s' src/freedreno/common/freedreno_devices.py

    # 3. FIX DXVK (GS/Tess)
    if ! git revert --no-edit "$bad_commit"; then
        git revert --abort || true
        # Fallback manual via SED
        find src/freedreno/vulkan -name "*.cc" -print0 | xargs -0 sed -i 's/ && (pdevice->info->chip != 8)//g'
        find src/freedreno/vulkan -name "*.cc" -print0 | xargs -0 sed -i 's/ && (pdevice->info->chip == 8)//g'
    fi

    # 4. SPIRV Dependencies
    mkdir -p subprojects && cd subprojects
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Headers.git spirv-headers
    cd ..
    
    cd "$workdir"
}

compile_mesa(){
	local source_dir="$workdir/mesa"
	local build_dir="$source_dir/build"
	local ndk_bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    
    local comp_ver="35"
    if [ ! -f "$ndk_bin/aarch64-linux-android${comp_ver}-clang" ]; then comp_ver="34"; fi

	local cross_file="$source_dir/android-aarch64-crossfile.txt"
	cat <<EOF > "$cross_file"
[binaries]
ar = '$ndk_bin/llvm-ar'
c = ['ccache', '$ndk_bin/aarch64-linux-android${comp_ver}-clang', '--sysroot=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot']
cpp = ['ccache', '$ndk_bin/aarch64-linux-android${comp_ver}-clang++', '--sysroot=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$ndk_bin/aarch64-linux-android-strip'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

	cd "$source_dir"
	meson setup "$build_dir" --cross-file "$cross_file" \
		-Dbuildtype=release -Dplatforms=android -Dplatform-sdk-version=$target_sdk -Dandroid-stub=true \
		-Dgallium-drivers= -Dvulkan-drivers=freedreno -Dfreedreno-kmds=kgsl -Degl=disabled -Dglx=disabled \
		-Db_lto=true -Dvulkan-beta=true -Ddefault_library=shared -Dzstd=disabled \
        --force-fallback-for=spirv-tools,spirv-headers
	ninja -C "$build_dir"
}

package_driver(){
	local build_dir="$workdir/mesa/build"
	local pkg_temp="$workdir/package_temp"
	rm -rf "$pkg_temp" && mkdir -p "$pkg_temp"
	
	cp "$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so" "$pkg_temp/lib_temp.so"
	cd "$pkg_temp"
	patchelf --set-soname "vulkan.adreno.so" lib_temp.so
	mv lib_temp.so "vulkan.adreno.so"

    # Nome Final: Ex: Mesa Turnip Gen8 V11+Yuck
    FINAL_NAME="Mesa Turnip Gen8 V${VERSION_NUM}${VERSION_SUFFIX}"

	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$FINAL_NAME",
  "description": "Compiled from Source. RobClark Base + Hacks ($HACKS_BRANCH) + DXVK Fix. SDK 36.",
  "author": "Turnip CI",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan 1.4 (Mesa 26.0.0-devel)",
  "minApi": 27,
  "libraryName": "vulkan.adreno.so"
}
EOF
	zip -9 "$workdir/$FINAL_NAME.zip" "vulkan.adreno.so" meta.json
}

check_deps
prepare_ndk
prepare_source
compile_mesa
package_driver
