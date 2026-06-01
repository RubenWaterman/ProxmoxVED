#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: MickLesk (CanbiZ)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

COMMUNITY_SCRIPTS_URL="${COMMUNITY_SCRIPTS_URL:-https://git.community-scripts.org/community-scripts/ProxmoxVED/raw/branch/main}"
source /dev/stdin <<<$(curl -fsSL "$COMMUNITY_SCRIPTS_URL/misc/api.func")
source <(curl -fsSL "$COMMUNITY_SCRIPTS_URL/misc/vm-core.func")
load_functions

APP="RaspiBlitz VM"
header_info
echo -e "\n Loading..."
GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
RANDOM_UUID="$(cat /proc/sys/kernel/random/uuid)"
METHOD=""
NSAPP="raspiblitz-vm"
var_os="raspiblitz"
var_version="2026-03-29-d52be1a"

YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
HA=$(echo "\033[1;34m")
RD=$(echo "\033[01;31m")
BGN=$(echo "\033[4;92m")
GN=$(echo "\033[1;92m")
DGN=$(echo "\033[32m")
CL=$(echo "\033[m")

CL=$(echo "\033[m")
BOLD=$(echo "\033[1m")
BFR="\\r\\033[K"
HOLD=" "
TAB="  "

CM="${TAB}✔️${TAB}${CL}"
CROSS="${TAB}✖️${TAB}${CL}"
INFO="${TAB}💡${TAB}${CL}"
OS="${TAB}🖥️${TAB}${CL}"
CONTAINERTYPE="${TAB}📦${TAB}${CL}"
DISKSIZE="${TAB}💾${TAB}${CL}"
CPUCORE="${TAB}🧠${TAB}${CL}"
RAMSIZE="${TAB}🛠️${TAB}${CL}"
CONTAINERID="${TAB}🆔${TAB}${CL}"
HOSTNAME="${TAB}🏠${TAB}${CL}"
BRIDGE="${TAB}🌉${TAB}${CL}"
GATEWAY="${TAB}🌐${TAB}${CL}"
DEFAULT="${TAB}⚙️${TAB}${CL}"
MACADDRESS="${TAB}🔗${TAB}${CL}"
VLANTAG="${TAB}🏷️${TAB}${CL}"
CREATING="${TAB}🚀${TAB}${CL}"
ADVANCED="${TAB}🧩${TAB}${CL}"
THIN="discard=on,ssd=1,"
set -e
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
trap 'post_update_to_api "failed" "INTERRUPTED"' SIGINT
trap 'post_update_to_api "failed" "TERMINATED"' SIGTERM
function error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  post_update_to_api "failed" "${command}"
  local error_message="${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}"
  echo -e "\n$error_message\n"
  cleanup_vmid
}

function get_valid_nextid() {
  local try_id
  try_id=$(pvesh get /cluster/nextid)
  while true; do
    if [ -f "/etc/pve/qemu-server/${try_id}.conf" ] || [ -f "/etc/pve/lxc/${try_id}.conf" ]; then
      try_id=$((try_id + 1))
      continue
    fi
    if lvs --noheadings -o lv_name | grep -qE "(^|[-_])${try_id}($|[-_])"; then
      try_id=$((try_id + 1))
      continue
    fi
    break
  done
  echo "$try_id"
}

function cleanup_vmid() {
  if qm status $VMID &>/dev/null; then
    qm stop $VMID &>/dev/null
    qm destroy $VMID &>/dev/null
  fi
}

function cleanup() {
  popd >/dev/null
  post_update_to_api "done" "none"
  rm -rf $TEMP_DIR
}

# Decompressing the ~26 GiB raw image needs real disk space, so default the
# working dir to /var/tmp (root filesystem) instead of /tmp, which is a small
# RAM-backed tmpfs on many Proxmox hosts. Override with TMPDIR if desired.
TEMP_DIR=$(mktemp -d -p "${TMPDIR:-/var/tmp}")
pushd $TEMP_DIR >/dev/null
if whiptail --backtitle "Proxmox VE Helper Scripts" --title "RaspiBlitz VM" --yesno "This will create a New RaspiBlitz VM. Proceed?" 10 58; then
  :
else
  header_info && echo -e "${CROSS}${RD}User exited script${CL}\n" && exit
fi

function msg_info() {
  local msg="$1"
  echo -ne "${TAB}${YW}${HOLD}${msg}${HOLD}"
}

function msg_ok() {
  local msg="$1"
  echo -e "${BFR}${CM}${GN}${msg}${CL}"
}

function msg_error() {
  local msg="$1"
  echo -e "${BFR}${CROSS}${RD}${msg}${CL}"
}

function check_storage_space() {
  # Verify the unpack/working filesystem has room for the compressed download,
  # the decompressed raw image and a safety buffer BEFORE pulling ~4 GB.
  local required_gb="$1"
  local target="${2:-${TEMP_DIR:-/var/tmp}}"
  msg_info "Checking for at least ${required_gb} GB free where the image unpacks"
  local avail_gb mount
  avail_gb=$(df -Pk "$target" 2>/dev/null | awk 'NR==2 {printf "%d", $4 / 1024 / 1024}')
  mount=$(df -Pk "$target" 2>/dev/null | awk 'NR==2 {print $6}')
  if [ -z "$avail_gb" ]; then
    msg_error "Could not determine free space for ${target}."
    exit 1
  fi
  if [ "$avail_gb" -lt "$required_gb" ]; then
    msg_error "Not enough free space on ${mount}: need ~${required_gb} GB, only ${avail_gb} GB free. Free up space (or set TMPDIR to a larger filesystem) and re-run."
    exit 1
  fi
  msg_ok "Free space OK on ${mount}: ${avail_gb} GB available"
}

function check_root() {
  if [[ "$(id -u)" -ne 0 || $(ps -o comm= -p $PPID) == "sudo" ]]; then
    clear
    msg_error "Please run this script as root."
    echo -e "\nExiting..."
    sleep 2
    exit
  fi
}

function pve_check() {
  if ! pveversion | grep -Eq "pve-manager/(8\.[1-4]|9\.[0-2])(\.[0-9]+)*"; then
    msg_error "${CROSS}${RD}This version of Proxmox Virtual Environment is not supported"
    echo -e "Requires Proxmox Virtual Environment Version 8.1 - 8.4 or 9.0 - 9.2."
    echo -e "Exiting..."
    sleep 2
    exit
  fi
}

function arch_check() {
  if [ "$(dpkg --print-architecture)" != "amd64" ]; then
    echo -e "\n ${INFO}${YWB}This script will not work with PiMox! \n"
    echo -e "\n ${YWB}Visit https://github.com/asylumexp/Proxmox for ARM64 support. \n"
    echo -e "Exiting..."
    sleep 2
    exit
  fi
}

function ssh_check() {
  if command -v pveversion >/dev/null 2>&1; then
    if [ -n "${SSH_CLIENT:+x}" ]; then
      if whiptail --backtitle "Proxmox VE Helper Scripts" --defaultno --title "SSH DETECTED" --yesno "It's suggested to use the Proxmox shell instead of SSH, since SSH can create issues while gathering variables. Would you like to proceed with using SSH?" 10 62; then
        echo "you've been warned"
      else
        clear
        exit
      fi
    fi
  fi
}

function exit_script() {
  clear
  echo -e "\n${CROSS}${RD}User exited script${CL}\n"
  exit
}

function default_settings() {
  VMID=$(get_valid_nextid)
  FORMAT=",efitype=4m"
  MACHINE=""
  DISK_CACHE=""
  DISK_SIZE="32G"
  DATA_DISK_SIZE="1024G"
  HN="raspiblitz"
  CPU_TYPE=""
  CORE_COUNT="4"
  RAM_SIZE="8192"
  BRG="vmbr0"
  MAC="$GEN_MAC"
  VLAN=""
  MTU=""
  START_VM="yes"
  METHOD="default"
  echo -e "${CONTAINERID}${BOLD}${DGN}Virtual Machine ID: ${BGN}${VMID}${CL}"
  echo -e "${CONTAINERTYPE}${BOLD}${DGN}Machine Type: ${BGN}i440fx${CL}"
  echo -e "${DISKSIZE}${BOLD}${DGN}OS Disk Size: ${BGN}${DISK_SIZE}${CL}"
  echo -e "${DISKSIZE}${BOLD}${DGN}Data Disk Size (/mnt/hdd): ${BGN}${DATA_DISK_SIZE}${CL}"
  echo -e "${DISKSIZE}${BOLD}${DGN}Disk Cache: ${BGN}None${CL}"
  echo -e "${HOSTNAME}${BOLD}${DGN}Hostname: ${BGN}${HN}${CL}"
  echo -e "${OS}${BOLD}${DGN}CPU Model: ${BGN}KVM64${CL}"
  echo -e "${CPUCORE}${BOLD}${DGN}CPU Cores: ${BGN}${CORE_COUNT}${CL}"
  echo -e "${RAMSIZE}${BOLD}${DGN}RAM Size: ${BGN}${RAM_SIZE}${CL}"
  echo -e "${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}${BRG}${CL}"
  echo -e "${MACADDRESS}${BOLD}${DGN}MAC Address: ${BGN}${MAC}${CL}"
  echo -e "${VLANTAG}${BOLD}${DGN}VLAN: ${BGN}Default${CL}"
  echo -e "${DEFAULT}${BOLD}${DGN}Interface MTU Size: ${BGN}Default${CL}"
  echo -e "${GATEWAY}${BOLD}${DGN}Start VM when completed: ${BGN}yes${CL}"
  echo -e "${CREATING}${BOLD}${DGN}Creating a RaspiBlitz VM using the above default settings${CL}"
}

function advanced_settings() {
  METHOD="advanced"
  [ -z "${VMID:-}" ] && VMID=$(get_valid_nextid)
  while true; do
    if VMID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Virtual Machine ID" 8 58 $VMID --title "VIRTUAL MACHINE ID" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      if [ -z "$VMID" ]; then
        VMID=$(get_valid_nextid)
      fi
      if pct status "$VMID" &>/dev/null || qm status "$VMID" &>/dev/null; then
        echo -e "${CROSS}${RD} ID $VMID is already in use${CL}"
        sleep 2
        continue
      fi
      echo -e "${CONTAINERID}${BOLD}${DGN}Virtual Machine ID: ${BGN}$VMID${CL}"
      break
    else
      exit-script
    fi
  done

  if MACH=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "MACHINE TYPE" --radiolist --cancel-button Exit-Script "Choose Type" 10 58 2 \
    "i440fx" "Machine i440fx" ON \
    "q35" "Machine q35" OFF \
    3>&1 1>&2 2>&3); then
    if [ $MACH = q35 ]; then
      echo -e "${CONTAINERTYPE}${BOLD}${DGN}Machine Type: ${BGN}$MACH${CL}"
      FORMAT=""
      MACHINE=" -machine q35"
    else
      echo -e "${CONTAINERTYPE}${BOLD}${DGN}Machine Type: ${BGN}$MACH${CL}"
      FORMAT=",efitype=4m"
      MACHINE=""
    fi
  else
    exit_script
  fi

  if DISK_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Disk Size in GiB (e.g., 10, 20)" 8 58 "$DISK_SIZE" --title "DISK SIZE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    DISK_SIZE=$(echo "$DISK_SIZE" | tr -d ' ')
    if [[ "$DISK_SIZE" =~ ^[0-9]+$ ]]; then
      DISK_SIZE="${DISK_SIZE}G"
      echo -e "${DISKSIZE}${BOLD}${DGN}Disk Size: ${BGN}$DISK_SIZE${CL}"
    elif [[ "$DISK_SIZE" =~ ^[0-9]+G$ ]]; then
      echo -e "${DISKSIZE}${BOLD}${DGN}Disk Size: ${BGN}$DISK_SIZE${CL}"
    else
      echo -e "${DISKSIZE}${BOLD}${RD}Invalid Disk Size. Please use a number (e.g., 10 or 10G).${CL}"
      exit_script
    fi
  else
    exit_script
  fi

  if DISK_CACHE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "DISK CACHE" --radiolist "Choose" --cancel-button Exit-Script 10 58 2 \
    "0" "None (Default)" ON \
    "1" "Write Through" OFF \
    3>&1 1>&2 2>&3); then
    if [ $DISK_CACHE = "1" ]; then
      echo -e "${DISKSIZE}${BOLD}${DGN}Disk Cache: ${BGN}Write Through${CL}"
      DISK_CACHE="cache=writethrough,"
    else
      echo -e "${DISKSIZE}${BOLD}${DGN}Disk Cache: ${BGN}None${CL}"
      DISK_CACHE=""
    fi
  else
    exit_script
  fi

  if VM_NAME=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Hostname" 8 58 raspiblitz --title "HOSTNAME" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $VM_NAME ]; then
      HN="raspiblitz"
      echo -e "${HOSTNAME}${BOLD}${DGN}Hostname: ${BGN}$HN${CL}"
    else
      HN=$(echo ${VM_NAME,,} | tr -d ' ')
      echo -e "${HOSTNAME}${BOLD}${DGN}Hostname: ${BGN}$HN${CL}"
    fi
  else
    exit_script
  fi

  if CPU_TYPE1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "CPU MODEL" --radiolist "Choose" --cancel-button Exit-Script 10 58 2 \
    "0" "KVM64 (Default)" ON \
    "1" "Host" OFF \
    3>&1 1>&2 2>&3); then
    if [ $CPU_TYPE1 = "1" ]; then
      echo -e "${OS}${BOLD}${DGN}CPU Model: ${BGN}Host${CL}"
      CPU_TYPE=" -cpu host"
    else
      echo -e "${OS}${BOLD}${DGN}CPU Model: ${BGN}KVM64${CL}"
      CPU_TYPE=""
    fi
  else
    exit_script
  fi

  if CORE_COUNT=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate CPU Cores" 8 58 2 --title "CORE COUNT" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $CORE_COUNT ]; then
      CORE_COUNT="2"
      echo -e "${CPUCORE}${BOLD}${DGN}CPU Cores: ${BGN}$CORE_COUNT${CL}"
    else
      echo -e "${CPUCORE}${BOLD}${DGN}CPU Cores: ${BGN}$CORE_COUNT${CL}"
    fi
  else
    exit_script
  fi

  if RAM_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate RAM in MiB" 8 58 2048 --title "RAM" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $RAM_SIZE ]; then
      RAM_SIZE="2048"
      echo -e "${RAMSIZE}${BOLD}${DGN}RAM Size: ${BGN}$RAM_SIZE${CL}"
    else
      echo -e "${RAMSIZE}${BOLD}${DGN}RAM Size: ${BGN}$RAM_SIZE${CL}"
    fi
  else
    exit_script
  fi

  if BRG=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a Bridge" 8 58 vmbr0 --title "BRIDGE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $BRG ]; then
      BRG="vmbr0"
      echo -e "${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}$BRG${CL}"
    else
      echo -e "${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}$BRG${CL}"
    fi
  else
    exit_script
  fi

  if MAC1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a MAC Address" 8 58 $GEN_MAC --title "MAC ADDRESS" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $MAC1 ]; then
      MAC="$GEN_MAC"
      echo -e "${MACADDRESS}${BOLD}${DGN}MAC Address: ${BGN}$MAC${CL}"
    else
      MAC="$MAC1"
      echo -e "${MACADDRESS}${BOLD}${DGN}MAC Address: ${BGN}$MAC1${CL}"
    fi
  else
    exit_script
  fi

  if VLAN1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a Vlan(leave blank for default)" 8 58 --title "VLAN" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $VLAN1 ]; then
      VLAN1="Default"
      VLAN=""
      echo -e "${VLANTAG}${BOLD}${DGN}VLAN: ${BGN}$VLAN1${CL}"
    else
      VLAN=",tag=$VLAN1"
      echo -e "${VLANTAG}${BOLD}${DGN}VLAN: ${BGN}$VLAN1${CL}"
    fi
  else
    exit_script
  fi

  if MTU1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Interface MTU Size (leave blank for default)" 8 58 --title "MTU SIZE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $MTU1 ]; then
      MTU1="Default"
      MTU=""
      echo -e "${DEFAULT}${BOLD}${DGN}Interface MTU Size: ${BGN}$MTU1${CL}"
    else
      MTU=",mtu=$MTU1"
      echo -e "${DEFAULT}${BOLD}${DGN}Interface MTU Size: ${BGN}$MTU1${CL}"
    fi
  else
    exit_script
  fi

  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "START VIRTUAL MACHINE" --yesno "Start VM when completed?" 10 58); then
    echo -e "${GATEWAY}${BOLD}${DGN}Start VM when completed: ${BGN}yes${CL}"
    START_VM="yes"
  else
    echo -e "${GATEWAY}${BOLD}${DGN}Start VM when completed: ${BGN}no${CL}"
    START_VM="no"
  fi

  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "ADVANCED SETTINGS COMPLETE" --yesno "Ready to create a RaspiBlitz VM?" --no-button Do-Over 10 58); then
    echo -e "${CREATING}${BOLD}${DGN}Creating a RaspiBlitz VM using the above advanced settings${CL}"
  else
    header_info
    echo -e "${ADVANCED}${BOLD}${RD}Using Advanced Settings${CL}"
    advanced_settings
  fi
}

function start_script() {
  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "SETTINGS" --yesno "Use Default Settings?" --no-button Advanced 10 58); then
    header_info
    echo -e "${DEFAULT}${BOLD}${BL}Using Default Settings${CL}"
    default_settings
  else
    header_info
    echo -e "${ADVANCED}${BOLD}${RD}Using Advanced Settings${CL}"
    advanced_settings
  fi
}
check_root
arch_check
pve_check
ssh_check
start_script
post_to_api_vm

msg_info "Validating Storage"
while read -r line; do
  TAG=$(echo $line | awk '{print $1}')
  TYPE=$(echo $line | awk '{printf "%-10s", $2}')
  FREE=$(echo $line | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
  ITEM="  Type: $TYPE Free: $FREE "
  OFFSET=2
  if [[ $((${#ITEM} + $OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]]; then
    MSG_MAX_LENGTH=$((${#ITEM} + $OFFSET))
  fi
  STORAGE_MENU+=("$TAG" "$ITEM" "OFF")
done < <(pvesm status -content images | awk 'NR>1')
VALID=$(pvesm status -content images | awk 'NR>1')
if [ -z "$VALID" ]; then
  msg_error "Unable to detect a valid storage location."
  exit
elif [ $((${#STORAGE_MENU[@]} / 3)) -eq 1 ]; then
  STORAGE=${STORAGE_MENU[0]}
else
  while [ -z "${STORAGE:+x}" ]; do
    STORAGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Storage Pools" --radiolist \
      "Which storage pool would you like to use for ${HN}?\nTo make a selection, use the Spacebar.\n" \
      16 $(($MSG_MAX_LENGTH + 23)) 6 \
      "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3)
  done
fi
msg_ok "Using ${CL}${BL}$STORAGE${CL} ${GN}for Storage Location."
msg_ok "Virtual Machine ID is ${CL}${BL}$VMID${CL}."

# Preflight on the filesystem where the image is downloaded and decompressed.
# This is bounded by the IMAGE, not the VM disk size: the ~4 GB compressed
# download + the ~27 GB decompressed raw image + libguestfs/virt-customize
# scratch. It does NOT scale with DISK_SIZE (that space lives on the VM storage
# pool, not here), so 40 GB is a safe fixed requirement.
check_storage_space 40

msg_info "Retrieving the URL for $APP"
URL="https://raspiblitz.bittr.io/raspiblitz-amd64-debian-lean-2026-03-29-d52be1a.img.gz"
# SHA-256 of the compressed image (.img.gz). Hardcoded so every download is
# integrity-verified BEFORE decompression — the script aborts if the file was
# corrupted in transit or tampered with on the mirror.
IMG_GZ_SHA256="3167ddf4c383977526e779a2d4d7e7247438d776f08238468f0b51a5313f9cb9"
FILE="$(basename "$URL")"
# Cache the verified image so repeated runs don't re-download ~4 GB. The cache is
# keyed on the versioned filename and re-verified by checksum on every reuse, so a
# stale or corrupt cached file can never be used. Set CACHE_DIR="" to disable.
CACHE_DIR="${RASPIBLITZ_CACHE_DIR:-/var/cache/raspiblitz-vm}"
CACHE_FILE="${CACHE_DIR}/${FILE}"
sleep 2
msg_ok "${CL}${BL}${URL}${CL}"

if [ -n "$CACHE_DIR" ] && [ -f "$CACHE_FILE" ] && echo "${IMG_GZ_SHA256}  ${CACHE_FILE}" | sha256sum -c - >/dev/null 2>&1; then
  # Verified cache hit — skip the download entirely.
  GZ_SRC="$CACHE_FILE"
  msg_ok "Using cached image ${CL}${BL}${CACHE_FILE}${CL}"
else
  curl -f#SL -o "$FILE" "$URL"
  msg_ok "Downloaded ${CL}${BL}${FILE}${CL}"

  msg_info "Verifying SHA-256 checksum"
  if ! echo "${IMG_GZ_SHA256}  ${FILE}" | sha256sum -c - >/dev/null 2>&1; then
    msg_error "Checksum verification FAILED for ${FILE} — the image is corrupt or has been tampered with. Aborting."
    rm -f "$FILE"
    exit 1
  fi
  msg_ok "Verified SHA-256 ${CL}${BL}${IMG_GZ_SHA256}${CL}"
  GZ_SRC="$FILE"

  # Best-effort: save the verified image to the cache for next time.
  if [ -n "$CACHE_DIR" ] && mkdir -p "$CACHE_DIR" 2>/dev/null && cp -f "$FILE" "$CACHE_FILE" 2>/dev/null; then
    msg_ok "Cached image to ${CL}${BL}${CACHE_FILE}${CL}"
  fi
fi

if ! command -v pv &>/dev/null; then
  apt-get update &>/dev/null && apt-get install -y pv &>/dev/null
fi

msg_info "Decompressing image with progress${CL}\n"
FILE_IMG="${FILE%.gz}"
pv "$GZ_SRC" -N "Extracting" | gzip -dc >"$FILE_IMG"
msg_ok "Decompressed to ${CL}${BL}${FILE_IMG}${CL}"

# The RaspiBlitz image has no growroot, so its LVM root stays ~23 GB no matter how
# large the VM disk is. Inject a one-shot firstboot script (via libguestfs) that
# grows partition 3 -> LVM PV -> root LV -> ext4 to fill the disk on first boot.
# Best-effort: if libguestfs is unavailable or fails, the VM is still created and
# the user can expand root manually later. Disable with RASPIBLITZ_AUTO_GROW=0.
if [ "${RASPIBLITZ_AUTO_GROW:-1}" = "1" ]; then
  msg_info "Injecting first-boot root-filesystem auto-grow"
  if ! command -v virt-customize &>/dev/null; then
    apt update &>/dev/null && apt install -y libguestfs-tools &>/dev/null
  fi
  if command -v virt-customize &>/dev/null; then
    GROW_SCRIPT="${TEMP_DIR}/raspiblitz-growroot.sh"
    cat <<'GROW' >"$GROW_SCRIPT"
#!/bin/bash
# Grow the root partition -> LVM PV -> root LV -> filesystem to fill its disk
# (runs once). Detect everything dynamically: SCSI device naming (sda vs sdb) is
# NOT stable across VMs because the data disk can claim sda, so never hardcode it.
set -x
ROOT_LV=$(findmnt -no SOURCE /)
VG=$(lvs --noheadings -o vg_name "$ROOT_LV" 2>/dev/null | tr -d ' ')
PV=$(pvs --noheadings -o pv_name -S "vg_name=$VG" 2>/dev/null | head -n1 | tr -d ' ')
DISK=$(lsblk -no pkname "$PV" 2>/dev/null | head -n1)
PARTNUM=$(echo "$PV" | grep -oE '[0-9]+$')
[ -n "$DISK" ] && [ -n "$PARTNUM" ] || { echo "growroot: could not detect root disk/partition"; exit 0; }
growpart "/dev/$DISK" "$PARTNUM" || echo ", +" | sfdisk --no-reread -N "$PARTNUM" "/dev/$DISK" || true
partprobe "/dev/$DISK" 2>/dev/null || partx -u "/dev/$DISK" 2>/dev/null || true
pvresize "$PV" || true
lvextend -l +100%FREE "$ROOT_LV" || true
if [ "$(findmnt -no FSTYPE /)" = "xfs" ]; then xfs_growfs / || true; else resize2fs "$ROOT_LV" || true; fi
GROW
    if LIBGUESTFS_BACKEND=direct virt-customize -a "$FILE_IMG" --firstboot "$GROW_SCRIPT" &>/dev/null; then
      msg_ok "Injected first-boot root auto-grow (root will fill ${DISK_SIZE} on first boot)"
    else
      echo -e "${TAB}${YW}⚠ Could not inject auto-grow (libguestfs failed). VM will still be created; root stays at the image default ~23 GB — expand manually later.${CL}"
    fi
  else
    echo -e "${TAB}${YW}⚠ libguestfs-tools unavailable — skipping root auto-grow; root stays ~23 GB.${CL}"
  fi
fi

STORAGE_TYPE=$(pvesm status -storage $STORAGE | awk 'NR>1 {print $2}')
case $STORAGE_TYPE in
nfs | dir)
  DISK_EXT=".raw"
  DISK_REF="$VMID/"
  DISK_IMPORT="-format raw"
  THIN=""
  ;;
btrfs)
  DISK_EXT=".raw"
  DISK_REF="$VMID/"
  DISK_IMPORT="-format raw"
  FORMAT=",efitype=4m"
  THIN=""
  ;;
esac
for i in {0,1,2}; do
  disk="DISK$i"
  eval DISK${i}=vm-${VMID}-disk-${i}${DISK_EXT:-}
  eval DISK${i}_REF=${STORAGE}:${DISK_REF:-}${!disk}
done

msg_info "Creating the RaspiBlitz VM shell"
qm create $VMID -agent 1${MACHINE} -tablet 0 -localtime 1 -bios ovmf${CPU_TYPE} -cores $CORE_COUNT -memory $RAM_SIZE \
  -name $HN -tags community-script -net0 virtio,bridge=$BRG,macaddr=$MAC$VLAN$MTU -onboot 1 -ostype l26 -scsihw virtio-scsi-pci >/dev/null
pvesm alloc $STORAGE $VMID $DISK0 4M >/dev/null
msg_ok "Created the RaspiBlitz VM shell ${CL}${BL}(ID ${VMID})${CL}"

# Importing the ~26 GiB raw image into the storage pool is the slow part (minutes
# on Ceph/NFS). Don't suppress its output — qm importdisk prints live "transferred
# X% of N GiB" progress so the user can see it working instead of a frozen spinner.
echo -e "${TAB}${YW}Importing the OS image into ${BL}${STORAGE}${YW} — this can take several minutes (Ceph/NFS are slower)...${CL}\n"
qm importdisk $VMID ${FILE_IMG} $STORAGE ${DISK_IMPORT:-}
msg_ok "Imported the OS image into ${CL}${BL}${STORAGE}${CL}"

msg_info "Attaching disks and finalizing configuration"
qm set $VMID \
  -efidisk0 ${DISK0_REF}${FORMAT} \
  -scsi0 ${DISK1_REF},${DISK_CACHE}${THIN}size=${DISK_SIZE} \
  -boot order=scsi0 \
  -serial0 socket >/dev/null
# Second disk: blockchain/data volume that RaspiBlitz auto-detects and mounts at /mnt/hdd
DATA_DISK_GB="${DATA_DISK_SIZE%G}"
qm set $VMID -scsi1 ${STORAGE}:${DATA_DISK_GB},${DISK_CACHE}${THIN}backup=0 >/dev/null
qm set $VMID --agent enabled=1 >/dev/null
msg_ok "Attached disks ${CL}${BL}(OS ${DISK_SIZE}, data ${DATA_DISK_SIZE} → /mnt/hdd)${CL}"

DESCRIPTION=$(
  cat <<EOF
<div align='center'>
  <a href='https://Helper-Scripts.com' target='_blank' rel='noopener noreferrer'>
    <img src='https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/images/logo-81x112.png' alt='Logo' style='width:81px;height:112px;'/>
  </a>

  <h2 style='font-size: 24px; margin: 20px 0;'>RaspiBlitz VM</h2>

  <p style='margin: 16px 0;'>
    Set up via <b>SSH</b> (<code>ssh admin@&lt;VM-IP&gt;</code>, default password <code>raspiblitz</code>).
    This image is built without the Web UI/API, so SSH is the only interface. The Proxmox
    console shows RaspiBlitz's LCD interface, which does not work in a VM — this is expected.
  </p>

  <p style='margin: 16px 0;'>
    <a href='https://ko-fi.com/community_scripts' target='_blank' rel='noopener noreferrer'>
      <img src='https://img.shields.io/badge/&#x2615;-Buy us a coffee-blue' alt='spend Coffee' />
    </a>
  </p>

  <span style='margin: 0 10px;'>
    <i class="fa fa-github fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/community-scripts/ProxmoxVE' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>GitHub</a>
  </span>
  <span style='margin: 0 10px;'>
    <i class="fa fa-comments fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/community-scripts/ProxmoxVE/discussions' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Discussions</a>
  </span>
  <span style='margin: 0 10px;'>
    <i class="fa fa-exclamation-circle fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/community-scripts/ProxmoxVE/issues' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Issues</a>
  </span>
</div>
EOF
)
qm set "$VMID" -description "$DESCRIPTION" >/dev/null

if [ -n "$DISK_SIZE" ]; then
  msg_info "Resizing disk to $DISK_SIZE GB"
  qm resize $VMID scsi0 ${DISK_SIZE} >/dev/null
else
  msg_info "Using default disk size of $DEFAULT_DISK_SIZE GB"
  qm resize $VMID scsi0 ${DEFAULT_DISK_SIZE} >/dev/null
fi

msg_ok "Created a RaspiBlitz VM ${CL}${BL}(${HN})"
if [ "$START_VM" == "yes" ]; then
  msg_info "Starting RaspiBlitz VM"
  qm start $VMID
  msg_ok "Started RaspiBlitz VM"
fi
post_update_to_api "done" "none"
msg_ok "Completed successfully!\n"

echo -e "${INFO}${YW} Set up RaspiBlitz over SSH — NOT the Proxmox console.${CL}"
echo -e "${TAB}This image is built without the Web UI/API, so SSH is the only interface."
echo -e "${TAB}The noVNC/Proxmox console runs RaspiBlitz's LCD interface, which does not work"
echo -e "${TAB}in a VM (harmless '/dev/fb0 Oops: Quit' errors). Once the VM has an IP:"
echo -e "${TAB}${GATEWAY}${BGN}SSH:${CL} ssh admin@<VM-IP>   ${YW}(default password: raspiblitz)${CL}"
echo -e "${TAB}${YW}Find the IP in your router, or in Proxmox → VM ${VMID} → Summary (guest agent).${CL}"
