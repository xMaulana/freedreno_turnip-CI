#!/bin/bash
set -e

# --- ESTÉTICA (Para parecer diferente) ---
BOLD='\033[1m'
BLUE='\033[0;34m'
NC='\033[0m'
log() { echo -e "${BLUE}${BOLD}[BUILD]${NC} $1"; }

# --- VARIÁVEIS (Mesmos valores do script que funciona) ---
TAG="$1"
[ -z "$TAG" ] && TAG="dev"

ROOT="$(pwd)/workspace"
OUT="$(pwd)/out"
NDK_PKG="android-ndk-r29" # Usando r29 igual ao original
SDK_VER="34"              # SDK 34 para ferramentas

# Repositório Whitebelyash
REPO="https://github.com/whitebelyash/mesa-tu8"
BRANCH="gen8-hacks"

mkdir -p "$ROOT" "$OUT"
cd "$ROOT"

# --- 1. PREPARAR NDK ---
if [ ! -d "$NDK_PKG" ]; then
    log "Downloading NDK r29..."
    curl -L -o ndk.zip "https://dl.google.com/android/repository/${NDK_PKG}-linux.zip" > /dev/null
    unzip -q ndk.zip
    rm ndk.zip
fi
export ANDROID_NDK_HOME="$ROOT/$NDK_PKG"
NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
export PATH="$NDK_BIN:$PATH"

# --- 2. BAIXAR FONTE ---
if [ -d "mesa" ]; then rm -rf mesa; fi
log "Cloning Mesa ($BRANCH)..."
git clone --depth 1 --branch "$BRANCH" "$REPO" mesa
cd mesa

# --- 3. CONFIGURAR AMBIENTE (Simulando o native.txt e android.txt do original) ---
CROSS="android-cross.txt"
log "Generating config..."

# O segredo: Usar os compiladores do NDK r29 explicitamente
cat <<EOF > "$CROSS"
[binaries]
c = '$NDK_BIN/aarch64-linux-android${SDK_VER}-clang'
cpp = '$NDK_BIN/aarch64-linux-android${SDK_VER}-clang++'
ar = '$NDK_BIN/llvm-ar'
strip = '$NDK_BIN/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$ANDROID_NDK_HOME/pkg-config', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

# --- 4. COMPILAÇÃO (Onde a mágica acontece) ---
BUILD_DIR="build-android"

# AS FLAGS CRÍTICAS DO SCRIPT QUE FUNCIONA:
# 1. -Dandroid-libbacktrace=disabled (Vital para Yuzu/Switch)
# 2. -Dplatform-sdk-version=36 (Otimização Adreno 8xx)
# 3. -Dvideo-codecs= (Remove lixo)

log "Running Meson..."
meson setup "$BUILD_DIR" \
    --cross-file "$CROSS" \
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

# --- 5. EMPACOTAMENTO ---
LIB_FILE="$BUILD_DIR/src/freedreno/vulkan/libvulkan_freedreno.so"

if [ ! -f "$LIB_FILE" ]; then
    echo "Erro: Falha na compilação!"
    exit 1
fi

log "Creating Zip..."
TMP_PKG="package_tmp"
rm -rf "$TMP_PKG" && mkdir -p "$TMP_PKG"

# Copia com o nome original (libvulkan_freedreno.so) pois emuladores gostam disso
cp "$LIB_FILE" "$TMP_PKG/libvulkan_freedreno.so"

# JSON idêntico ao original, apenas mudando o autor
cat <<EOF > "$TMP_PKG/meta.json"
{
  "schemaVersion": 1,
  "name": "Turnip A8xx $TAG",
  "description": "Adreno 8xx Driver. Built from gen8-hacks. Libbacktrace disabled.",
  "author": "Turnip CI",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan 1.4",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF

cd "$TMP_PKG"
ZIP_NAME="$OUT/Turnip-A8xx-${TAG}.zip"
zip -q -9 "$ZIP_NAME" libvulkan_freedreno.so meta.json

log "Success! Output: $ZIP_NAME"
