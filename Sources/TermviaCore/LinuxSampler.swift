import Foundation

enum LinuxSampler {
    static let script = #"""
    if [ "$(uname -s)" != Linux ]; then exit 42; fi
    trap 'exit 0' HUP INT TERM
    sample_limit=${1:-0}; sample_interval=${2:-1}; sample_count=0; slow_elapsed=30
    case "$sample_interval" in ''|*[!0-9]*) exit 43;; esac
    [ "$sample_interval" -ge 1 ] && [ "$sample_interval" -le 30 ] || exit 43
    termvia_sysfs=${TERMVIA_SYSFS_ROOT:-/sys}
    termvia_sysfs=$(CDPATH= cd -P "$termvia_sysfs" 2>/dev/null && pwd -P)
    """# + "\n" + LinuxCPUTopology.script + "\n" + #"""
    termvia_inventory() {
    """# + "\n" + PhysicalDevices.linuxInventory + "\n" + #"""
    }
    termvia_slow() {
      termvia_cpu_topology
      printf '%s\n[partitions]\n' "$inventory"
      TERMVIA_INVENTORY="$inventory" awk 'BEGIN {n=split(ENVIRON["TERMVIA_INVENTORY"],a,"\n"); for(i=1;i<=n;i++) {if(a[i]=="[physical-disks]") active=1; else if(substr(a[i],1,1)=="[") active=0; else if(active) disks[a[i]]=1}} $4 in disks {print}' /proc/partitions
    """# + "\n" + PhysicalDevices.linuxVolumes + "\n" + PhysicalDevices.linuxVolumeMap + "\n" + PhysicalDevices.linuxMounts + "\n" + #"""
    }
    info=$(
      printf '[platform]\nLinux\n[boot]\n'; cat /proc/sys/kernel/random/boot_id 2>/dev/null
      printf '\n[hostname]\n'; uname -n
      printf '[kernel]\n'; uname -r
      printf '[architecture]\n'; uname -m
      printf '[processor]\n'; awk -F: '/model name|Hardware|Processor/ {sub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo
      printf '[os]\n'; awk '/^PRETTY_NAME=/' /etc/os-release 2>/dev/null
    )
    while :; do
      changed=
      if [ "$slow_elapsed" -ge 30 ]; then
        inventory=$(termvia_inventory)
        slow=$(termvia_slow)
        if [ "$slow" != "$previous_slow" ]; then changed=$slow; previous_slow=$slow; fi
        clock=$(date '+%s %z' 2>/dev/null); clock_epoch=${clock% *}; clock_zone=${clock#* }
        clock_uptime=
        if [ -r /proc/uptime ]; then IFS=' ' read -r clock_uptime clock_idle < /proc/uptime; fi
        slow_elapsed=0
      fi
      printf '@termvia-begin-v2\n' || exit 0
      [ "$sample_count" -ne 0 ] || printf '%s\n' "$info"
      [ -z "$changed" ] || printf '%s\n' "$changed"
      # awk stops at the first unreadable argument. Omit unavailable files so
      # a restricted /proc/net/dev cannot hide CPU, memory or load readings.
      set --
      for file in /proc/uptime /proc/stat /proc/meminfo /proc/loadavg /proc/net/dev /proc/diskstats; do
        [ ! -r "$file" ] || set -- "$@" "$file"
      done
      TERMVIA_INVENTORY="$inventory" awk -v epoch="$clock_epoch" -v zone="$clock_zone" -v anchor="$clock_uptime" '
        BEGIN {n=split(ENVIRON["TERMVIA_INVENTORY"],a,"\n"); for(i=1;i<=n;i++) {if(a[i]=="[physical-network]") section="net"; else if(a[i]=="[physical-disks]") section="disk"; else if(section=="net") net[a[i]]=1; else if(section=="disk") disk[a[i]]=1}}
        FILENAME=="/proc/uptime" {if($1 ~ /^[0-9]+([.][0-9]+)?$/) up=$1; next}
        FILENAME=="/proc/stat" {if($1=="cpu") {cpu="cpu"; for(i=2;i<=9 && i<=NF;i++) cpu=cpu " " $i}; next}
        FILENAME=="/proc/meminfo" {if(($1=="MemTotal:" || $1=="MemAvailable:" || $1=="MemFree:" || $1=="Buffers:" || $1=="Cached:") && $2 ~ /^[0-9]+$/) mem[$1]=$2; next}
        FILENAME=="/proc/loadavg" {load=$1 " " $2 " " $3; next}
        FILENAME=="/proc/net/dev" {split($0,p,":"); gsub(/^[ \t]+|[ \t]+$/,"",p[1]); if(p[1] in net) {gsub(/^[ \t]+/,"",p[2]); split(p[2],v,/[ \t]+/); network=network p[1] " " v[1] " " v[9] "\n"}; next}
        FILENAME=="/proc/diskstats" {if($3 in disk) storage=storage $3 " " $6 " " $10 "\n"}
        END {
          # Only restricted hosts need an extra clock command per sample.
          if(up=="" || anchor !~ /^[0-9]+([.][0-9]+)?$/ || epoch=="") {command="date +%s"; command | getline wall; close(command)}
          else wall=epoch+up-anchor
          printf "[uptime]\n%s\n[counter-time]\n%s\n[cpu]\n%s\n",up,(up!="" ? up : wall),cpu
          if(wall!="") printf "[clock]\n%.2f %s\n",wall,zone
          printf "[memory]\nMemTotal: %.0f kB\n",mem["MemTotal:"]
          if("MemAvailable:" in mem) printf "MemAvailable: %.0f kB\n",mem["MemAvailable:"]
          else if("MemFree:" in mem) printf "MemAvailable: %.0f kB\n",mem["MemFree:"]+mem["Buffers:"]+mem["Cached:"]
          printf "[load]\n%s\n",load
          printf "[network-compact]\n%s[disk-sectors]\n%s",network,storage
        }' "$@" </dev/null
      printf '@termvia-end\n' || exit 0
      sample_count=$((sample_count + 1)); if [ "$sample_limit" -gt 0 ] && [ "$sample_count" -ge "$sample_limit" ]; then break; fi
      sleep "$sample_interval"
      slow_elapsed=$((slow_elapsed + sample_interval))
    done
    """#
}
