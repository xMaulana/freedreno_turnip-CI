#!/bin/bash
set -e

# --- CORES E FORMATAÇÃO ---
BOLD='\033[1m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() { echo -e "${BLUE}${BOLD}[BUILDER]${NC} $1"; }


VERSION_TAG="$1"
if [ -z "$VERSION_TAG" ]; then VERSION_TAG="dev"; fi

ROOT_DIR="$(pwd)/workspace"
OUT_DIR="$(pwd)/out"
NDK_VER="android-ndk-r29" # Usando r29 igual ao original para garantir compatibilidade
SDK_API="34" 


REPO_URL="https://github.com/whitebelyash/mesa-tu8"
BRANCH="gen8-hacks"


PYTHON_DEPS="mako meson"

# --- INÍCIO ---
mkdir -p "$ROOT_DIR" "$OUT_DIR"
cd "$ROOT_DIR"

log "Checking dependencies..."
pip3 install $PYTHON_DEPS --break-system-packages > /dev/null 2>&1 || pip3 install $PYTHON_DEPS > /dev/null 2>&1

# --- SETUP NDK ---
if [ ! -d "$NDK_VER" ]; then
    log "Downloading NDK ($NDK_VER)..."
    curl -L -o ndk.zip "https://dl.google.com/android/repository/${NDK_VER}-linux.zip" > /dev/null
    log "Extracting NDK..."
    unzip -q ndk.zip
    rm ndk.zip
fi
export ANDROID_NDK_HOME="$ROOT_DIR/$NDK_VER"
NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
export PATH="$NDK_BIN:$PATH"

# --- CLONANDO FONTE ---
if [ -d "mesa" ]; then rm -rf mesa; fi
log "Cloning Mesa ($BRANCH)..."
git clone --depth 1 --branch "$BRANCH" "$REPO_URL" mesa
cd mesa

# --- CONFIGURANDO MESON ---
CROSS_FILE="android-cross.txt"
log "Generating Cross-Compilation file..."

# Truque: Definir os caminhos explicitamente para evitar symlinks
cat <<EOF > "$CROSS_FILE"
[binaries]
c = '$NDK_BIN/aarch64-linux-android${SDK_API}-clang'
cpp = '$NDK_BIN/aarch64-linux-android${SDK_API}-clang++'
ar = '$NDK_BIN/llvm-ar'
strip = '$NDK_BIN/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$ANDROID_NDK_HOME/pkg-config', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

BUILD_DIR="build-android"
log "Configuring Build (Meson)..."

# AS FLAGS MÁGICAS (Essenciais para funcionar igual ao outro)
# -Dandroid-libbacktrace=disabled -> O SEGREDO para não crashar no Yuzu
# -Dvideo-codecs= -> Remove bloatware
# -Dplatform-sdk-version=36 -> Otimização para Android 15/16

meson setup "$BUILD_DIR" \
    --cross-file "$CROSS_FILE" \
    -Dbuildtype=release \
    -Dplatforms=android \
    -Dplatform-sdk-version=36 \
    -Dandroid-stub=true \
    -Dgallium-drivers= \
    -Dvulkan-drivers=freedreno \
    -Dfreedreno-kmds=kgsl \
    -Degl=disabled \
    -Dglx=disabled \
    -Db_lto=true \
    -Dvulkan-beta=true \
    -Dandroid-libbacktrace=disabled \
    -Dvideo-codecs= \
    --force-fallback-for=spirv-tools,spirv-headers

log "Compiling (Ninja)..."
ninja -C "$BUILD_DIR"

# --- EMPACOTAMENTO ---
LIB_PATH="$BUILD_DIR/src/freedreno/vulkan/libvulkan_freedreno.so"

if [ ! -f "$LIB_PATH" ]; then
    echo "Erro: Driver não compilou!"
    exit 1
fi

log "Packaging..."
PKG_DIR="package_tmp"
mkdir -p "$PKG_DIR"
cp "$LIB_PATH" "$PKG_DIR/libvulkan_freedreno.so"

# Criando JSON
cat <<EOF > "$PKG_DIR/meta.json"
{
  "schemaVersion": 1,
  "name": "Turnip A8xx $VERSION_TAG",
  "description": "Adreno 8xx Driver. Built from gen8-hacks.",
  "author": "Turnip CI",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan 1.4",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF

cd "$PKG_DIR"
ZIP_NAME="$OUT_DIR/Turnip-A8xx-${VERSION_TAG}.zip"
zip -q -9 "$ZIP_NAME" libvulkan_freedreno.so meta.json

log "Done! Artifact at: $ZIP_NAME"
