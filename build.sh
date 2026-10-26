
#!/usr/bin/env bash

# Thunder Kernel Build Script
# ZyC-Clang 16 + ReSukiSU + SuSFS + KPM
# Supports: timelm, panotyv2, nethunter, evox, infinityx

set -Eeuo pipefail

# --------------------------------------------------
# Configuration
# --------------------------------------------------

TARGET_DEVICE="${1:-}"
KSU_MODE="${2:-}"

TOOLCHAIN_PATH="${TOOLCHAIN_PATH:-$HOME/zyc-clang/bin}"
export PATH="$TOOLCHAIN_PATH:/usr/lib/ccache:$PATH"

export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache_mikernel}"
export CCACHE_COMPILERCHECK=content
export CCACHE_SLOPPINESS=time_macros,include_file_mtime,include_file_ctime

export KBUILD_BUILD_USER="QCloudFx"
export KBUILD_BUILD_HOST="ThunderOS"
export KBUILD_BUILD_TIMESTAMP="$(date -u '+%a %b %d %T UTC %Y')"

# --------------------------------------------------
# Validation
# --------------------------------------------------

if [[ -z "$TARGET_DEVICE" ]]; then
    echo "Usage: bash build.sh <device> [ksu]"
    echo "Example: bash build.sh timelm ksu"
    exit 1
fi

if [[ ! -d "$TOOLCHAIN_PATH" ]]; then
    echo "ERROR: Toolchain directory does not exist:"
    echo "  $TOOLCHAIN_PATH"
    exit 1
fi

for tool in clang clang++ ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-strip; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: Required tool not found: $tool"
        exit 1
    fi
done

if [[ ! -f "arch/arm64/configs/${TARGET_DEVICE}_defconfig" ]]; then
    echo "ERROR: Defconfig not found:"
    echo "  arch/arm64/configs/${TARGET_DEVICE}_defconfig"
    echo
    echo "Available defconfigs:"
    find arch/arm64/configs -maxdepth 1 -name '*_defconfig' -printf '%f\n' | sort
    exit 1
fi

echo "=========================================="
echo " Thunder Kernel Builder"
echo "=========================================="
echo "Device       : $TARGET_DEVICE"
echo "Toolchain    : $TOOLCHAIN_PATH"
echo "KernelSU     : ${KSU_MODE:-disabled}"
echo "=========================================="

clang --version

# --------------------------------------------------
# Build arguments
# --------------------------------------------------

MAKE_ARGS=(
    ARCH=arm64
    SUBARCH=arm64
    O=out
    CC=clang
    HOSTCC=clang
    HOSTCXX=clang++
    CLANG_TRIPLE=aarch64-linux-gnu-
    LD=ld.lld
    AR=llvm-ar
    NM=llvm-nm
    OBJCOPY=llvm-objcopy
    OBJDUMP=llvm-objdump
    STRIP=llvm-strip
)

# --------------------------------------------------
# KernelSU setup
# --------------------------------------------------

KSU_ENABLE=0
KSU_ZIP_STR="NoKernelSU"

if [[ "$KSU_MODE" == "ksu" ]]; then
    KSU_ENABLE=1
    KSU_ZIP_STR="ReSukiSU-SuSFS-KPM"

    echo "Setting up BakaSU..."
    curl -fLSs \
        "https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh" \
        | bash

    echo "Setting up NoMount..."
    curl -fLSs \
        "https://raw.githubusercontent.com/maxsteeel/nomount/refs/heads/dev/kernel/setup.sh" \
        | bash
else
    echo "Building without KernelSU."
fi

# --------------------------------------------------
# Prepare workspace
# --------------------------------------------------

rm -rf out anykernel

echo "Cloning AnyKernel3..."

git clone \
    --depth=1 \
    --single-branch \
    --branch master \
    https://github.com/kiy017/AnyKernel3.git \
    anykernel

# --------------------------------------------------
# Configure kernel
# --------------------------------------------------

echo "Loading ${TARGET_DEVICE}_defconfig..."

make "${MAKE_ARGS[@]}" "${TARGET_DEVICE}_defconfig"

if [[ "$KSU_ENABLE" -eq 1 ]]; then
    echo "Enabling ReSukiSU + SuSFS + KPM..."

    scripts/config --file out/.config \
        -e KSU \
        -e THREAD_INFO_IN_TASK \
        -e KSU_SUSFS \
        -e KSU_SUSFS_SUS_PATH \
        -e KSU_SUSFS_SUS_MOUNT \
        -e KSU_SUSFS_SUS_KSTAT \
        -e KSU_SUSFS_SUS_KSTAT_REDIRECT \
        -e KSU_SUSFS_SPOOF_UNAME \
        -e KSU_SUSFS_ENABLE_LOG \
        -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
        -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
        -e KSU_SUSFS_OPEN_REDIRECT \
        -e KSU_SUSFS_SUS_MAP \
        -e KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT \
        -e KSU_MULTI_MANAGER_SUPPORT \
        -e KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT \
        -e KPM \
        -e TMPFS_XATTR \
        -e TMPFS_POSIX_ACL \
        -e NOMOUNT
else
    scripts/config --file out/.config -d KSU
fi

scripts/config --file out/.config \
    -e REKERNEL \
    -e REKERNEL_NETWORK

# Resolve dependencies and save final configuration.
make "${MAKE_ARGS[@]}" olddefconfig

# --------------------------------------------------
# Compile kernel
# --------------------------------------------------

echo "Building kernel with $(nproc) jobs..."

make "${MAKE_ARGS[@]}" -j"$(nproc)"

IMAGE="out/arch/arm64/boot/Image"
DTB_DIR="out/arch/arm64/boot/dts"
DTB_FILE="out/arch/arm64/boot/dtb"
IMAGE_DTB="out/arch/arm64/boot/Image-dtb"

if [[ ! -s "$IMAGE" ]]; then
    echo "ERROR: Kernel Image was not generated."
    exit 1
fi

echo "Kernel Image built successfully."

# --------------------------------------------------
# Apply KPM patch
# --------------------------------------------------

if [[ "$KSU_ENABLE" -eq 1 ]]; then
    PATCH_DIR="out/arch/arm64/boot"
    PATCH_URL="https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.13.0/patch_linux"

    echo "Downloading KPM patch..."

    curl -fL "$PATCH_URL" -o "$PATCH_DIR/patch_linux"
    chmod +x "$PATCH_DIR/patch_linux"

    (
        cd "$PATCH_DIR"
        ./patch_linux
    )

    if [[ ! -s "$PATCH_DIR/oImage" ]]; then
        echo "ERROR: KPM patch did not generate oImage."
        exit 1
    fi

    mv "$PATCH_DIR/oImage" "$IMAGE"
    rm -f "$PATCH_DIR/patch_linux"

    echo "KPM patch applied successfully."
fi

# --------------------------------------------------
# Collect DTBs
# --------------------------------------------------

if [[ ! -d "$DTB_DIR" ]]; then
    echo "ERROR: DTB directory not found: $DTB_DIR"
    exit 1
fi

mapfile -t DTB_FILES < <(find "$DTB_DIR" -type f -name '*.dtb' | sort)

if [[ "${#DTB_FILES[@]}" -eq 0 ]]; then
    echo "ERROR: No DTB files found."
    exit 1
fi

echo "Combining ${#DTB_FILES[@]} DTB files..."

cat "${DTB_FILES[@]}" > "$DTB_FILE"

# Always generate Image-dtb because packaging requires it.
cat "$IMAGE" "${DTB_FILES[@]}" > "$IMAGE_DTB"

if [[ ! -s "$IMAGE_DTB" || ! -s "$DTB_FILE" ]]; then
    echo "ERROR: Image-dtb or dtb generation failed."
    exit 1
fi

echo "Image-dtb generated successfully."

# --------------------------------------------------
# Package AnyKernel3
# --------------------------------------------------

rm -rf anykernel/kernels
mkdir -p anykernel/kernels

cp "$IMAGE_DTB" anykernel/
cp "$DTB_FILE" anykernel/

# --------------------------------------------------
# Create flashable ZIP
# --------------------------------------------------

ZIP_FILENAME="ThunderOS_${TARGET_DEVICE}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S').zip"

echo "Creating flashable ZIP..."

(
    cd anykernel
    zip -r9 "../$ZIP_FILENAME" . \
        -x '.git/*' '.gitignore' '*.zip'
)

if [[ ! -s "$ZIP_FILENAME" ]]; then
    echo "ERROR: Flashable ZIP was not generated."
    exit 1
fi

echo "=========================================="
echo " BUILD COMPLETED SUCCESSFULLY"
echo "=========================================="
echo "Device  : $TARGET_DEVICE"
echo "Kernel  : $IMAGE"
echo "DTB     : $DTB_FILE"
echo "Package : $ZIP_FILENAME"
echo "=========================================="
