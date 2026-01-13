#!/bin/bash -e
set -o pipefail

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# Dependências (glslangValidator + pip para meson novo)
deps="ninja patchelf unzip curl pip flex bison zip git perl glslangValidator"
workdir="$(pwd)/turnip_workdir"

# --- CONFIGURAÇÃO ---
ndkver="android-ndk-r28"
target_sdk="36"

base_repo="https://gitlab.freedesktop.org/robclark/mesa.git"
base_branch="tu/gen8"

hacks_repo="https://github.com/whitebelyash/mesa-tu8.git"
hacks_branch="gen8-hacks"

bad_commit="2f0ea1c6"

check_deps(){
	echo "Checking dependencies..."
	for dep in $deps; do
		if ! command -v $dep >/dev/null 2>&1; then echo -e "$red Missing: $dep$nocolor" && exit 1; fi
	done
	# Força instalação do Meson via PIP (Versão > 1.4.0 requerida)
	pip install meson mako &> /dev/null || true
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
	echo "Preparing Mesa source..."
	cd "$workdir"
	rm -rf mesa
	git clone --branch "$base_branch" "$base_repo" mesa
	cd mesa

    git config user.email "ci@turnip.builder"
    git config user.name "Turnip CI Builder"

    # Merge Hacks
    git remote add hacks "$hacks_repo"
    git fetch hacks "$hacks_branch"
    if ! git merge --no-edit "hacks/$hacks_branch" --allow-unrelated-histories; then
        git checkout --theirs .
        git add .
        git commit -m "Auto-resolved conflicts"
    fi

    # Fix Python Syntax (Vírgula faltante no A825)
    perl -i -p0e 's/(\n\s*a8xx_825)/,$1/s' src/freedreno/common/freedreno_devices.py

    # Fix DXVK (GS/Tess)
    if ! git revert --no-edit "$bad_commit"; then
        git revert --abort || true
        find src/freedreno/vulkan -name "*.cc" -print0 | xargs -0 sed -i 's/ && (pdevice->info->chip != 8)//g'
        find src/freedreno/vulkan -name "*.cc" -print0 | xargs -0 sed -i 's/ && (pdevice->info->chip == 8)//g'
    fi

    # Dependencies
    mkdir -p subprojects && cd subprojects
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Headers.git spirv-headers
    cd ..
    
	commit_hash=$(git rev-parse HEAD)
	version_str="RobClark-BleedingEdge"
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
	
	# === CRÍTICO PARA FUNCIONAR ===
	# -Dandroid-libbacktrace=disabled: Impede crash no Yuzu/Sudachi
	# -Dvideo-codecs=: Remove lixo
	meson setup "$build_dir" --cross-file "$cross_file" \
		-Dbuildtype=release \
		-Dplatforms=android \
		-Dplatform-sdk-version=$target_sdk \
		-Dandroid-stub=true \
		-Dgallium-drivers= \
		-Dvulkan-drivers=freedreno \
		-Dfreedreno-kmds=kgsl \
		-Degl=disabled \
		-Dglx=disabled \
		-Db_lto=true \
		-Dvulkan-beta=true \
		-Ddefault_library=shared \
		-Dzstd=disabled \
		-Dandroid-libbacktrace=disabled \
		-Dvideo-codecs= \
        --force-fallback-for=spirv-tools,spirv-headers
        
	ninja -C "$build_dir"
}

package_driver(){
	local build_dir="$workdir/mesa/build"
	local pkg_temp="$workdir/package_temp"
	rm -rf "$pkg_temp" && mkdir -p "$pkg_temp"
	
	cp "$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so" "$pkg_temp/lib_temp.so"
	cd "$pkg_temp"

    # === RENOMEANDO PARA vulkan.ad08XX.so ===
    # 1. Ajusta o SONAME interno para bater com o nome do arquivo
	patchelf --set-soname "vulkan.ad08XX.so" lib_temp.so
    # 2. Renomeia o arquivo
	mv lib_temp.so "vulkan.ad08XX.so"

	local short_hash=${commit_hash:0:7}
	local meta_name="Turnip-A830-Gen8-${short_hash}"
	
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "Turnip Gen8 (Rob Clark upstream + hacks)",
  "author": "Turnip CI",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "$version_str",
  "minApi": 28,
  "libraryName": "vulkan.ad08XX.so"
}
EOF
	zip -9 "$workdir/$meta_name.zip" "vulkan.ad08XX.so" meta.json
	echo -e "${green}Package ready: $workdir/$meta_name.zip${nocolor}"
}

check_deps
prepare_ndk
prepare_source
compile_mesa
package_driver
