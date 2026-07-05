#!/bin/bash

set -e

# Configs
export KERNEL_NAME="Exynoobs"
export DEVICE=a54x
export ARCH=arm64
export TARGET_SOC=s5e8835
export PLATFORM_VERSION="14"
export ANDROID_MAJOR_VERSION=t
export OS_VERSION="13.0.0"
export SPL="$(date +%Y-%m)"
export BOOT_HEADER="4"

CLANG_URL=$(curl -Ls https://raw.githubusercontent.com/ZyCromerZ/Clang/main/Clang-main-link.txt)
export LLVM=1
export LLVM_IAS=1
export CC=clang
export CLANG_TRIPLE=llvm-
export CROSS_COMPILE=aarch64-linux-gnu-
export DEPMOD=depmod

export TZ="Asia/Jakarta"
export KBUILD_BUILD_HOST=builder
export KBUILD_BUILD_USER=bot

OUTDIR="$(pwd)/out"
MODULES_OUTDIR="$(pwd)/modules_out"
TMPDIR="$(pwd)/kernel_build/tmp"

PREBUILT_PLATFORM="$(pwd)/kernel_build/vboot_platform/${DEVICE}/vendor_ramdisk_platform.lz4"
IN_DLKM="$(pwd)/kernel_build/vboot_dlkm/${DEVICE}"
IN_DTB="$OUTDIR/arch/arm64/boot/dts/exynos/${TARGET_SOC}.dtb"

DLKM_RAMDISK_DIR="$TMPDIR/ramdisk_dlkm"
MODULES_DIR="$DLKM_RAMDISK_DIR/lib/modules"

MKBOOTIMG="$(pwd)/kernel_build/tools/mkbootimg.py"
MKDTBOIMG="$(pwd)/kernel_build/tools/mkdtboimg.py"

OUT_KERNELZIP="$(pwd)/kernel_build/Kernel_${DEVICE}.zip"
OUT_KERNELTAR="$(pwd)/kernel_build/Kernel_${DEVICE}.tar"
OUT_KERNEL="$OUTDIR/arch/arm64/boot/Image"
OUT_BOOTIMG="$(pwd)/kernel_build/boot.img"
OUT_VENDORBOOTIMG="$(pwd)/kernel_build/vendor_boot.img"
OUT_DTBIMAGE="$TMPDIR/dtb.img"

# Kernel-side

kfinish() {
    rm -rf "$TMPDIR"
    rm -rf "$OUTDIR"
    rm -rf "$MODULES_OUTDIR"
} 

kfinish

DIR="$(readlink -f .)"
PARENT_DIR="$(readlink -f ${DIR}/..)"

export CC="$PARENT_DIR/toolchain/clang/bin/clang"
export PATH="$PARENT_DIR/toolchain/build-tools/path/linux-x86:$PARENT_DIR/toolchain/kernel-build-tools/linux-x86/bin:$PARENT_DIR/toolchain/clang/bin:$PATH"

if [ ! -d "$PARENT_DIR/toolchain/clang" ]; then
    wget "$CLANG_URL" -O clang.tar.gz &> /dev/null
    mkdir -p "$PARENT_DIR/toolchain/clang"
    tar -xvzf clang.tar.gz -C $PARENT_DIR/toolchain/clang &> /dev/null
    rm -rf clang.tar.gz
fi

if [ ! -d "$PARENT_DIR/toolchain/build-tools" ]; then
    wget https://github.com/aosp-mirror-neo/platform_prebuilts_build-tools/archive/refs/heads/main.tar.gz  &> /dev/null
    mkdir -p "$PARENT_DIR/toolchain/build-tools"
    tar -xvzf main.tar.gz -C $PARENT_DIR/toolchain/build-tools --strip-components=1  &> /dev/null
    rm -rf main.tar.gz
fi

if [ ! -d "$PARENT_DIR/toolchain/kernel-build-tools" ]; then
    wget https://github.com/aosp-mirror-neo/kernel_prebuilts_build-tools/archive/refs/heads/main-kernel-build-2023.tar.gz  &> /dev/null
    mkdir -p "$PARENT_DIR/toolchain/kernel-build-tools"
    tar -xvzf main-kernel-build-2023.tar.gz -C $PARENT_DIR/toolchain/kernel-build-tools --strip-components=1  &> /dev/null
    rm -rf main-kernel-build-2023.tar.gz
fi

# Overclock option
if [ "${1}" == "oc" ]; then
    ./scripts/config --file arch/${ARCH}/configs/${TARGET_SOC}_defconfig \
		-e CONFIG_SOC_S5E8835_CPU_OC \
		-e CONFIG_SOC_S5E8835_GPU_OC
    echo "KERNEL_BUILD: Overclock enabled!"
fi

echo "-${KERNEL_NAME}" > localversion
make -j$(nproc --all) -C $(pwd) O=out ${TARGET_SOC}_defconfig
./scripts/kconfig/merge_config.sh -m -O out out/.config arch/arm64/configs/${DEVICE}.config
make -j$(nproc --all) -C $(pwd) O=out olddefconfig
make -j$(nproc --all) -C $(pwd) O=out dtbs
make -j$(nproc --all) -C $(pwd) O=out
make -j$(nproc --all) -C $(pwd) O=out INSTALL_MOD_STRIP="--strip-debug --keep-section=.ARM.attributes" INSTALL_MOD_PATH="$MODULES_OUTDIR" modules_install

rm -rf "$TMPDIR"
rm -f "$OUT_BOOTIMG"
rm -f "$OUT_VENDORBOOTIMG"
mkdir "$TMPDIR"
mkdir -p "$MODULES_DIR/0.0"

if ! find "$MODULES_OUTDIR/lib/modules" -mindepth 1 -type d | read; then
    echo "Unknown error!"
    exit 1
fi

missing_modules=""

for module in $(cat "$IN_DLKM/modules.load"); do
    i=$(find "$MODULES_OUTDIR/lib/modules" -name $module);
    if [ -f "$i" ]; then
        cp -f "$i" "$MODULES_DIR/0.0/$module"
    else
	missing_modules="$missing_modules $module"
    fi
done

if [ "$missing_modules" != "" ]; then
        echo "ERROR: the following modules were not found: $missing_modules"
	exit 1
fi

depmod 0.0 -b "$DLKM_RAMDISK_DIR"
sed -i 's/\([^ ]\+\)/\/lib\/modules\/\1/g' "$MODULES_DIR/0.0/modules.dep"
cd "$MODULES_DIR/0.0"
for i in $(find . -name "modules.*" -type f); do
    if [ $(basename "$i") != "modules.dep" ] && [ $(basename "$i") != "modules.softdep" ] && [ $(basename "$i") != "modules.alias" ]; then
        rm -f "$i"
    fi
done
cd "$DIR"

cp -f "$IN_DLKM/modules.load" "$MODULES_DIR/0.0/modules.load"
mv "$MODULES_DIR/0.0"/* "$MODULES_DIR/"
rm -rf "$MODULES_DIR/0.0"

echo "Building dtb image..."
python3 "$MKDTBOIMG" create "$OUT_DTBIMAGE" --custom0=0x00000000 --custom1=0x000000ff --version=0 --page_size=2048 "$IN_DTB" || exit 1

echo "Building boot image..."

chmod +x $MKBOOTIMG

$MKBOOTIMG --header_version "$BOOT_HEADER" \
    --kernel "$OUT_KERNEL" \
    --output "$OUT_BOOTIMG" \
    --pagesize 4096 \
    --os_version "$OS_VERSION" \
    --os_patch_level "$SPL" || exit 1

echo "Done!"
echo "Building vendor_boot image..."

mkbootfs $DLKM_RAMDISK_DIR | lz4 -9cl > "$(pwd)/ramdisk_dlkm.lz4"

echo "buildtime_bootconfig=enable " > bootconfig
$MKBOOTIMG --header_version "$BOOT_HEADER" \
    --vendor_boot "$OUT_VENDORBOOTIMG" \
    --vendor_bootconfig "$(pwd)/bootconfig" \
    --vendor_cmdline "bootconfig loop.max_part=7" \
    --dtb "$OUT_DTBIMAGE" \
    --vendor_ramdisk "$PREBUILT_PLATFORM" \
    --ramdisk_type dlkm \
    --ramdisk_name dlkm \
    --vendor_ramdisk_fragment "$(pwd)/ramdisk_dlkm.lz4" \
    --pagesize 4096 \
    --os_version "$OS_VERSION" \
    --os_patch_level "$SPL" || exit 1

cd "$DIR"

echo "Done!"

echo "Building zip..."
rm -f "$OUT_KERNELZIP"
git clone -b "$DEVICE" https://github.com/zainarbani/AnyKernel3 AnyKernel3 --depth=1 &> /dev/null
cd AnyKernel3
cp "$OUT_KERNEL" Image
cp "$OUT_VENDORBOOTIMG" vendor_boot.img
zip -r9 -q "$OUT_KERNELZIP" -- *
cd "$DIR"
echo "Done! Output: $OUT_KERNELZIP"

echo "Building tar..."
cd "$(pwd)/kernel_build"
rm -f "$OUT_KERNELTAR"
lz4 -c -12 -B6 --content-size "$OUT_BOOTIMG" > boot.img.lz4
lz4 -c -12 -B6 --content-size "$OUT_VENDORBOOTIMG" > vendor_boot.img.lz4
tar -cf "$OUT_KERNELTAR" boot.img.lz4 vendor_boot.img.lz4 "$OUTDIR/vmlinux"
cd "$DIR"
rm -f boot.img.lz4 vendor_boot.img.lz4
echo "Done! Output: $OUT_KERNELTAR"
echo "Cleaning..."
rm -f "${OUT_VENDORBOOTIMG}" "${OUT_BOOTIMG}"
kfinish
