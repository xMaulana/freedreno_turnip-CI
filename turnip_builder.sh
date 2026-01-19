#!/bin/bash -e

#Define variables
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'
deps="git meson ninja patchelf unzip curl pip flex bison zip glslang glslangValidator"
workdir="$(pwd)/turnip_workdir"
magiskdir="$workdir/turnip_module"
ndkver="android-ndk-r29"
ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
sdkver="34"
mesasrc="https://github.com/xMaulana/mesa-tu8-A825"
srcfolder="mesa"
mesa_branch="${MESA_BRANCH:-main}"

clear

#There are 4 functions here, simply comment to disable.
#You can insert your own function and make a pull request.
run_all(){
	echo "====== Begin building TU V$BUILD_VERSION! ======"
	check_deps
	prepare_workdir
	apply_custom_patches
	build_lib_for_android $mesa_branch
	#build_lib_for_android gen8-yuck
}

apply_custom_patches(){
    echo -e "${green}Applying Custom Patches...${nocolor}"

    # Patch: Disable Workgroup Memory Explicit Layout
    cat <<'EOF' > patch_layout.diff
diff --git a/src/freedreno/vulkan/tu_device.cc b/src/freedreno/vulkan/tu_device.cc
--- a/src/freedreno/vulkan/tu_device.cc
+++ b/src/freedreno/vulkan/tu_device.cc
@@ -222,7 +222,7 @@
       .KHR_variable_pointers = true,
       .KHR_vertex_attribute_divisor = true,
       .KHR_vulkan_memory_model = true,
-      .KHR_workgroup_memory_explicit_layout = true,
+      .KHR_workgroup_memory_explicit_layout = false,
       .KHR_zero_initialize_workgroup_memory = true,
 
       .EXT_4444_formats = true,
@@ -494,11 +494,11 @@
    features->vertexAttributeInstanceRateDivisor = true;
    features->vertexAttributeInstanceRateZeroDivisor = true;
 
-   /* VK_KHR_workgroup_memory_explicit_layout */
-   features->workgroupMemoryExplicitLayout = true;
-   features->workgroupMemoryExplicitLayoutScalarBlockLayout = true;
-   features->workgroupMemoryExplicitLayout8BitAccess = true;
-   features->workgroupMemoryExplicitLayout16BitAccess = true;
+      /* VK_KHR_workgroup_memory_explicit_layout */
+   features->workgroupMemoryExplicitLayout = false;
+   features->workgroupMemoryExplicitLayoutScalarBlockLayout = false;
+   features->workgroupMemoryExplicitLayout8BitAccess = false;
+   features->workgroupMemoryExplicitLayout16BitAccess = false;
 
    /* VK_EXT_4444_formats */
    features->formatA4R4G4B4 = true;
EOF
    patch -p1 --fuzz=3 < patch_layout.diff || echo "Warn: Patch Layout failed"

    # Patch: Force TU_DEBUG=nolrz
    cat <<'EOF' > patch_debug.diff
diff --git a/src/freedreno/vulkan/tu_util.cc b/src/freedreno/vulkan/tu_util.cc
--- a/src/freedreno/vulkan/tu_util.cc
+++ b/src/freedreno/vulkan/tu_util.cc
@@ -130,7 +130,8 @@
 static void
 tu_env_init_once(void)
 {
-   tu_env.start_debug = tu_env.debug = parse_debug_string(os_get_option("TU_DEBUG"), tu_debug_options);
+   uint64_t default_flags = TU_DEBUG_NOLRZ;
+   tu_env.start_debug = tu_env.debug = parse_debug_string(os_get_option("TU_DEBUG"), tu_debug_options) | default_flags;
 
    if (TU_DEBUG(STARTUP))
       mesa_logi("TU_DEBUG=0x%" PRIx64, tu_env.debug.load());
EOF
    patch -p1 --fuzz=3 < patch_debug.diff || echo "Warn: Patch Debug failed"

}
    
check_deps(){
	echo "Checking system for required Dependencies ..."
		for deps_chk in $deps;
			do
				sleep 0.25
				if command -v "$deps_chk" >/dev/null 2>&1 ; then
					echo -e "$green - $deps_chk found $nocolor"
				else
					echo -e "$red - $deps_chk not found, can't countinue. $nocolor"
					deps_missing=1
				fi;
			done

		if [ "$deps_missing" == "1" ]
			then echo "Please install missing dependencies" && exit 1
		fi

	echo "Installing python Mako dependency (if missing) ..." $'\n'
		pip install mako &> /dev/null
}

prepare_workdir(){
	echo "Preparing work directory ..." $'\n'
		mkdir -p "$workdir" && cd "$_"

	echo "Downloading android-ndk from google server ..." $'\n'
		curl https://dl.google.com/android/repository/"$ndkver"-linux.zip --output "$ndkver"-linux.zip &> /dev/null
	echo "Exracting android-ndk ..." $'\n'
		unzip "$ndkver"-linux.zip &> /dev/null

	echo "Downloading mesa source from branch: $mesa_branch ..." $'\n'
		if [ -n "$mesa_branch" ] && [ "$mesa_branch" != "main" ]; then
			git clone $mesasrc --depth=1 --branch $mesa_branch $srcfolder
		else
			git clone $mesasrc --depth=1 --no-single-branch $srcfolder
		fi
		cd $srcfolder
	echo "Pushing TU_VERSION..."
		echo "#define TUGEN8_DRV_VERSION \"v$BUILD_VERSION\"" > ./src/freedreno/vulkan/tu_version.h
}


build_lib_for_android(){
	echo "==== Building Mesa on $1 branch ===="
	git chechkout origin/$mesa_branch
	#Workaround for using Clang as c compiler instead of GCC
	mkdir -p "$workdir/bin"
	ln -sf "$ndk/clang" "$workdir/bin/cc"
	ln -sf "$ndk/clang++" "$workdir/bin/c++"
	export PATH="$workdir/bin:$ndk:$PATH"
	export CC=clang
	export CXX=clang++
	export AR=llvm-ar
	export RANLIB=llvm-ranlib
	export STRIP=llvm-strip
	export OBJDUMP=llvm-objdump
	export OBJCOPY=llvm-objcopy
	export LDFLAGS="-fuse-ld=lld"

	echo "Generating build files ..." $'\n'
		cat <<EOF >"android-aarch64.txt"
[binaries]
ar = '$ndk/llvm-ar'
c = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang']
cpp = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = '$ndk/ld.lld'
cpp_ld = '$ndk/ld.lld'
strip = '$ndk/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$ndk/pkg-config', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

		cat <<EOF >"native.txt"
[build_machine]
c = ['ccache', 'clang']
cpp = ['ccache', 'clang++']
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

		meson setup build-android-aarch64 \
			--cross-file "android-aarch64.txt" \
			--native-file "native.txt" \
			--prefix /tmp/turnip-$1 \
			-Dbuildtype=release \
			-Db_lto=true \
   			-Db_lto_mode=thin \
			-Dstrip=true \
			-Dplatforms=android \
			-Dvideo-codecs= \
			-Dplatform-sdk-version="$sdkver" \
			-Dandroid-stub=true \
			-Dgallium-drivers= \
			-Dvulkan-drivers=freedreno \
			-Dvulkan-beta=true \
			-Dfreedreno-kmds=kgsl \
			-Degl=disabled \
			-Dplatform-sdk-version=36 \
			-Dandroid-libbacktrace=disabled \
			--reconfigure

	echo "Compiling build files ..." $'\n'
		ninja -C build-android-aarch64 install

	if ! [ -a /tmp/turnip-$1/lib/libvulkan_freedreno.so ]; then
		echo -e "$red Build failed! $nocolor" && exit 1
	fi
	echo "Making the archive"
	cd /tmp/turnip-$1/lib
	cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "A825 v$BUILD_VERSION",
  "description": "A825 support fixed. Built from $1 branch",
  "author": "whitebelyash (mod xmaulana)",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan 1.4.335",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF
zip /tmp/a8xx-V$BUILD_VERSION-$mesa_branch.zip libvulkan_freedreno.so meta.json
cd -
if ! [ -a /tmp/a8xx-V$BUILD_VERSION-$mesa_branch.zip ]; then
	echo -e "$red Failed to pack the archive! $nocolor"
fi
}

run_all
