#!/bin/bash
set -euo pipefail
#
# Script to execute by azure-chroot's `pre_mount[]` hendler
#
###########################################################################
BOOTDEVSZ="${BOOTDEVSZ:-1024}"
CHROOTDEV="${CHROOTDEV:-UNDEF}"
FSTYPE="${FSTYPE:-xfs}"
MKFSFORCEOPT="${MKFSFORCEOPT:--f}"
PARTITIONARRAY=(
  "/:rootVol:12"
  "swap:swapVol:4"
  "/home:homeVol:2"
  "/var:varVol:8"
  "/var/log:logVol:4"
  "/var/log/audit:auditVol:FREE"
)
PROGNAME="$( basename "$0" )"
UEFIDEVSZ="${UEFIDEVSZ:-64}"
VGNAME="${VGNAME:-RootVG}"

# Make interactive-execution more-verbose unless explicitly told not to
if [[ $( tty -s ) -eq 0 ]] && [[ ${DEBUG:-} == "UNDEF" ]]
then
  DEBUG="true"
fi

# Error handler function
function err_exit {
  local ERRSTR
  local ISNUM
  local SCRIPTEXIT

  ERRSTR="${1}"
  ISNUM='^[0-9]+$'
  SCRIPTEXIT="${2:-1}"

  if [[ ${DEBUG:-} == true ]]
  then
    # Our output channels
    logger -i -t "${PROGNAME}" -p kern.crit -s -- "${ERRSTR}"
  else
    logger -i -t "${PROGNAME}" -p kern.crit -- "${ERRSTR}"
  fi

  # Only exit if requested exit is numerical
  if [[ ${SCRIPTEXIT} =~ ${ISNUM} ]]
  then
    exit "${SCRIPTEXIT}"
  fi
}

# Parition the disk
parted -s "${CHROOTDEV}" -- mktable gpt \
    mkpart primary xfs 1049k 2m \
    mkpart primary fat16 4096s $(( 2 + UEFIDEVSZ ))m \
    mkpart primary xfs $((
      2 + UEFIDEVSZ ))m $(( ( 2 + UEFIDEVSZ ) + BOOTDEVSZ
    ))m \
    mkpart primary xfs $(( ( 2 + UEFIDEVSZ ) + BOOTDEVSZ ))m 100% \
    set 1 bios_grub on \
    set 2 esp on \
    set 3 bls_boot on \
    set 4 lvm on || \
      err_exit "Failed laying down new partition-table" 1

# Create root volume-group
vgcreate -y "${VGNAME}" "${CHROOTDEV}4" || \
    err_exit "VG creation failed. Aborting!"

# Create LVM2 volume-objects by iterating ${PARTITIONARRAY}
ITER=0
while [[ ${ITER} -lt ${#PARTITIONARRAY[*]} ]]
do
  MOUNTPT="$( cut -d ':' -f 1 <<< "${PARTITIONARRAY[${ITER}]}")"
  VOLNAME="$( cut -d ':' -f 2 <<< "${PARTITIONARRAY[${ITER}]}")"
  VOLSIZE="$( cut -d ':' -f 3 <<< "${PARTITIONARRAY[${ITER}]}")"

  # Create LVs
  if [[ ${VOLSIZE} =~ FREE ]]
  then
    # Make sure 'FREE' is given as last list-element
    if [[ $(( ITER += 1 )) -eq ${#PARTITIONARRAY[*]} ]]
    then
      VOLFLAG="-l"
      VOLSIZE="100%FREE"
    else
      echo "Using 'FREE' before final list-element. Aborting..."
      kill -s TERM " ${TOP_PID}"
    fi
  else
    VOLFLAG="-L"
    VOLSIZE+="g"
  fi
  lvcreate --yes -W y "${VOLFLAG}" "${VOLSIZE}" -n "${VOLNAME}" "${VGNAME}" || \
    err_exit "Failure creating LVM2 volume '${VOLNAME}'"

  # Create FSes on LVs
  if [[ ${MOUNTPT} == swap ]]
  then
    err_exit "Creating swap filesystem..." NONE
    mkswap "/dev/${VGNAME}/${VOLNAME}" || \
      err_exit "Failed creating swap filesystem..."
  else
    err_exit "Creating filesystem for ${MOUNTPT}..." NONE
    mkfs -t "${FSTYPE}" "${MKFSFORCEOPT}" "/dev/${VGNAME}/${VOLNAME}" || \
      err_exit "Failure creating filesystem for '${MOUNTPT}'"
  fi

  (( ITER+=1 ))
done
