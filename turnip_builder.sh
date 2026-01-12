#!/bin/bash -e
set -o pipefail

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="meson ninja patchelf unzip curl pip flex bison zip git perl"
workdir="$(pwd)/turnip_workdir"

# --- CONFIGURAÇÃO ---
ndkver="android-ndk-r28"
target_sdk="36"

# REPOSITÓRIOS
base_repo="https://gitlab.freedesktop.org/robclark/mesa.git"
base_branch="tu/gen8"

hacks_repo="https://github.com/whitebelyash/mesa-tu8.git"
hacks_branch="gen8-hacks"

# Commit que quebra o DXVK (Disable GS/Tess)
bad_commit="2f0ea1c6"

commit_hash=""
version_str=""

check_deps(){
	echo "Checking system dependencies ..."
	for dep in $deps; do
		if ! command -v $dep >/dev/null 2>&1; then
			echo -e "$red Missing dependency: $dep$nocolor"
			missing=1
		else
			echo -e "$green Found: $dep$nocolor"
		fi
	done
	if [ "$missing" == "1" ]; then
		echo "Please install missing dependencies." && exit 1
	fi
	pip install mako &> /dev/null || true
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
	
    # 1. Clona BASE (Rob Clark)
    echo "Cloning Base: $base_repo ($base_branch)..."
	git clone --branch "$base_branch" "$base_repo" mesa
	cd mesa

    git config user.email "ci@turnip.builder"
    git config user.name "Turnip CI Builder"

    # 2. APLICANDO MR !38808 (Primeiro)
    echo -e "${green}Fetching & Merging MR !38808...${nocolor}"
    git fetch https://gitlab.freedesktop.org/mesa/mesa.git merge-requests/38808/head:mr-38808
    if ! git merge --no-edit mr-38808; then
        echo -e "${red}Conflict in MR 38808. Forcing merge...${nocolor}"
        git checkout --theirs .
        git add .
        git commit -m "Force merge MR 38808"
    fi

    # 3. APLICANDO HACKS A830
    echo "Fetching Hacks from: $hacks_repo..."
    git remote add hacks "$hacks_repo"
    git fetch hacks "$hacks_branch"
    
    echo "Attempting Merge Hacks..."
    # Tentamos o merge. Se der conflito no freedreno_devices.py, vamos resolvê-lo manualmente abaixo.
    if ! git merge --no-edit -X theirs "hacks/$hacks_branch" --allow-unrelated-histories; then
        echo -e "${red}Merge Conflict detected! Forcing resolution...${nocolor}"
        git checkout --theirs .
        git add .
        git commit -m "Auto-resolved conflicts by forcing Hacks"
    fi
    
    # --- CORREÇÃO CRÍTICA DE SINTAXE ---
    echo -e "${green}Fixing freedreno_devices.py syntax...${nocolor}"
    
    # PASSO 1: Força o arquivo a ser idêntico ao do Hack (descarta a mistura quebrada do merge)
    git checkout hacks/gen8-hacks -- src/freedreno/common/freedreno_devices.py
    echo "Restored freedreno_devices.py from Hacks repo."

    # PASSO 2: Aplica a vírgula que falta no upstream (Bug conhecido do a825)
    # Procura a linha que contem 'a8xx_825 =' e insere uma vírgula no final da linha ANTERIOR
    sed -i -e '/a8xx_825 =/i ,' src/freedreno/common/freedreno_devices.py
    # Remove qualquer linha vazia que tenha ficado com apenas uma virgula e une com a anterior (limpeza)
    sed -i ':a;N;$!ba;s/\n,/,/g' src/freedreno/common/freedreno_devices.py 2>/dev/null || true
    # Garante que ficou visualmente correto (opcional, só para log)
    sed -i '/a8xx_825 =/i ,' src/freedreno/common/freedreno_devices.py
    
    # Método mais bruto e garantido: Substituir a quebra de linha antes do a825 por ", \n"
    # Resetamos o arquivo de novo para garantir
    git checkout hacks/gen8-hacks -- src/freedreno/common/freedreno_devices.py
    # Adiciona a vírgula na linha anterior ao a8xx_825
    sed -i ':a;N;$!ba;s/\(\n[[:space:]]*\)a8xx_825 =/, \1a8xx_825 =/g' src/freedreno/common/freedreno_devices.py
    
    echo "Syntax Fix Applied."

    # 4. REVERT DO COMMIT QUE MATA O DXVK (GS/Tess)
    echo -e "${green}Attempting to REVERT commit $bad_commit (Fix DXVK)...${nocolor}"
    
    if git revert --no-edit "$bad_commit"; then
        echo -e "${green}SUCCESS: Reverted GS/Tess disable! DXVK should work.${nocolor}"
    else
        echo -e "${red}Git revert failed. Applying manual SED patch...${nocolor}"
        git revert --abort || true
        # Patch manual para reativar GS/Tess
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
    if [ -f VERSION ]; then
	    version_str=$(cat VERSION | xargs)
	else
	    version_str="git-${commit_hash:0:7}"
	fi
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
	export CFLAGS="-D__ANDROID__"
	export CXXFLAGS="-D__ANDROID__"

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
    
    echo "Patching SONAME..."
	patchelf --set-soname "vulkan.adreno.so" lib_temp.so
	mv lib_temp.so "vulkan.adreno.so"

	local short_hash=${commit_hash:0:7}
    
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "Mesa Turnip A830 (MR 38808) Fixed",
  "description": "RobClark + Hacks + MR 38808 + Syntax Fix + DXVK Fix. SDK 36.",
  "author": "Turnip CI",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan 1.4 (Mesa $version_str)",
  "minApi": 27,
  "libraryName": "vulkan.adreno.so"
}
EOF

	local zip_name="Turnip-A830-MR38808-${short_hash}.zip"
	zip -9 "$workdir/$zip_name" "vulkan.adreno.so" meta.json
	echo -e "${green}Package ready: $workdir/$zip_name${nocolor}"
}

generate_release_info() {
    echo -e "${green}Generating release info...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
	local short_hash=${commit_hash:0:7}

    echo "Turnip-A830-MR38808-${date_tag}-${short_hash}" > tag
    echo "Turnip A830 (MR 38808 + Fix) - ${date_tag}" > release
    echo "Automated Turnip Build. SDK 36, DXVK Fix, MR 38808, Syntax Fix." > description
}

check_deps
prepare_ndk
prepare_source
compile_mesa
package_driver
generate_release_info
