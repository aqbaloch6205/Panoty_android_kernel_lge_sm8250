#!/bin/bash

# Ensure the script exits on error
set -e

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
export KBUILD_BUILD_USER="Panoty"
export KBUILD_BUILD_HOST="Abdul-Qadeer"
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

echo "TARGET_DEVICE: $TARGET_DEVICE"

# Dev's original KSU setup logic
if [ $KSU_ENABLE -eq 1 ]; then
    echo "KSU is enabled"
    curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash
else
    echo "KSU is disabled"
fi

# Clear Previous Build
rm -rf out/
rm -rf anykernel/

echo "Clone AnyKernel3 for packing Panoty-kernel"
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

# Dev's exact Module processing logic
if grep -q "CONFIG_MODULES=y" "out/.config"; then
    echo "Compiling and installing modules..."
    MODULES_OUT="$(pwd)/out/modules_out"
    rm -rf "$MODULES_OUT"
    
    make $MAKE_ARGS INSTALL_MOD_PATH="$MODULES_OUT" modules_install

    if [ -d "$MODULES_OUT/lib/modules" ]; then
        echo "Translating kernel build footprints to exact stock firmware signatures..."
        TARGET_KV_DIR=$(find "$MODULES_OUT/lib/modules" -mindepth 1 -maxdepth 1 -type d | head -n 1)
        FLAT_STAGE="$MODULES_OUT/flat_modules"
        mkdir -p "$FLAT_STAGE"

        find "$TARGET_KV_DIR/kernel/techpack/audio" -name "*.ko" 2>/dev/null | while read -r audio_mod; do
            base_name=$(basename "$audio_mod" ".ko")
            if [ "$base_name" = "machine_dlkm" ]; then
                cp "$audio_mod" "$FLAT_STAGE/audio_machine_kona.ko"
            else
                clean_name=$(echo "$base_name" | sed 's/_dlkm//')
                cp "$audio_mod" "$FLAT_STAGE/audio_${clean_name}.ko"
            fi
        done

        if [ -f "$TARGET_KV_DIR/kernel/drivers/staging/qcacld-3.0/wlan.ko" ]; then
            cp "$TARGET_KV_DIR/kernel/drivers/staging/qcacld-3.0/wlan.ko" "$FLAT_STAGE/qca_cld3_qca6390.ko"
        fi

        find "$TARGET_KV_DIR/kernel" -name "*.ko" ! -path "*qcacld-3.0*" ! -path "*techpack/audio*" | while read -r misc_mod; do
            base_name=$(basename "$misc_mod")
            cp "$misc_mod" "$FLAT_STAGE/$base_name"
        done

        rm -rf "$TARGET_KV_DIR/kernel"
        rm -f "$TARGET_KV_DIR"/source "$TARGET_KV_DIR"/build

        mv "$FLAT_STAGE"/* "$TARGET_KV_DIR/"
        rm -rf "$FLAT_STAGE"

        find "$TARGET_KV_DIR" -name "*.ko" -type f -exec chmod 644 {} +

        cat << 'EOF' > "$TARGET_KV_DIR/modules.dep"
/vendor/lib/modules/audio_adsp_loader.ko: /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_stub.ko:
/vendor/lib/modules/audio_tx_macro.ko: /vendor/lib/modules/audio_swr_ctrl.ko /vendor/lib/modules/audio_swr.ko /vendor/lib/modules/audio_wcd_core.ko /vendor/lib/modules/audio_bolero_cdc.ko /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/tcp_westwood.ko:
/vendor/lib/modules/audio_wcd9xxx.ko: /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_q6_notifier.ko: /vendor/lib/modules/audio_q6_pdr.ko
/vendor/lib/modules/audio_wcd_core.ko:
/vendor/lib/modules/audio_wsa883x.ko: /vendor/lib/modules/audio_swr.ko /vendor/lib/modules/audio_wcd_core.ko
/vendor/lib/modules/audio_snd_event.ko:
/vendor/lib/modules/cxd22xx.ko:
/vendor/lib/modules/audio_machine_kona.ko: /vendor/lib/modules/audio_wcd938x.ko /vendor/lib/modules/audio_mbhc.ko /vendor/lib/modules/audio_es9218.ko /vendor/lib/modules/audio_wcd9xxx.ko /vendor/lib/modules/audio_wsa881x.ko /vendor/lib/modules/audio_wsa883x.ko /vendor/lib/modules/audio_swr.ko /vendor/lib/modules/audio_wcd_core.ko /vendor/lib/modules/audio_bolero_cdc.ko /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_rx_macro.ko: /vendor/lib/modules/audio_swr_ctrl.ko /vendor/lib/modules/audio_swr.ko /vendor/lib/modules/audio_wcd_core.ko /vendor/lib/modules/audio_bolero_cdc.ko /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_wcd938x.ko: /vendor/lib/modules/audio_mbhc.ko /vendor/lib/modules/audio_es9218.ko /vendor/lib/modules/audio_wcd9xxx.ko /vendor/lib/modules/audio_swr.ko /vendor/lib/modules/audio_wcd_core.ko /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_swr_ctrl.ko: /vendor/lib/modules/audio_swr.ko /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_tfa9878.ko: /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_va_macro.ko: /vendor/lib/modules/audio_swr_ctrl.ko /vendor/lib/modules/audio_swr.ko /vendor/lib/modules/audio_wcd_core.ko /vendor/lib/modules/audio_bolero_cdc.ko /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_usf.ko: /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/wmc_drv.ko:
/vendor/lib/modules/audio_bolero_cdc.ko: /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/rmnet_perf.ko:
/vendor/lib/modules/audio_wsa_macro.ko: /vendor/lib/modules/audio_swr_ctrl.ko /vendor/lib/modules/audio_swr.ko /vendor/lib/modules/audio_wcd_core.ko /vendor/lib/modules/audio_bolero_cdc.ko /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_wcd938x_slave.ko: /vendor/lib/modules/audio_swr.ko
/vendor/lib/modules/audio_apr.ko: /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/tcp_htcp.ko:
/vendor/lib/modules/audio_native.ko: /vendor/lib/modules/audio_platform.ko /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_platform.ko: /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_q6_pdr.ko:
/vendor/lib/modules/audio_hdmi.ko:
/vendor/lib/modules/audio_q6.ko: /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_swr.ko:
/vendor/lib/modules/qca_cld3_qca6390.ko:
/vendor/lib/modules/audio_es9218.ko:
/vendor/lib/modules/audio_pinctrl_lpi.ko: /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/gspca_main.ko:
/vendor/lib/modules/audio_wsa881x.ko: /vendor/lib/modules/audio_swr.ko /vendor/lib/modules/audio_wcd_core.ko
/vendor/lib/modules/rmnet_shs.ko:
/vendor/lib/modules/audio_mbhc.ko: /vendor/lib/modules/audio_es9218.ko
/vendor/lib/modules/audio_pinctrl_wcd.ko:
EOF

        touch "$TARGET_KV_DIR/modules.alias" "$TARGET_KV_DIR/modules.softdep"
        
        echo "Copying Modules into AnyKernel modules directory..."
        cp -r "$TARGET_KV_DIR"/* anykernel/modules/vendor/lib/modules/
        chmod 644 anykernel/modules/vendor/lib/modules/*
        echo "Modules Copied Successfully"
    fi
fi

cp out/arch/arm64/boot/Image-dtb anykernel/
cp out/arch/arm64/boot/dtb anykernel/

cd anykernel 

ZIP_FILENAME=Panoty_${TARGET_DEVICE}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3.zip

zip -r9 $ZIP_FILENAME ./* -x .git .gitignore out/ ./*.zip

mv $ZIP_FILENAME ../

cd ..

echo "Kernel Build Finished"
echo "Done. The flashable zip is: [./$ZIP_FILENAME]"
