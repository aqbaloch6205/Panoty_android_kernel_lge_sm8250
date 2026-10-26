#!/bin/bash

# Some logics of this script are copied from [scripts/build_kernel]. Thanks to UtsavBalar1231.

# Ensure the script exits on error
set -e

TOOLCHAIN_PATH=$HOME/toolchain/bin
TARGET_DEVICE=$1

if [ -z "$1" ]; then
    echo "Error: No argument provided, please specific a target device." 
    echo "If you need KernelSU, please add [ksu] as the second arg."
    echo "Examples:"
    echo "Build for timelm without KernelSU:"
    echo "    bash build.sh timelm"
    echo "Build for timelm with KernelSU:"
    echo "    bash build.sh timelm ksu"
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
export KBUILD_BUILD_USER="kiyomi"
export KBUILD_BUILD_HOST="yuki"
export KBUILD_BUILD_TIMESTAMP=$(TZ="Japan" date)

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
           STRIP=llvm-strip"


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


# Check clang is existing.
echo "[clang --version]:"
clang --version



KSU_ZIP_STR=NoKernelSU
if [ "$2" == "ksu" ]; then
    KSU_ENABLE=1
    KSU_ZIP_STR=ReSukiSU-SuSFS
else
    KSU_ENABLE=0
fi


echo "TARGET_DEVICE: $TARGET_DEVICE"

if [ $KSU_ENABLE -eq 1 ]; then
    echo "KSU is enabled"
    curl -LSs "https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh" | bash
    curl https://raw.githubusercontent.com/maxsteeel/nomount/refs/heads/dev/kernel/setup.sh | bash
else
    echo "KSU is disabled"
fi

# Clear Previous Build
rm -rf out/
rm -rf anykernel/

echo "Clone AnyKernel3 for packing kernel (repo: https://github.com/kiy017/AnyKernel3)"
git clone https://github.com/kiy017/AnyKernel3.git -b master --single-branch --depth=1 anykernel

# ------------- Building Kernel -------------

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
    -e TMPFS_POSIX_ACL \
    -e NOMOUNT
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

# Patch Kernel For KPM Support

if [ $KSU_ENABLE -eq 1 ]; then
    cd out/arch/arm64/boot/
    wget https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.13.0/patch_linux
    chmod +x patch_linux
    ./patch_linux
    rm Image
    mv oImage Image
    cd -
    echo " KPM patch successful"
fi

echo "Generating [out/arch/arm64/boot/dtb]......"
find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + >out/arch/arm64/boot/dtb

rm -rf anykernel/kernels/

# Genrate Image-dtb
if [ ! -f "out/arch/arm64/boot/Image.gz" ] && [ -f "out/arch/arm64/boot/Image" ]; then
    echo "Merging Image and compiled DTBs into integrated image..."
    cat out/arch/arm64/boot/Image $(find out/arch/arm64/boot/dts/ -name "*.dtb") > out/arch/arm64/boot/Image-dtb
    echo "Generated integrated Image-dtb binary!"
fi

# NOTE: Modules are NOT packed. Only kernel image + dtb go into the zip.

cp out/arch/arm64/boot/Image-dtb anykernel/
cp out/arch/arm64/boot/dtb anykernel/


cd anykernel 

ZIP_FILENAME=kiyo_${TARGET_DEVICE}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3.zip

zip -r9 $ZIP_FILENAME ./* -x .git .gitignore out/ ./*.zip

mv $ZIP_FILENAME ../

cd ..

echo "Kernel Build Finished"
echo "Done. The flashable zip is: [./$ZIP_FILENAME]"
