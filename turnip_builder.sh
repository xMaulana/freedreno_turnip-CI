#!/bin/bash -e
set -o pipefail

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# Dependências
deps="ninja patchelf unzip curl pip flex bison zip git perl glslangValidator"
workdir="$(pwd)/turnip_workdir"

# --- CONFIGURAÇÃO ---
ndkver="android-ndk-r28"
target_sdk="36"

# 1. BASE: Mesa Oficial
base_repo="https://gitlab.freedesktop.org/mesa/mesa.git"

# 2. HACKS: Whitebelyash (Gen8 patches)
hacks_repo="https://github.com/whitebelyash/mesa-tu8.git"
hacks_branch="gen8"

# Commit que quebra o DXVK
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
		echo "Please install missing dependencies." && exit 1
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
	
    # 1. Clona Mesa Oficial
    echo "Cloning Official Mesa..."
	git clone --depth 100 "$base_repo" mesa
	cd mesa
    
    git config user.email "ci@turnip.builder"
    git config user.name "Turnip CI Builder"

    # 2. FETCH DA MR 39167 (Rob Clark - Elite Support)
    echo -e "${green}Fetching Rob Clark MR 39167 (Gen8 Support)...${nocolor}"
    git fetch "$base_repo" refs/merge-requests/39167/head:mr-39167
    git checkout mr-39167
    
    echo -e "${green}Base Commit (MR 39167):${nocolor}"
    git log -1 --format="%H - %cd - %s"

    # 3. MERGE DOS HACKS
    echo "Fetching Hacks from: $hacks_repo..."
    git remote add hacks "$hacks_repo"
    git fetch hacks "$hacks_branch"
    
    echo "Attempting Merge Hacks..."
    if ! git merge --no-edit "hacks/$hacks_branch" --allow-unrelated-histories; then
        echo -e "${red}Merge Conflict detected! Resolving by accepting Hacks...${nocolor}"
        git checkout --theirs .
        git add .
        git commit -m "Auto-resolved conflicts by accepting Hacks over MR 39167"
        echo -e "${green}Conflicts resolved. Hacks applied successfully.${nocolor}"
    fi

    echo "Fixing freedreno_devices.py syntax..."
    if [ -f "src/freedreno/common/freedreno_devices.py" ]; then
        perl -i -p0e 's/(\n\s*a8xx_825)/,$1/s' src/freedreno/common/freedreno_devices.py
    fi

    # 4. APLICAÇÃO DO PATCH SEMAPHORE (AGORA ALINHADO À ESQUERDA)
    echo -e "${green}Applying Semaphore Wait Patch...${nocolor}"
    
# O BLOCO ABAIXO NÃO PODE TER INDENTAÇÃO
cat << 'EOF' > semaphore_fix.patch
diff --git a/src/vulkan/runtime/vk_sync_timeline.c b/src/vulkan/runtime/vk_sync_timeline.c
--- a/src/vulkan/runtime/vk_sync_timeline.c
+++ b/src/vulkan/runtime/vk_sync_timeline.c
@@ -436,45 +436,26 @@ static VkResult
 vk_sync_timeline_wait_locked(struct vk_device *device,
                              struct vk_sync_timeline_state *state,
                              uint64_t wait_value,
                              enum vk_sync_wait_flags wait_flags,
                              uint64_t abs_timeout_ns)
 {
    struct timespec abs_timeout_ts;
    timespec_from_nsec(&abs_timeout_ts, abs_timeout_ns);
 
-   /* Wait on the queue_submit condition variable until the timeline has a
-    * time point pending that's at least as high as wait_value.
-    */
-   while (state->highest_pending < wait_value) {
-      int ret = u_cnd_monotonic_timedwait(&state->cond, &state->mutex,
-                                          &abs_timeout_ts);
-      if (ret == thrd_timedout)
-         return VK_TIMEOUT;
-
-      if (ret != thrd_success)
-         return vk_errorf(device, VK_ERROR_UNKNOWN, "cnd_timedwait failed");
-   }
-
-   if (wait_flags & VK_SYNC_WAIT_PENDING)
-      return VK_SUCCESS;
-
-   VkResult result = vk_sync_timeline_gc_locked(device, state, false);
-   if (result != VK_SUCCESS)
-      return result;
-
-   while (state->highest_past < wait_value) {
-      struct vk_sync_timeline_point *point = vk_sync_timeline_first_point(state);
-
-      /* Drop the lock while we wait. */
-      vk_sync_timeline_ref_point_locked(point);
-      mtx_unlock(&state->mutex);
-
-      result = vk_sync_wait(device, &point->sync, 0,
-                            VK_SYNC_WAIT_COMPLETE,
-                            abs_timeout_ns);
-
-      /* Pick the mutex back up */
-      mtx_lock(&state->mutex);
-      vk_sync_timeline_unref_point_locked(device, state, point);
-
-      /* This covers both VK_TIMEOUT and VK_ERROR_DEVICE_LOST */
-      if (result != VK_SUCCESS)
-         return result;
-
-      vk_sync_timeline_complete_point_locked(device, state, point);
-   }
-
-   return VK_SUCCESS;
+    /* Wait until the timeline reaches the requested value */
+    while (state->highest_past < wait_value) {
+        struct vk_sync_timeline_point *point = NULL;
+
+        /* Get the first pending point >= wait_value */
+        list_for_each_entry(struct vk_sync_timeline_point, p,
+                            &state->pending_points, link) {
+            if (p->value >= wait_value) {
+                vk_sync_timeline_ref_point_locked(p);
+                point = p;
+                break;
+            }
+        }
+
+        if (!point) {
+            /* Nothing pending, just wait on condition variable */
+            int ret = u_cnd_monotonic_timedwait(&state->cond, &state->mutex, &abs_timeout_ts);
+            if (ret == thrd_timedout)
+                return VK_TIMEOUT;
+            if (ret != thrd_success)
+                return vk_errorf(device, VK_ERROR_UNKNOWN, "cnd_timedwait failed");
+            continue;
+        }
+
+        /* Unlock while waiting on this specific timeline point */
+        mtx_unlock(&state->mutex);
+        VkResult r = vk_sync_wait(device, &point->sync, 0, VK_SYNC_WAIT_COMPLETE, abs_timeout_ns);
+        mtx_lock(&state->mutex);
+
+        vk_sync_timeline_unref_point_locked(device, state, point);
+
+        if (r != VK_SUCCESS)
+            return r;
+
+        vk_sync_timeline_complete_point_locked(device, state, point);
+    }
+
+    return VK_SUCCESS;
 }
EOF
    
    # Aplica ignorando espaço em branco e mudanças de espaço
    if git apply --ignore-space-change --ignore-whitespace semaphore_fix.patch; then
        echo -e "${green}SUCCESS: Semaphore Patch applied!${nocolor}"
    else
        echo -e "${red}Semaphore Patch Failed! Retrying with 3-way merge...${nocolor}"
        git apply -3 semaphore_fix.patch || echo -e "${red}Final Failure on Patch (Check indentation).${nocolor}"
    fi

    # 5. DXVK FIX (GS/Tessellation)
    echo -e "${green}Applying DXVK Fixes...${nocolor}"
    
    if git revert --no-edit "$bad_commit" 2>/dev/null; then
        echo -e "${green}SUCCESS: Reverted commit $bad_commit via Git.${nocolor}"
    else
        echo -e "${red}Git revert failed. Applying MANUAL patch...${nocolor}"
        git revert --abort || true
        # Fallback manual
        find src/freedreno/vulkan -name "*.cc" -print0 | xargs -0 sed -i 's/ && (pdevice->info->chip != 8)//g'
        find src/freedreno/vulkan -name "*.cc" -print0 | xargs -0 sed -i 's/ && (pdevice->info->chip == 8)//g'
    fi

    # --- SPIRV Manual ---
    echo "Cloning SPIRV dependencies..."
    mkdir -p subprojects
    cd subprojects
    rm -rf spirv-tools spirv-headers
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Headers.git spirv-headers
    cd .. 
    
	commit_hash=$(git rev-parse HEAD)
	version_str="MR39167-Hacks-SemaphoreFix"
	cd "$workdir"
}

compile_mesa(){
	echo -e "${green}Compiling Mesa for SDK $target_sdk...${nocolor}"

	local source_dir="$workdir/mesa"
	local build_dir="$source_dir/build"
	local ndk_bin_path="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
	local ndk_sysroot_path="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

    local compiler_ver="35"
    if [ ! -f "$ndk_bin_path/aarch64-linux-android${compiler_ver}-clang" ]; then compiler_ver="34"; fi
    echo "Using compiler: Clang $compiler_ver"

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
	patchelf --set-soname "vulkan.adreno.so" lib_temp.so
	mv lib_temp.so "vulkan.ad08XX.so"

	local short_hash=${commit_hash:0:7}
	local meta_name="Turnip-MR39167-Plus-SemaphoreFix-${short_hash}"
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "Turnip Hybrid (RobClark MR 39167 + Hacks + Semaphore Fix). Commit $short_hash",
  "author": "StevenMX",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad08XX.so"
}
EOF

	local zip_name="Turnip-MR39167-Plus-SemaphoreFix-${short_hash}.zip"
	zip -9 "$workdir/$zip_name" "vulkan.ad08XX.so" meta.json
	echo -e "${green}Package ready: $workdir/$zip_name${nocolor}"
}

generate_release_info() {
    echo -e "${green}Generating release info...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
	local short_hash=${commit_hash:0:7}

    echo "Turnip-Elite-Fixed-${date_tag}-${short_hash}" > tag
    echo "Turnip Elite (Fixed Semaphore) - ${date_tag}" > release
    echo "Base: RobClark MR 39167. Hacks: Whitebelyash/gen8. Includes Semaphore Fix & DXVK fixes." > description
}

check_deps
prepare_ndk
prepare_source
compile_mesa
package_driver
generate_release_info
