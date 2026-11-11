import Foundation

/// Samplers report an explicit hardware inventory. Missing inventory must not
/// silently fall back to unfiltered loopback, virtual or partition counters.
enum PhysicalDevices {
    static func names(_ rows: [String]?, limit: Int) -> Set<String> {
        Set((rows ?? []).prefix(limit).compactMap { row in
            let name = row.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.count <= 128,
                  name.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            return name
        })
    }
    /// Resolve class symlinks before inspecting the device tree, and inspect
    /// DEVTYPE/partition on the device itself rather than guessing from names.
    static let linuxInventory = #"""
    termvia_sysfs=${TERMVIA_SYSFS_ROOT:-/sys}
    termvia_sysfs=$(CDPATH= cd -P "$termvia_sysfs" 2>/dev/null && pwd -P)
    printf '[physical-network]\n'
    if [ -n "$termvia_sysfs" ]; then
      for entry in "$termvia_sysfs"/class/net/*; do
        path=$(CDPATH= cd -P "$entry" 2>/dev/null && pwd -P)
        case "$path" in "$termvia_sysfs"/devices/virtual/*) continue;; "$termvia_sysfs"/devices/*) ;; *) continue;; esac
        printf '%s\n' "${entry##*/}"
      done
    fi
    printf '[physical-disks]\n'
    if [ -n "$termvia_sysfs" ]; then
      for entry in "$termvia_sysfs"/class/block/*; do
        path=$(CDPATH= cd -P "$entry" 2>/dev/null && pwd -P)
        case "$path" in "$termvia_sysfs"/devices/virtual/*) continue;; "$termvia_sysfs"/devices/*) ;; *) continue;; esac
        [ -r "$path/uevent" ] && [ ! -e "$path/partition" ] || continue
        case "${entry##*/}" in mmcblk*boot*|mmcblk*rpmb) continue;; esac
        whole=0
        while IFS= read -r property; do [ "$property" != 'DEVTYPE=disk' ] || whole=1; done < "$path/uevent"
        [ "$whole" != 1 ] || printf '%s\n' "${entry##*/}"
      done
    fi
    """#
    /// Filesystem identity comes from mountinfo; resolve partitions and stacked
    /// devices through sysfs slaves, so bind mounts and LVM are not double-counted.
    static let linuxVolumeMap = #"""
    termvia_backing() (
      node=$1; depth=$2
      [ "$depth" -lt 16 ] || exit
      path=$(CDPATH= cd -P "$node" 2>/dev/null && pwd -P)
      [ -n "$path" ] || exit
      if [ -e "$path/partition" ]; then path=${path%/*}; fi
      found=0
      for slave in "$path"/slaves/*; do
        [ -e "$slave" ] || continue
        found=1; termvia_backing "$slave" "$((depth + 1))"
      done
      [ "$found" = 0 ] || exit
      case "$path" in "$termvia_sysfs"/devices/virtual/*) exit;; "$termvia_sysfs"/devices/*) ;; *) exit;; esac
      printf '%s\n' "${path##*/}"
    )
    printf '[volume-physical-map]\n'
    if [ -n "$termvia_sysfs" ] && [ -r /proc/self/mountinfo ]; then
      awk '{for(i=7;i<=NF;i++) if($i=="-") {print $3, $(i+2); break}}' /proc/self/mountinfo |
      while read -r identity source; do
        case "$source" in /dev/*) ;; *) continue;; esac
        devices=$(termvia_backing "$termvia_sysfs/dev/block/$identity" 0 | sort -u | paste -sd, -)
        [ -z "$devices" ] || printf '%s\t%s\t%s\n' "$source" "$identity" "$devices"
      done
    fi
    """#

    /// Keep only the upperdir option; Docker lowerdir lists can be enormous.
    /// Preserve escaped commas and mountinfo octal paths for the decoder.
    static let linuxMounts = #"""
    printf '[mounts-linux]\n'
    awk '
      function upper(options, token,i,c) {
        token=""
        for(i=1;i<=length(options);i++) {
          c=substr(options,i,1)
          if(c=="\\") {token=token c substr(options,++i,1); continue}
          if(c==",") {if(index(token,"upperdir=")==1) return substr(token,10); token=""}
          else token=token c
        }
        return index(token,"upperdir=")==1 ? substr(token,10) : ""
      }
      NR<=2048 {for(i=7;i<=NF;i++) if($i=="-") {
        item=$3 "\t" $5 "\t" $(i+1) "\t" $6 "\t" upper($(i+3))
        if(length(item)<=8192 && bytes+length(item)<131072) {print item; bytes+=length(item)+1}
        break
      }}' /proc/self/mountinfo 2>/dev/null
    """#

    static let linuxVolumes = #"""
    printf '[volumes]\n'
    if command -v timeout >/dev/null 2>&1; then
      timeout 2 sh -c 'df -Pk -l 2>/dev/null || df -Pk 2>/dev/null'
    else
      df -Pk -l 2>/dev/null || df -Pk 2>/dev/null
    fi
    """#

}
