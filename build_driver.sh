#!/bin/bash
set -e

# --- CONFIGURAÇÃO ---
# NDK r29 (Igual ao script de referência)
NDK_TAG="android-ndk-r29"
SDK_VER="34"

# Repositório do Whitebelyash (Hacks do A830)
REPO="https://github.com/whitebelyash/mesa-tu8"
BRANCH="gen8-hacks"

# Caminhos
ROOT="$(pwd)/build_env"
OUT="$(pwd)/out"

# 1. SETUP INICIAL
mkdir -p "$ROOT" "$OUT"
cd "$ROOT"

echo "[BUILD] Verificando dependências..."
# Garante Meson novo via Python (corrige erro do Ubuntu 24.04)
pip3 install meson mako --break-system-packages > /dev/null 2>&1 || pip3 install meson mako > /dev/null 2>&1

# 2. BAIXAR NDK
if [ ! -d "$NDK_TAG" ]; then
    echo "[BUILD] Baixando NDK r29..."
    curl -L -o ndk.zip "https://dl.google.com/android/repository/${NDK_TAG}-linux.zip" > /dev/null
    unzip -q ndk.zip
    rm ndk.zip
fi
export ANDROID_NDK_HOME="$ROOT/$NDK_TAG"
NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
export PATH="$NDK_BIN:$PATH"

# 3. CLONAR MESA
if [ -d "mesa" ]; then rm -rf mesa; fi
echo "[BUILD] Clonando fonte ($BRANCH)..."
git clone --depth 1 --branch "$BRANCH" "$REPO" mesa
cd mesa

# 4. CONFIGURAR MESON (Cross-file Manual)
echo "[BUILD] Gerando configuração..."
cat <<EOF > android-cross.txt
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

# 5. COMPILAR (Flags exatas que funcionam)
# -Dandroid-libbacktrace=disabled : CRÍTICO para não crashar
# -Dplatform-sdk-version=36 : Otimização para Android 16
echo "[BUILD] Compilando..."
meson setup build-android \
    --cross-file android-cross.txt \
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

ninja -C build-android

# 6. EMPACOTAR (A PARTE MAIS IMPORTANTE)
echo "[BUILD] Criando ZIP..."
LIB_SRC="build-android/src/freedreno/vulkan/libvulkan_freedreno.so"
TMP_DIR="pkg_temp"
rm -rf "$TMP_DIR" && mkdir -p "$TMP_DIR"

if [ ! -f "$LIB_SRC" ]; then
    echo "ERRO: O arquivo .so não foi gerado!"
    exit 1
fi

# COPIAR COM O NOME PADRÃO (NÃO MUDE ISSO)
cp "$LIB_SRC" "$TMP_DIR/libvulkan_freedreno.so"

# JSON PADRÃO
cat <<EOF > "$TMP_DIR/meta.json"
{
  "schemaVersion": 1,
  "name": "Turnip A830 v2",
  "description": "Turnip Gen8 (Standard Naming). Libbacktrace Disabled.",
  "author": "Turnip CI",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan 1.4",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF

# GERAR ZIP
cd "$TMP_DIR"
# O nome do zip pode ser qualquer coisa, mas o conteúdo NÃO.
zip -q -9 "$OUT/Turnip_A830_Fixed.zip" libvulkan_freedreno.so meta.json

echo "SUCESSO: Arquivo salvo em $OUT/Turnip_A830_Fixed.zip"
