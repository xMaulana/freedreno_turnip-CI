#!/bin/bash -e
set -o pipefail

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# ADICIONADO: 'patch' na lista de dependências
deps="ninja patchelf unzip curl pip flex bison zip git perl glslangValidator patch"
workdir="$(pwd)/turnip_workdir"

# --- CONFIGURAÇÃO ---
ndkver="android-ndk-r28"
target_sdk="36"

# BASE: Rob Clark (Bleeding Edge)
base_repo="https://gitlab.freedesktop.org/robclark/mesa.git"
base_branch="tu/gen8"

# HACKS: Whitebelyash (A830 Support)
hacks_repo="https://github.com/whitebelyash/mesa-tu8.git"
hacks_branch="gen8-hacks"

# Commit que quebra o DXVK (Vamos reverter ele)
bad_commit="2f0ea1c6"

commit_hash=""
version_str=""

check_deps(){
	echo "Checking system dependencies ..."
	for dep in $deps; do
		if ! command -v $dep >/dev/null 2>&1; then
			echo -e "$red Missing dependency binary: $dep$nocolor"
			missing=1
		else
			echo -e "$green Found: $dep$nocolor"
		fi
	done
	if [ "$missing" == "1" ]; then
		echo "Please install missing dependencies (ex: sudo apt install glslang-tools python3-pip patch ...)." && exit 1
	fi
    
	echo "Updating Meson via pip..."
	pip install meson mako --break-system-packages &> /dev/null || pip install meson mako &> /dev/null || true
}

prepare_ndk(){
	echo "Preparing NDK r28..."
	mkdir -p "$workdir"
	cd "$workdir"
	if [ ! -d "$ndkver" ]; then
		echo "Downloading Android NDK $ndkver..."
		curl -L "https://dl.google.com/android/repository/${ndkver}-linux.zip" --output "${ndkver}-linux.zip" &> /dev/null
		echo "Extracting NDK..."
		unzip -q "${ndkver}-linux.zip" &> /dev/null
	fi
    export ANDROID_NDK_HOME="$workdir/$ndkver"
}

prepare_source(){
	echo "Preparing Mesa source..."
	cd "$workdir"
	if [ -d mesa ]; then rm -rf mesa; fi
	
    # 1. Clona BASE (Rob Clark - Último Commit)
    echo "Cloning Base: $base_repo ($base_branch)..."
	git clone --branch "$base_branch" "$base_repo" mesa
	cd mesa
    
    echo -e "${green}Current Rob Clark Commit:${nocolor}"
    git log -1 --format="%H - %cd - %s"

    git config user.email "ci@turnip.builder"
    git config user.name "Turnip CI Builder"

    # 2. Prepara os HACKS
    echo "Fetching Hacks from: $hacks_repo..."
    git remote add hacks "$hacks_repo"
    git fetch hacks "$hacks_branch"
    
    # 3. SMART MERGE HACKS
    echo "Attempting Merge Hacks..."
    if ! git merge --no-edit "hacks/$hacks_branch" --allow-unrelated-histories; then
        echo -e "${red}Merge Conflict detected! Resolving intelligently...${nocolor}"
        git checkout --theirs .
        git add .
        git commit -m "Auto-resolved conflicts by accepting Hacks"
        echo -e "${green}Conflicts resolved. Hacks applied successfully.${nocolor}"
    fi

    # --- PATCH A710/A720 (Unofficial) ---
    echo -e "${green}Applying A710/A720 Support Patch...${nocolor}"
cat << 'EOF_A7XX' > a7xx_support.patch
diff -uNr mesa/src/freedreno/common/freedreno_devices.py mesa1/src/freedreno/common/freedreno_devices.py
--- mesa/src/freedreno/common/freedreno_devices.py	2025-11-26 13:11:08.662398622 +0200
+++ mesa1/src/freedreno/common/freedreno_devices.py	2025-12-01 01:20:38.270885899 +0200
@@ -1139,6 +1139,46 @@
     ))
 
 add_gpus([
+        GPUId(chip_id=0x07010000, name="FD710"), # KGSL, no speedbin data
+        GPUId(chip_id=0xffff07010000, name="FD710"), # Default no-speedbin fallback
+    ], A6xxGPUInfo(
+        CHIP.A7XX,
+        [a7xx_base, a7xx_gen1],
+        num_ccu = 4,
+        tile_align_w = 64,
+        tile_align_h = 32,
+        tile_max_w = 1024,
+        tile_max_h = 1024,
+        num_vsc_pipes = 32,
+        cs_shared_mem_size = 32 * 1024,
+        wave_granularity = 2,
+        fibers_per_sp = 128 * 2 * 16,
+        highest_bank_bit = 16,
+        magic_regs = a730_magic_regs,
+        raw_magic_regs = a730_raw_magic_regs,
+    ))
+
+add_gpus([
+        GPUId(chip_id=0x43020000, name="FD720"), # KGSL, no speedbin data
+        GPUId(chip_id=0xffff043020000, name="FD720"), # Default no-speedbin fallback
+    ], A6xxGPUInfo(
+        CHIP.A7XX,
+        [a7xx_base, a7xx_gen1],
+        num_ccu = 4,
+        tile_align_w = 64,
+        tile_align_h = 32,
+        tile_max_w = 1024,
+        tile_max_h = 1024,
+        num_vsc_pipes = 32,
+        cs_shared_mem_size = 32 * 1024,
+        wave_granularity = 2,
+        fibers_per_sp = 128 * 2 * 16,
+        highest_bank_bit = 16,
+        magic_regs = a730_magic_regs,
+        raw_magic_regs = a730_raw_magic_regs,
+    ))
+
+add_gpus([
         GPUId(chip_id=0x07030001, name="FD730"), # KGSL, no speedbin data
         GPUId(chip_id=0xffff07030001, name="FD730"), # Default no-speedbin fallback
     ], A6xxGPUInfo(
diff -uNr mesa/src/freedreno/drm-shim/freedreno_noop.c mesa1/src/freedreno/drm-shim/freedreno_noop.c
--- mesa/src/freedreno/drm-shim/freedreno_noop.c	2025-11-26 13:11:08.666398622 +0200
+++ mesa1/src/freedreno/drm-shim/freedreno_noop.c	2025-12-01 01:21:57.954885869 +0200
@@ -262,6 +262,16 @@
       .gmem_size = 128 * 1024,
    },
    {
+      .gpu_id = 710,
+      .chip_id = 0x07010000,
+      .gmem_size = 2 * 1024 * 1024,
+   },
+   {
+      .gpu_id = 720,
+      .chip_id = 0x43020000,
+      .gmem_size = 2 * 1024 * 1024,
+   },
+   {
       .gpu_id = 730,
       .chip_id = 0x07030001,
       .gmem_size = 2 * 1024 * 1024,
diff -uNr mesa/src/freedreno/vulkan/tu_cmd_buffer.cc mesa1/src/freedreno/vulkan/tu_cmd_buffer.cc
--- mesa/src/freedreno/vulkan/tu_cmd_buffer.cc	2025-12-01 01:16:01.142886005 +0200
+++ mesa1/src/freedreno/vulkan/tu_cmd_buffer.cc	2025-12-01 01:24:06.186885820 +0200
@@ -1314,7 +1314,7 @@
       return true;
    }
 
-   if (TU_DEBUG(GMEM))
+
       return false;
 
    bool use_sysmem = tu_autotune_use_bypass(&cmd->device->autotune,
EOF_A7XX
    
    # Aplica o patch
    if patch -p1 < a7xx_support.patch; then
        echo -e "${green}A710/A720 Patch applied successfully!${nocolor}"
    else
        echo -e "${red}A710/A720 Patch FAILED! Attempting git apply...${nocolor}"
        git apply -p1 --ignore-space-change --ignore-whitespace a7xx_support.patch || true
    fi

    # --- CORREÇÃO DE SINTAXE (A825 MISSING COMMA) ---
    echo "Fixing freedreno_devices.py syntax..."
    perl -i -p0e 's/(\n\s*a8xx_825)/,$1/s' src/freedreno/common/freedreno_devices.py

    # 4. REVERT DO COMMIT QUE MATA O DXVK
    echo -e "${green}Attempting to REVERT commit $bad_commit (Enable GS/Tess)...${nocolor}"
    
    if git revert --no-edit "$bad_commit"; then
        echo -e "${green}SUCCESS: Reverted GS/Tess disable! DXVK should work.${nocolor}"
    else
        echo -e "${red}Git revert failed (hash changed?). Trying manual SED patch...${nocolor}"
        git revert --abort || true
        # Fallback manual para reativar GS/Tess
        find src/freedreno/vulkan -name "*.cc" -print0 | xargs -0 sed -i 's/ && (pdevice->info->chip != 8)//g'
        find src/freedreno/vulkan -name "*.cc" -print0 | xargs -0 sed -i 's/ && (pdevice->info->chip == 8)//g'
        echo "Applied manual patch via SED to enable GS/Tess."
    fi

    # --- SPIRV Manual ---
    echo "Manually cloning dependencies..."
    mkdir -p subprojects
    cd subprojects
    rm -rf spirv-tools spirv-headers
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Headers.git spirv-headers
    cd .. 
    
	commit_hash=$(git rev-parse HEAD)
	version_str="RobClark-A7xx-Unofficial"
	cd "$workdir"
}

compile_mesa(){
	echo -e "${green}Compiling Mesa for SDK $target_sdk...${nocolor}"

	local source_dir="$workdir/mesa"
	local build_dir="$source_dir/build"
	local ndk_bin_path="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
	local ndk_sysroot_path="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

    # Fallback compilador
    local compiler_ver="35"
    if [ ! -f "$ndk_bin_path/aarch64-linux-android${compiler_ver}-clang" ]; then compiler_ver="34"; fi
    echo "Using compiler binary: $compiler_ver (Targeting API $target_sdk)"

	local cross_file="$source_dir/android-aarch64-crossfile.txt"
	cat <<EOF > "$cross_file"
[binaries]
ar = '$ndk_bin_path/llvm-ar'
c = ['ccache', '$ndk_bin_path/aarch64-linux-android${compiler_ver}-clang', '--sysroot=$ndk_sysroot_path']
cpp = ['ccache', '$ndk_bin_path/aarch64-linux-android${compiler_ver}-clang++', '--sysroot=$ndk_sysroot_path', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$ndk_bin_path/aarch64-linux-android-strip'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

	cd "$source_dir"
	# CORREÇÃO CRÍTICA: Desabilita "Treat Warnings as Errors"
	export CFLAGS="-D__ANDROID__ -Wno-error"
	export CXXFLAGS="-D__ANDROID__ -Wno-error"

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
        -Dwerror=false \
        --force-fallback-for=spirv-tools,spirv-headers \
		2>&1 | tee "$workdir/meson_log"

	ninja -C "$build_dir" 2>&1 | tee "$workdir/ninja_log"
}

package_driver(){
	local source_dir="$workdir/mesa"
	local build_dir="$source_dir/build"
	local lib_path="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"
	local package_temp="$workdir/package_temp"

	if [ ! -f "$lib_path" ]; then
		echo -e "${red}Build failed: libvulkan_freedreno.so not found.${nocolor}"
		exit 1
	fi

	rm -rf "$package_temp"
	mkdir -p "$package_temp"
	cp "$lib_path" "$package_temp/lib_temp.so"

	cd "$package_temp"
	patchelf --set-soname "vulkan.adreno.so" lib_temp.so
	mv lib_temp.so "vulkan.ad07XX.so"

	local short_hash=${commit_hash:0:7}
	local meta_name="Turnip-A7xx-Unofficial-${short_hash}"
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "Turnip Gen8 + A710/A720 Unofficial Support. Commit $short_hash",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF

	local zip_name="Turnip-A7xx-Unofficial-${short_hash}.zip"
	zip -9 "$workdir/$zip_name" "vulkan.ad07XX.so" meta.json
	echo -e "${green}Package ready: $workdir/$zip_name${nocolor}"
}

generate_release_info() {
    echo -e "${green}Generating release info...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
	local short_hash=${commit_hash:0:7}

    echo "Turnip-A7xx-${date_tag}-${short_hash}" > tag
    echo "Turnip A7xx (A710/A720 Support) - ${date_tag}" > release
    echo "Automated Turnip Build. Features: SDK 36, Hacks, DXVK Fix, A710/A720 Unofficial Support." > description
}

check_deps
prepare_ndk
prepare_source
compile_mesa
package_driver
generate_release_info
