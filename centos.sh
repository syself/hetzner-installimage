#!/bin/bash
#
# CentOS specific functions
#
# (c) 2008-2021, Hetzner Online GmbH
#

# generate_config_mdadm "NIL"
generate_config_mdadm() {
  [[ -z "$1" ]] && return 0

  local mdadmconf='/etc/mdadm.conf'
  {
    echo 'DEVICE partitions'
    echo 'MAILADDR root'
  } > "${FOLD}/hdd${mdadmconf}"

  execute_chroot_command "mdadm --examine --scan >> ${mdadmconf}"
  return $?
}

# generate_new_ramdisk "NIL"
generate_new_ramdisk() {
  [[ -z "$1" ]] && return 0

  blacklist_unwanted_and_buggy_kernel_modules
  configure_kernel_modules

  local dracutfile="${FOLD}/hdd/etc/dracut.conf.d/99-${C_SHORT}.conf"
  cat << EOF > "$dracutfile"
### ${COMPANY} - installimage
add_dracutmodules+=" lvm mdraid "
add_drivers+=" raid0 raid1 raid10 raid456 ext2 ext3 ext4 xfs vfat "
hostonly="no"
hostonly_cmdline="no"
lvmconf="yes"
mdadmconf="yes"
persistent_policy="by-uuid"
EOF

  # generate initramfs for the latest kernel
  execute_chroot_command "dracut -f --kver $(find "${FOLD}/hdd/boot/" -name 'vmlinuz-*' | cut -d '-' -f 2- | sort -V | tail -1)"
  return $?
}

#
# generate_config_grub <version>
#
# Generate the GRUB bootloader configuration.
#
generate_config_grub() {
  local grubdefconf="${FOLD}/hdd/etc/default/grub"
  local grub_cmdline_linux='biosdevname=0 rd.auto=1 consoleblank=0'

  debug "# Building device map for GRUB2"
  build_device_map 'grub2'

  if rhel_9_based_image; then
    grub_cmdline_linux+=' crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M'
  elif rhel_10_based_image; then
    grub_cmdline_linux+=' crashkernel=2G-64G:256M,64G-:512M'
  else
    grub_cmdline_linux+=' crashkernel=auto'
  fi

  # nomodeset can help avoid issues with some GPUs.
  if ((USE_KERNEL_MODE_SETTING == 0)); then
    grub_cmdline_linux+=' nomodeset'
  fi

  # 'noop' scheduler is used in VMs to reduce overhead.
  if is_virtual_machine; then
    grub_cmdline_linux+=' elevator=noop'
  fi

  # disable memory-mapped PCI configuration
  if has_threadripper_cpu; then
    grub_cmdline_linux+=' pci=nommconf'
  fi

  if [[ "$SYSARCH" = "arm64" ]]; then
    grub_cmdline_linux+=' console=ttyAMA0 console=tty0'
  fi

  # Configure grub
  debug "# Configuring grub defaults"
  sed -i "s/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX=\"${grub_cmdline_linux}\"/" "$grubdefconf"

    # Ensure all needed filesystem modules are loaded
  sed -i '/^GRUB_PRELOAD_MODULES=/d' "$grubdefconf"
  echo 'GRUB_PRELOAD_MODULES="part_gpt part_msdos lvm ext2 ext4 xfs"' >> "$grubdefconf"

  # Ensure GRUB knows to use UUIDs
  sed -i '/^GRUB_DISABLE_LINUX_UUID=/d' "$grubdefconf"
  echo 'GRUB_DISABLE_LINUX_UUID=false' >> "$grubdefconf"

  # Disable OS prober to prevent false positives
  sed -i '/^GRUB_DISABLE_OS_PROBER=/d' "$grubdefconf"
  echo 'GRUB_DISABLE_OS_PROBER=true' >> "$grubdefconf"

  # Ensure GRUB timeout is reasonable
  sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' "$grubdefconf"
  sed -i 's/^GRUB_HIDDEN_TIMEOUT_QUIET=.*/GRUB_HIDDEN_TIMEOUT_QUIET=false/' "$grubdefconf"

  # Make sure not using gfxmode
  sed -i 's/^GRUB_TERMINAL=.*/GRUB_TERMINAL="console"/' "$grubdefconf"
  sed -i 's/^GRUB_GFXMODE=.*/GRUB_GFXMODE="text"/' "$grubdefconf"

  # set $GRUB_DEFAULT_OVERRIDE to specify custom GRUB_DEFAULT Value ( https://www.gnu.org/software/grub/manual/grub/grub.html#Simple-configuration )
  [[ -n "$GRUB_DEFAULT_OVERRIDE" ]] && sed -i "s/^GRUB_DEFAULT=.*/GRUB_DEFAULT=${GRUB_DEFAULT_OVERRIDE}/" "$grubdefconf"

  debug "# GRUB default configuration:"
  cat "$grubdefconf" | debugoutput

  # Install GRUB bootloader and generate configuration
  debug "# Installing GRUB bootloader"
  if [ "$UEFI" -eq 1 ]; then
    local grub2_install_flags="--efi-directory=/boot/efi --bootloader-id=centos --no-nvram --force --recheck"

    if [ "$SYSARCH" = "arm64" ]; then
      # For ARM64 UEFI systems, use the correct target
      grub2_install_flags="--target=arm64-efi ${grub2_install_flags} --removable"
    else
      # For x86_64 UEFI systems
      grub2_install_flags="--target=x86_64-efi ${grub2_install_flags}"
    fi

    execute_chroot_command "grub2-install ${grub2_install_flags}" || return $?

    # Set up fallback boot entries
    execute_chroot_command "mkdir -p /boot/efi/EFI/BOOT" || return $?
    if [ "$SYSARCH" = "arm64" ]; then
      execute_chroot_command "cp /boot/efi/EFI/centos/grubaa64.efi /boot/efi/EFI/BOOT/bootaa64.efi" || return $?
    else
      execute_chroot_command "cp /boot/efi/EFI/centos/grubx64.efi /boot/efi/EFI/BOOT/bootx64.efi" || return $?
    fi
  else
    # For BIOS systems - install on ALL drives
    for i in $(seq 1 $COUNT_DRIVES); do
      local disk; disk="$(eval echo "\$DRIVE$i")"
      debug "# Installing GRUB on $disk"
      execute_chroot_command "grub2-install --target=i386-pc --force --recheck $disk" || return $?
    done
  fi
}

write_grub() {
  # Generate the GRUB configuration file
  debug "# Generating GRUB configuration"

  execute_chroot_command "grub2-mkconfig -o /boot/grub2/grub.cfg --update-bls-cmdline" || return $?

    # For UEFI, also build grub.cfg in the EFI directory + copy it to the fallback location
  if [ "$UEFI" -eq 1 ]; then
    # Apply UUID fixes to GRUB config
    debug "# Applying UUID bugfixes to GRUB"
    grub2_uuid_bugfix "centos" || return $?

    execute_chroot_command "cp /boot/efi/EFI/centos/grub.cfg /boot/efi/EFI/BOOT/" || return $?
  fi
}

# os specific functions
run_os_specific_functions() {
  randomize_mdadm_array_check_time

  # selinux autorelabel if enabled
  if grep -Eq 'SELINUX=(enforcing|permissive)' "${FOLD}/hdd/etc/sysconfig/selinux"; then
    touch "${FOLD}/hdd/.autorelabel"
  fi

  mkdir -p "${FOLD}/hdd/var/run/netreport"

  return 0
}

# vim: ai:ts=2:sw=2:et
