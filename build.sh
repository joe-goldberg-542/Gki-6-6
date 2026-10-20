#!/usr/bin/env bash

WORKDIR="$(pwd)"
RELEASE_DIR="$WORKDIR/artifacts"

KERNEL_NAME="GKID"
USER="ahmed-alnassif"
HOST="GKID"
TIMEZONE="Asia/Damascus"
ANYKERNEL_REPO="https://github.com/ahmed-alnassif/AK3-GKID"

KERNEL_DEFCONFIG="gki_defconfig"
KERNEL_VERSION="${KERNEL_VERSION:-6.1}"

sudo timedatectl set-timezone "$TIMEZONE" || export TZ="$TIMEZONE"
RELEASE="$(date +v%y.%m.%d)${RUN_NUM}"
mkdir -p $RELEASE_DIR

GKI_RELEASES_REPO="https://github.com/ahmed-alnassif/GKID-Kernels"
AK3_ZIP_NAME="$KERNEL_NAME-VARIANT-REL-KVER.zip"
OUTDIR="$WORKDIR/out"
KSRC="$WORKDIR/ksrc"
KERNEL_PATCHES="$WORKDIR/kernel-patches"
PATCHES_DIR="$WORKDIR/patches"

source $WORKDIR/functions.sh

IFS='|' read -r KERNEL_REPO KERNEL_BRANCH KERNEL_KMI <<< "$(resolve_kernel_source "$KERNEL_VERSION")"

ANDROID_RELEASE="$(android_release_for_version "$KERNEL_VERSION")"
echo "KERNEL_VERSION=$KERNEL_VERSION" >> $GITHUB_ENV
echo "ANDROID_RELEASE=$ANDROID_RELEASE" >> $GITHUB_ENV
echo "KERNEL_SOURCE_REPO=$(simplify_gh_url "$KERNEL_REPO")" >> $GITHUB_ENV
echo "KERNEL_SOURCE_BRANCH=$KERNEL_BRANCH" >> $GITHUB_ENV
echo "RELEASE_REPO=$(simplify_gh_url "$GKI_RELEASES_REPO")" >> $GITHUB_ENV
echo "RELEASE_NAME=$KERNEL_NAME $RELEASE" >> $GITHUB_ENV
echo "RELEASE=$RELEASE" >> $GITHUB_ENV

BUILD_LOGS="$RELEASE_DIR/build.log"
exec > >(tee -a "$BUILD_LOGS") 2>&1

log "Cloning kernel source from $(simplify_gh_url "$KERNEL_REPO")"
git clone -q --depth=1 "$KERNEL_REPO" -b "$KERNEL_BRANCH" "$KSRC"

cd $KSRC
LINUX_VERSION=$(make kernelversion)
DEFCONFIG_FILE=$(find ./arch/arm64/configs -name "$KERNEL_DEFCONFIG")
echo "LINUX_VERSION=$LINUX_VERSION" >> $GITHUB_ENV
cd $WORKDIR

log "Setting Kernel variant"
case "$KSU" in
  "BSU") VARIANT="BakaSU" ;;
  "no") VARIANT="Vanilla" ;;
  *) VARIANT="BakaSU" ;;
esac

susfs_included && VARIANT+="+SuSFS"
SUSFS_URL="https://gitlab.com/simonpunk/susfs4ksu"
SUSFS_DIR="$WORKDIR/susfs"
SUSFS_PATCHES="${SUSFS_DIR}/kernel_patches"
SUSFS_BRANCH="$(resolve_susfs_branch "$KERNEL_VERSION")"
SUSFS_PATCH="$SUSFS_BRANCH"

clone_susfs 5

CLANG_BIN="$WORKDIR/neutron-clang/bin"
mkdir -p "$WORKDIR/neutron-clang"
cd "$WORKDIR/neutron-clang"
bash <(curl -s "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman") -S
cd $OLDPWD

export PATH="${CLANG_BIN}:$PATH"
export CC="clang"
export CXX="clang++"

cd $KSRC

if susfs_included && [ "$KSU" = "BSU" ]; then
  log "BakaSU included"
  install_ksu "Baka-SU/BakaSU" "main"
  clone_susfs
  apply_susfs_patches
fi

if [ "$NM" = "true" ]; then
  log "Applying NoMount (dev)"
  curl -LSs "https://raw.githubusercontent.com/maxsteeel/nomount/refs/heads/dev/kernel/setup.sh" | bash -s dev
fi

echo "VARIANT=$VARIANT" >> $GITHUB_ENV
AK3_ZIP_NAME=${AK3_ZIP_NAME//KVER/$LINUX_VERSION}
AK3_ZIP_NAME=${AK3_ZIP_NAME//VARIANT/$VARIANT}

log "Generating config for POCO M6 Pro 5G (Sky)..."
make LLVM=1 LLVM_IAS=1 ARCH=arm64 O="$OUTDIR" "$KERNEL_DEFCONFIG" vendor/parrot_perf.config

MAKE_ARGS=(
  LLVM=1
  LLVM_IAS=1
  ARCH=arm64
  CROSS_COMPILE=aarch64-linux-gnu-
  CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
  -j$(nproc --all)
  O="$OUTDIR"
)

log "Building kernel..."
make ${MAKE_ARGS[@]}

cd $WORKDIR
git clone -q --depth=1 $ANYKERNEL_REPO anykernel

AK3_ZIP_NAME=${AK3_ZIP_NAME//REL/$RELEASE}
cd anykernel
cp "$OUTDIR/arch/arm64/boot/Image" .
zip -r9 "$WORKDIR/$AK3_ZIP_NAME" ./*
cd $OLDPWD

mkdir -p $RELEASE_DIR
mv $WORKDIR/*.zip $RELEASE_DIR
