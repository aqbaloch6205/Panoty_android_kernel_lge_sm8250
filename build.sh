#!/bin/bash

# Ensure the script exits on error
set -e

KERNEL_NAME="Thunder Next Gen 2.0"
KERNEL_ZIP_NAME="Thunder_Next_Gen_2.0"

TOOLCHAIN_PATH=$HOME/zyc-clang/bin
TARGET_DEVICE=$1

if [ -z "$1" ]; then
    echo "Error: No argument provided, please specific a target device." 
    echo "If you need KernelSU, please add [ksu] as the second arg."
    echo "Examples:"
    echo "Build for panoty without KernelSU:"
    echo "    bash build.sh panoty"
    echo "Build for panoty with KernelSU:"
    echo "    bash build.sh panoty ksu"
    exit 1
fi

if [ ! -d $TOOLCHAIN_PATH ]; then
    echo "TOOLCHAIN_PATH [$TOOLCHAIN_PATH] does not exist."
    echo "Please ensure the toolchain is there, or change TOOLCHAIN_PATH in the script to your toolchain path."
    exit 1
fi

echo "TOOLCHAIN_PATH: [$TOOLCHAIN_PATH]"
export PATH="$TOOLCHAIN_PATH:$PATH"

if ! command -v clang >/dev/null 2>&1; then
    echo "[clang] does not exist, please check your environment."
    exit 1
fi

# Enable ccache for speed up compiling 
export CCACHE_DIR="$HOME/.cache/ccache_mikernel" 
export CC="clang"
export CXX="clang++"
export PATH="/usr/lib/ccache:$PATH"
export CCACHE_COMPILERCHECK=content
export CCACHE_SLOPPINESS=time_macros,include_file_mtime,include_file_ctime
echo "CCACHE_DIR: [$CCACHE_DIR]"

# Export Build Info
export KBUILD_BUILD_USER="Qcloudfx"
export KBUILD_BUILD_HOST="Abdul Qadeer"
export KBUILD_BUILD_TIMESTAMP=$(TZ="Asia/Karachi" date)

MAKE_ARGS="ARCH=arm64 \
           SUBARCH=arm64 \
           O=out \
           CC=clang \
           HOSTCC=clang \
           CLANG_TRIPLE=aarch64-linux-gnu- \
           LD=ld.lld \
           AR=llvm-ar \
           NM=llvm-nm \
           OBJCOPY=llvm-objcopy \
           OBJDUMP=llvm-objdump \
           STRIP=llvm-strip \
           KCFLAGS=-Wno-error"

if [ "$1" == "j1" ]; then
    make $MAKE_ARGS -j1
    exit
fi

if [ "$1" == "continue" ]; then
    make $MAKE_ARGS -j$(nproc)
    exit
fi

if [ ! -f "arch/arm64/configs/${TARGET_DEVICE}_defconfig" ]; then
    echo "No target device [${TARGET_DEVICE}] found."
    echo "Avaliable defconfigs, please choose one target from below down:"
    ls arch/arm64/configs/*_defconfig
    exit 1
fi

# Check clang version
echo "[clang --version]:"
clang --version

KSU_ZIP_STR=NoKernelSU
if [ "$2" == "ksu" ]; then
    KSU_ENABLE=1
    KSU_ZIP_STR=ReSukiSU-SuSFS-KPM
else
    KSU_ENABLE=0
fi

echo "KERNEL_NAME: $KERNEL_NAME"
echo "TARGET_DEVICE: $TARGET_DEVICE"

# Dev's original KSU setup logic
if [ $KSU_ENABLE -eq 1 ]; then
    echo "KSU is enabled"
    curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash
else
    echo "KSU is disabled"
fi

# ------------- Fix: ufshcd unused-function -Werror (clang 16) -------------
# Only touches drivers/scsi/ufs/ufshcd.c, safe to run multiple times.
echo "Applying ufshcd unused-function fix..."
sed -i 's/^static void ufshcd_add_cmd_upiu_trace(/static void __maybe_unused ufshcd_add_cmd_upiu_trace(/' drivers/scsi/ufs/ufshcd.c
sed -i 's/^static void __ufshcd_cmd_log(/static void __maybe_unused __ufshcd_cmd_log(/' drivers/scsi/ufs/ufshcd.c
grep -n "__maybe_unused" drivers/scsi/ufs/ufshcd.c | head -n 5 || true

# Clear Previous Build
rm -rf out/
rm -rf anykernel/

echo "Clone AnyKernel3 for packing $KERNEL_NAME"
git clone https://github.com/aqbaloch6205/AnyKernel3.git -b master --single-branch --depth=1 anykernel

# ------------- Building Kernel (Dev's Exact Logic) -------------

echo "Building Kernel......"
make $MAKE_ARGS ${TARGET_DEVICE}_defconfig

if [ $KSU_ENABLE -eq 1 ]; then
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
    -e TMPFS_POSIX_ACL
else
    scripts/config --file out/.config -d KSU
fi

scripts/config --file out/.config \
    -e REKERNEL \
    -e REKERNEL_NETWORK

make $MAKE_ARGS -j$(nproc)

# Check if kernel image exists
if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "The file [out/arch/arm64/boot/Image] exists. Kernel Build successfully."
else
    echo "The file [out/arch/arm64/boot/Image] does not exist. Seems Kernel build failed."
    exit 1
fi

# --- KPM PATCHING (FIXED ORDER: Patch Image before merging DTB) ---
if [ $KSU_ENABLE -eq 1 ]; then
    echo "Applying KPM patch via patch_linux..."
    cd out/arch/arm64/boot/
    wget -q https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.13.0/patch_linux
    chmod +x patch_linux
    ./patch_linux
    if [ -f "oImage" ]; then
        rm Image
        mv oImage Image
        rm -f patch_linux
        echo "KPM patch successful!"
    else
        echo "KPM patch failed!"
        exit 1
    fi
    cd -
fi

echo "Generating [out/arch/arm64/boot/dtb]......"
find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + > out/arch/arm64/boot/dtb

rm -rf anykernel/kernels/

# Dev's Logic: Merge Patched Image + DTBs into Image-dtb
if [ ! -f "out/arch/arm64/boot/Image.gz" ] && [ -f "out/arch/arm64/boot/Image" ]; then
    echo "Merging Image and compiled DTBs into integrated image..."
    cat out/arch/arm64/boot/Image $(find out/arch/arm64/boot/dts/ -name "*.dtb") > out/arch/arm64/boot/Image-dtb
    echo "Generated integrated Image-dtb binary!"
fi

cp out/arch/arm64/boot/Image-dtb anykernel/
cp out/arch/arm64/boot/dtb anykernel/

cd anykernel 

# Safely purge 'out' directory inside AnyKernel if present to prevent bloated zip size
rm -rf out

ZIP_FILENAME=${KERNEL_ZIP_NAME}_${TARGET_DEVICE}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3.zip

# Clean compression without extra folders
zip -r9 $ZIP_FILENAME ./* -x ".git/*" ".gitignore" "*.zip"

mv $ZIP_FILENAME ../

cd ..

echo "$KERNEL_NAME Build Finished"
echo "Done. The flashable zip is: [./$ZIP_FILENAME]"
