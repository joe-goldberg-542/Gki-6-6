#!/usr/bin/env bash
set -eo pipefail

WORKDIR="$(pwd)"
RELEASE_DIR="$WORKDIR/artifacts"

KERNEL_NAME="sky"
USER=""
HOST="sky"
TIMEZONE="Asia/Damascus"
ANYKERNEL_REPO="https://github.com/ahmed-alnassif/AK3-GKID"

KERNEL_DEFCONFIG="gki_defconfig"

KERNEL_VERSION="${KERNEL_VERSION:-6.6}"

sudo timedatectl set-timezone "$TIMEZONE" || export TZ="$TIMEZONE"

RELEASE="$(date +v%y.%m.%d)${RUN_NUM}"

mkdir -p "$RELEASE_DIR"

GKI_RELEASES_REPO="https://github.com/${GITHUB_REPOSITORY:-joe-goldberg-542/Gki-6-6}"
AK3_ZIP_NAME="$KERNEL_NAME-VARIANT-REL-KVER.zip"
OUTDIR="$WORKDIR/out"
KSRC="$WORKDIR/ksrc"
KERNEL_PATCHES="$WORKDIR/kernel-patches"
PATCHES_DIR="$WORKDIR/patches"

source "$WORKDIR/functions.sh"

IFS='|' read -r KERNEL_REPO KERNEL_BRANCH KERNEL_KMI <<< "$(resolve_kernel_source "$KERNEL_VERSION")"

ANDROID_RELEASE="$(android_release_for_version "$KERNEL_VERSION")"
echo "KERNEL_VERSION=$KERNEL_VERSION" >> "$GITHUB_ENV"
echo "ANDROID_RELEASE=$ANDROID_RELEASE" >> "$GITHUB_ENV"
echo "KERNEL_SOURCE_REPO=$(simplify_gh_url "$KERNEL_REPO")" >> "$GITHUB_ENV"
echo "KERNEL_SOURCE_BRANCH=$KERNEL_BRANCH" >> "$GITHUB_ENV"

echo "RELEASE_REPO=$(simplify_gh_url "$GKI_RELEASES_REPO")" >> "$GITHUB_ENV"
echo "KERNEL_NAME=${KERNEL_NAME}${RUN_NUM}" >> "$GITHUB_ENV"
echo "RELEASE_NAME=$KERNEL_NAME $RELEASE" >> "$GITHUB_ENV"
echo "RELEASE=$RELEASE" >> "$GITHUB_ENV"

BUILD_LOGS="$RELEASE_DIR/build.log"
exec > >(tee -a "$BUILD_LOGS") 2>&1

trap 'echo "SCRIPT EXIT at $(date)" >> "$BUILD_LOGS"' EXIT
trap 'echo "[-] ERROR at line $LINENO: [[$BASH_COMMAND]]" >> "$BUILD_LOGS"' ERR
trap 'echo "[-] Received SIGTERM at $(date) - possible GitHub kill" >> "$BUILD_LOGS"' TERM
trap 'echo "[-] Received SIGINT at $(date)" >> "$BUILD_LOGS"' INT

log "Cloning kernel source from $(simplify_gh_url "$KERNEL_REPO")"
git clone -q --depth=1 "$KERNEL_REPO" -b "$KERNEL_BRANCH" "$KSRC"

cd "$KSRC"
LINUX_VERSION=$(make kernelversion)
LINUX_VERSION_CODE=${LINUX_VERSION//./}
DEFCONFIG_FILE=$(find ./arch/arm64/configs -name "$KERNEL_DEFCONFIG")
echo "LINUX_VERSION=$LINUX_VERSION" >> "$GITHUB_ENV"
cd "$WORKDIR"

log "Setting Kernel variant"
case "$KSU" in
  "SKSU") VARIANT="SukiSU-Ultra" ;;
  "BSU") VARIANT="BakaSU" ;;
  "KSU") VARIANT="KernelSU" ;;
  "no") VARIANT="Vanilla" ;;
  "vnlto") VARIANT="Vanilla+NoLTO" ;;
  *) VARIANT="Vanilla" ;;
esac

susfs_included && VARIANT+="+SuSFS"
SUSFS_URL="https://gitlab.com/simonpunk/susfs4ksu"
SUSFS_DIR="$WORKDIR/susfs"
SUSFS_PATCHES="${SUSFS_DIR}/kernel_patches"

SUSFS_BRANCH="$(resolve_susfs_branch "$KERNEL_VERSION")"
SUSFS_PATCH="$SUSFS_BRANCH"

log "Changelog of repos"
clone_susfs 5
cd "$SUSFS_DIR"
git log --pretty=format:"- [%h](https://${SUSFS_URL#https://}/commit/%H) %s" -5 "$SUSFS_BRANCH" \
  > "$RELEASE_DIR/susfs_changelog-${KERNEL_VERSION}.txt"
cd "$WORKDIR"

if kernel_version_eq "$KERNEL_VERSION" "6.6"; then
  generate_gh_changelog "xiaomi-ravelin/android_kernel_xiaomi_sm4450" "$KERNEL_BRANCH" 10 "$RELEASE_DIR/android_kernel-6.6_changelog.txt"
else
  echo "No changelog generator wired up yet for $KERNEL_VERSION" \
    > "$RELEASE_DIR/android_kernel-${KERNEL_VERSION}_changelog.txt"
fi

generate_gh_changelog "maxsteeel/nomount" "dev" 5 "$RELEASE_DIR/nomount_changelog.txt"
generate_gh_changelog "tiann/KernelSU" "main" 5 "$RELEASE_DIR/ksu_changelog.txt"
generate_gh_changelog "Baka-SU/BakaSU" "sync-susfs" 5 "$RELEASE_DIR/BakaSU_changelog.txt"

echo "::group::[*] Downloading Clang"
CLANG_BIN="$WORKDIR/neutron-clang/bin"
mkdir -p "$WORKDIR/neutron-clang"
cd "$WORKDIR/neutron-clang"
bash <(curl -s "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman") -S
cd "$WORKDIR"
if [ ! -d "$CLANG_BIN" ]; then
  error "Clang not found in ${CLANG_BIN}."
  exit 1
fi

export PATH="${CLANG_BIN}:$PATH"
echo "::endgroup::"

export CCACHE_DIR="$HOME/.ccache"
export CCACHE_BASEDIR="$WORKDIR"
export CCACHE_NOHARDLINK=true
export CCACHE_COMPILERCHECK=content
export CC="ccache clang"
export CXX="ccache clang++"

ccache --zero-stats
ccache --max-size=5G
ccache --set-config=sloppiness="pch_defines,time_macros,file_macro,include_file_mtime,include_file_ctime"
ccache --set-config=hash_dir=false
ccache --set-config=base_dir="$WORKDIR"
ccache --set-config=compiler_check=content

if [ "${CLEAN_BUILD:-false}" = "true" ]; then
  log "Force Scratch Build! Clearing old ccache completely..."
  ccache --clear
fi

COMPILER_STRING=$(clang -v 2>&1 | head -n 1 | sed 's/(https..*//' | sed 's/ version//')
echo "COMPILER_STRING=$COMPILER_STRING" >> "$GITHUB_ENV"

cd "$KSRC"

echo "::group::[+] pahole installation"
build_and_install_pahole
echo "::endgroup::"

echo "::group::[+] Applied patches"

export DROIDSPACES="false"
export NH="false"

apply_force_load_module_patch
cleanup_abi_gki_protected_exports

if [ -f "tools/lib/bpf/libbpf.c" ]; then
  sed -i 's/next_path = strchr(s, '\'':'\'');/next_path = (char *)strchr(s, '\'':'\'');/g' tools/lib/bpf/libbpf.c
  success "Patched tools/lib/bpf/libbpf.c for glibc 2.43 C23 strchr compatibility"
fi

if [ -d "kernel/sched/walt" ]; then
  log "Patching WALT governor (Retaining App Launch Boost)"
  sed -i 's/queue_work(input_boost_wq, &input_boost_work);/\/\* killed schedutil-style \*\//g' kernel/sched/walt/input-boost.c
  sed -i 's/if (wg_policy->tunables->pl)/if (0)/g' kernel/sched/walt/cpufreq_walt.c
  sed -i 's/#define DEFAULT_HISPEED_LOAD 90/#define DEFAULT_HISPEED_LOAD 105/g' kernel/sched/walt/cpufreq_walt.c
  sed -i 's/if (wrq->ed_task)/if (0)/g' kernel/sched/walt/walt.c
  sed -i 's/if (should_apply_suh_freq_boost(cluster))/if (0)/g' kernel/sched/walt/walt.c
  sed -i 's/if (wrq->lrb_pipeline_start_time)/if (0)/g' kernel/sched/walt/walt.c
  sed -i 's/wtg->sched_boost_enable\[BALANCE_BOOST\] = true/wtg->sched_boost_enable\[BALANCE_BOOST\] = false/g' kernel/sched/walt/boost.c
  sed -i 's/#define DEFAULT_SILVER_RTG_BOOST_FREQ 1000000/#define DEFAULT_SILVER_RTG_BOOST_FREQ 0/g' kernel/sched/walt/cpufreq_walt.c
  sed -i 's/#define DEFAULT_GOLD_RTG_BOOST_FREQ 768000/#define DEFAULT_GOLD_RTG_BOOST_FREQ 0/g' kernel/sched/walt/cpufreq_walt.c
fi

if [ "$KSU" = "BSU" ]; then
  log "BakaSU included (Merge Multiple Branches)"
  
  curl -LSs "https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh" | bash -s main
  
  cd KernelSU
  git config user.email "joe_goldberg_542@protonmail.com"
  git config user.name "joe-goldberg-542"
  
  git fetch origin --prune
  git checkout main
  
  BRANCHES=(
    "sync-susfs"
    "sync-upstream"
    "renovate/maven-group-in-manager"
    "renovate/gradle-9.x"
  )
  
  for branch in "${BRANCHES[@]}"; do
    echo "=========================================="
    log "Merging origin/$branch into main..."
    ACTUAL_BRANCH=$(git branch -r | grep -i "origin/$branch$" | sed 's/origin\///' | tr -d ' ' | head -n 1)
    
    if [ -n "$ACTUAL_BRANCH" ]; then
      if git merge --no-edit "origin/$ACTUAL_BRANCH"; then
        success "Successfully merged $ACTUAL_BRANCH"
      elif git merge --no-edit -X theirs "origin/$ACTUAL_BRANCH"; then
        warning "Merged $ACTUAL_BRANCH using auto-conflict resolution (-X theirs)"
      else
        error "Conflict in $ACTUAL_BRANCH could not be auto-resolved, skipping..."
        git merge --abort || true
      fi
    else
      warning "Branch $branch not found on remote!"
    fi
  done
  
  cd ..
  
  log "Injecting KSU SUSFS Configuration to gki_defconfig"
  cat << 'EOF' >> arch/arm64/configs/gki_defconfig
CONFIG_KSU=y
CONFIG_KSU_SENTINEL=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=n
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_INLINE_HOOK=y
CONFIG_KSU_SUSFS_SUS_MEMFD=y
CONFIG_KSU_SUSFS_SUS_PROC_FD_LINK=y
EOF
  
  if susfs_included; then
    clone_susfs
    apply_susfs_patches
  fi
fi

if [ "$KSU" = "KSU" ]; then
  log "KernelSU included"
  if ! susfs_included; then
    install_ksu "tiann/KernelSU" "main"
  fi

  if susfs_included; then
    VARIANT+="+Multiple-Managers"
    git clone "https://github.com/tiann/KernelSU" && echo "[+] Repository cloned."
    clone_susfs

    cd KernelSU
    git reset --soft HEAD~1
    apply_patch_file "$PATCHES_DIR/0001-feat-avc-log-spoofing.patch"
    apply_patch_file "$SUSFS_PATCHES/KernelSU/10_enable_susfs_for_ksu.patch"
    apply_patch_file "$PATCHES_DIR/0001-feat-escape-persistent_allow_list-to-kthread.patch"
    apply_patch_file "$PATCHES_DIR/0001-feat-supercalls-allow-userspace-to-pull-list-entries.patch"
    sed -i "/    git pull && echo \"\[+\] Repository updated.\"/d" "kernel/setup.sh"
    git config --global user.email "mr.ahmed.nassif@gmail.com"
    git config --global user.name "Ahmed Al-Nassif"
    git add .
    git commit -m "susfs patch"
    cd ..
    bash "KernelSU/kernel/setup.sh" "main"

    apply_susfs_patches
  fi
fi

if [ "$KSU" != "no" ] && [ "$KSU" != "vnlto" ] && [ -d "drivers/kernelsu" ]; then
  log "Injecting KSU & SELinux Bridge Symbols"
  cat << 'EOF' > drivers/kernelsu/compat_bridge.c
#include <linux/types.h>
#include <linux/fs.h>
#include <linux/file.h>
#include <linux/sched.h>
#include <linux/uaccess.h>
#include <linux/slab.h>

bool ksu_setup_preinit_file(struct file *file)
{
    return false;
}

void ksu_preinit_handle_post_execveat(int fd, struct filename *filename, void *argv, void *envp, int flags)
{
}

int my_setprocattr(const char *name, void *value, size_t size)
{
    return 1;
}

ssize_t my_write_context(struct file *file, const char __user *buf, size_t size, loff_t *ppos)
{
    return 0;
}

ssize_t my_write_access(struct file *file, const char __user *buf, size_t size, loff_t *ppos)
{
    return 0;
}
EOF

  if [ -f "drivers/kernelsu/Kbuild" ]; then
    echo "obj-y += compat_bridge.o" >> drivers/kernelsu/Kbuild
  elif [ -f "drivers/kernelsu/Makefile" ]; then
    echo "obj-y += compat_bridge.o" >> drivers/kernelsu/Makefile
  fi
  
  log "Committing compat_bridge changes to clear KSU dirty version"
  cd drivers/kernelsu
  git config user.email "build@dummy.com" || true
  git config user.name "Dummy Builder" || true
  git add compat_bridge.c Kbuild Makefile 2>/dev/null || true
  git commit -m "inject: KSU & SELinux Bridge Symbols" || true
  cd ../../
fi

if [ "$NM" = "true" ]; then
  log "Applying NoMount (dev)"
  curl -LSs "https://raw.githubusercontent.com/maxsteeel/nomount/refs/heads/dev/kernel/setup.sh" | bash -s dev
  VARIANT+="+NoMount"
fi

echo "VARIANT=$VARIANT" >> "$GITHUB_ENV"
echo "::endgroup::"
set +eo pipefail

AK3_ZIP_NAME=${AK3_ZIP_NAME//KVER/$LINUX_VERSION}
AK3_ZIP_NAME=${AK3_ZIP_NAME//VARIANT/$VARIANT}

log "Applying configs..."
source "$WORKDIR/configs/gki_defconfig.sh"

if [ "$NM" = "true" ]; then
  config --enable CONFIG_NOMOUNT
fi

if [ "${TODO:-kernel}" = "kernel" ]; then
  LATEST_COMMIT_HASH=$(git rev-parse --short HEAD)
  config --set-str CONFIG_LOCALVERSION "-android15-11-g${LATEST_COMMIT_HASH}"
  config --disable CONFIG_LOCALVERSION_AUTO
  sed -i 's/echo "+"/# echo "+"/g' scripts/setlocalversion
fi

export KBUILD_BUILD_USER="$USER"
export KBUILD_BUILD_HOST="$HOST"
export KBUILD_BUILD_TIMESTAMP=$(git -C "$KSRC" log -1 --format=%cd --date=format-local:'%a %b %d %T %z %Y')
export KCFLAGS="-w"
export HOSTCFLAGS="-Wno-error -Wno-incompatible-pointer-types-discards-qualifiers"

LINK_CACHE_PATH="/dev/shm/thinlto-cache"
LINKER_SHIM="$WORKDIR/clang-lto-linker"
MAKE_ARGS=(
  LLVM=1
  LLVM_IAS=1
  ARCH=arm64
  CROSS_COMPILE=aarch64-linux-gnu-
  CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
  HOSTCFLAGS="-Wno-error -Wno-incompatible-pointer-types-discards-qualifiers"
  EXTRA_CFLAGS="-Wno-error -Wno-incompatible-pointer-types-discards-qualifiers"
  -j"$(nproc --all)"
  O="$OUTDIR"
)

if [ "${LTO:-full}" = "thin" ] && [ "$CLEAN_LTO_CACHE" = "true" ]; then
  rm -rf "$LINK_CACHE_PATH"
  success "ThinLTO cache removed"
fi

if [ "${LTO:-full}" = "thin" ]; then
  log "ThinLTO cache enabled"
  mkdir -p "$LINK_CACHE_PATH"
  cat > "$LINKER_SHIM" << SHIM
#!/usr/bin/env bash
JOBCOUNT=\$(( \$(nproc --all) / 2 ))
exec ld.lld "\$@" --thinlto-cache-dir="$LINK_CACHE_PATH" --thinlto-jobs=\$JOBCOUNT
SHIM
  chmod +x "$LINKER_SHIM"
  MAKE_ARGS+=(LD="$LINKER_SHIM" HOSTLD="$LINKER_SHIM")
fi

KERNEL_IMAGE="$OUTDIR/arch/arm64/boot/Image"
MODULE_SYMVERS="$OUTDIR/Module.symvers"
KMI_CHECK="$WORKDIR/py/kmi-check-6.x.py"

echo "::group::[*] Generating config"
if kernel_version_eq "$KERNEL_VERSION" "6.6" && [ -f "arch/arm64/configs/vendor/parrot_perf.config" ]; then
  log "Merging gki_defconfig + vendor/parrot_perf.config for POCO M6 Pro 5G (Sky)"
  make "${MAKE_ARGS[@]}" "$KERNEL_DEFCONFIG" vendor/parrot_perf.config
else
  make "${MAKE_ARGS[@]}" "$KERNEL_DEFCONFIG"
fi

# =======================
# LTO ENABLER OVERRIDE FIX
# =======================
log "Injecting LTO Method: ${LTO:-full}"
if [ "${LTO:-full}" = "full" ]; then
  ./scripts/config --file "$OUTDIR/.config" -d LTO_CLANG_THIN -e LTO_CLANG_FULL
  MAKE_ARGS+=(LTO=full)
elif [ "${LTO:-full}" = "thin" ]; then
  ./scripts/config --file "$OUTDIR/.config" -e LTO_CLANG_THIN -d LTO_CLANG_FULL
  MAKE_ARGS+=(LTO=thin)
elif [ "${LTO:-full}" = "none" ]; then
  ./scripts/config --file "$OUTDIR/.config" -d LTO_CLANG_THIN -d LTO_CLANG_FULL -e LTO_NONE
  MAKE_ARGS+=(LTO=none)
fi
make "${MAKE_ARGS[@]}" olddefconfig > /dev/null
echo "::endgroup::"

if susfs_included; then
  log "DEBUG: Checking defconfig for SUSFS"
  grep -i susfs ./arch/arm64/configs/gki_defconfig || error "SUSFS NOT FOUND in defconfig!"
  echo ""

  log "DEBUG: Checking .config for SUSFS"
  grep CONFIG_KSU_SUSFS "$OUTDIR/.config" || error "SUSFS NOT ENABLED in .config!"
  grep CONFIG_KSU_SUSFS_SUS_MAP "$OUTDIR/.config" || error "SUSFS_SUS_MAP not enabled!"
  echo ""

  if grep -q "CONFIG_KSU_SUSFS" ./arch/arm64/configs/gki_defconfig && ! grep -q "CONFIG_KSU_SUSFS=y" "$OUTDIR/.config"; then
    warning "SUSFS in defconfig but not in .config - checking dependencies..."
    grep "depends on" $(find . -name "Kconfig" -exec grep -l "KSU_SUSFS" {} \;) 2>/dev/null || error "No dependency info found"
  fi
fi

if [ "$TEST" = "yes" ]; then
  success "Pipeline test done"
  mkdir -p "$RELEASE_DIR"
  echo "test-${VARIANT}" > "$RELEASE_DIR/test-${VARIANT}.zip"
  exit 0
fi

if [[ $TODO == "defconfig" ]]; then
  log "Copying defconfig"
  mkdir -p "$RELEASE_DIR"
  cp "$OUTDIR/.config" "$RELEASE_DIR/config-${VARIANT}.txt"
  exit 0
fi

echo "::group::[*] Swap & Memory Optimization for LTO"

info "Initial storage: $(df -h / | awk 'NR==2 {print $4}') available"
info "Initial memory:  $(free -h | awk '/^Mem:/ {print $7}') available"

if [ -f /swapfile ]; then
  sudo swapoff /swapfile 2>/dev/null || true
  sudo rm -f /swapfile
fi
if [ -f /mnt/swapfile ]; then
  sudo swapoff /mnt/swapfile 2>/dev/null || true
  sudo rm -f /mnt/swapfile
fi

warning "Creating 15GB swap for Heavy Link-Time Optimization (Full LTO)"
sudo fallocate -l 15G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=15360 status=none
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
success "15GB swap created and activated"

sudo sysctl -w vm.swappiness=90
sudo sysctl -w vm.vfs_cache_pressure=200
sudo sysctl -w vm.dirty_ratio=5
sudo sysctl -w vm.dirty_background_ratio=2
sudo sysctl -w vm.drop_caches=3
sudo sysctl -w vm.overcommit_memory=1

success "Final storage: $(df -h / | awk 'NR==2 {print $4}') available"
success "Final memory:  $(free -h | awk '/^Mem:/ {print $7}') available | Swap: $(free -h | awk '/^Swap:/ {print $2}')"
echo "::endgroup::"

set -eo pipefail
echo "::group::[*] Building kernel"
make "${MAKE_ARGS[@]}" CC="ccache clang" CXX="ccache clang++"
echo "::endgroup::"

cd "$WORKDIR"

log "Cloning anykernel from $(simplify_gh_url "$ANYKERNEL_REPO")"
git clone -q --depth=1 "$ANYKERNEL_REPO" anykernel

AK3_ZIP_NAME=${AK3_ZIP_NAME//REL/$RELEASE}
sed -i \
  -e "s/kernel.string=.*/kernel.string=${KERNEL_NAME} ${RELEASE} ${LINUX_VERSION} ${VARIANT} by Ahmed Al-Nassif (ahmed-alnassif)/g" \
  -e "s/supported_kernel=\".*\"/supported_kernel=\"${KERNEL_VERSION}\"/g" \
  "$WORKDIR/anykernel/anykernel.sh"

cd anykernel
log "Zipping anykernel"
if [ ! -f "$KERNEL_IMAGE" ]; then
  error "$KERNEL_IMAGE not found."
  exit 1
fi
cp "$KERNEL_IMAGE" .
zip -r9 "$WORKDIR/$AK3_ZIP_NAME" ./*
cd "$WORKDIR"

echo "BASE_NAME=$KERNEL_NAME-$VARIANT" >> "$GITHUB_ENV"
mkdir -p "$RELEASE_DIR"
mv "$WORKDIR"/*.zip "$RELEASE_DIR"
