import Foundation

/// Count online logical CPUs and distinct physical cores across every package.
/// Do not infer one core per thread when topology is unavailable (common on
/// embedded kernels). sysfs sibling groups also work on ARM without package IDs.
enum LinuxCPUTopology {
    static let script = #"""
    termvia_cpu_topology() (
      root=${termvia_sysfs:-${TERMVIA_SYSFS_ROOT:-/sys}}
      topology=$(
        for cpu in "$root"/devices/system/cpu/cpu[0-9]*; do
          [ -d "$cpu" ] || continue
          id=${cpu##*/cpu}; case "$id" in (''|*[!0-9]*) continue;; esac
          online=1
          if [ -e "$cpu/online" ]; then
            if ! IFS= read -r online < "$cpu/online"; then printf '!\n'; continue; fi
          fi
          [ "$online" = 1 ] || continue
          key=; siblings=
          if [ -r "$cpu/topology/thread_siblings_list" ]; then IFS= read -r siblings < "$cpu/topology/thread_siblings_list"; fi
          case "$siblings" in (''|*[!0-9,-]*) ;;
            (*) [ "${#siblings}" -gt 1024 ] || key=s$siblings;;
          esac
          if [ -z "$key" ]; then
            package=; core=
            if [ -r "$cpu/topology/physical_package_id" ]; then IFS= read -r package < "$cpu/topology/physical_package_id"; fi
            if [ -r "$cpu/topology/core_id" ]; then IFS= read -r core < "$cpu/topology/core_id"; fi
            case "$package:$core" in (:*|*:|*[!0-9:]*) ;; (*) key=p${package}c${core};; esac
          fi
          printf '%s\n' "${key:-?}"
        done 2>/dev/null |
        awk '$0=="!" {incomplete=1; next} {threads++; if($0=="?") unknown=1; else cores[$0]=1}
          END {for(c in cores) count++; if(incomplete) print 0,0; else print (unknown ? 0 : count+0),threads+0}'
      )
      set -- $topology; cores=${1:-0}; threads=${2:-0}
      if [ "$cores" -eq 0 ]; then
        proc=$(
          awk -F: '
            function commit() {
              if(processor!="" && !(processor in seen)) {
                seen[processor]=1; threads++
                if(package!="" && core!="") pairs[package ":" core]=1; else unknown=1
                if(package!="" && count>0 && siblings>0) {
                  package_threads[package]++
                  if((package in package_cores) && (package_cores[package]!=count || package_siblings[package]!=siblings)) bad=1
                  package_cores[package]=count; package_siblings[package]=siblings
                } else bad=1
              }
              processor=""; package=""; core=""; count=0; siblings=0
            }
            /^[ \t]*$/ {commit(); next}
            {key=tolower($1); gsub(/^[ \t]+|[ \t]+$/,"",key); value=$2; gsub(/^[ \t]+|[ \t]+$/,"",value)
              if(value !~ /^[0-9]+$/) next
              if(key=="processor") processor=value
              else if(key=="physical id") package=value
              else if(key=="core id") core=value
              else if(key=="cpu cores") count=value+0
              else if(key=="siblings") siblings=value+0
            }
            END {commit(); for(p in pairs) physical++
              if(unknown) {
                physical=0
                for(p in package_cores) {if(package_threads[p]!=package_siblings[p]) bad=1; physical+=package_cores[p]}
                if(bad) physical=0
              }
              print physical+0,threads+0
            }' /proc/cpuinfo 2>/dev/null
        )
        set -- $proc
        if [ "$threads" -eq 0 ]; then cores=${1:-0}; threads=${2:-0}
        elif [ "$threads" = "${2:-0}" ]; then cores=${1:-0}; fi
      fi
      if [ "$threads" -eq 0 ]; then threads=$(awk '/^cpu[0-9]+ / {n++} END {print n+0}' /proc/stat 2>/dev/null); fi
      case "$threads" in ''|*[!0-9]*) threads=0;; esac
      if [ "$threads" -eq 0 ]; then threads=$(getconf _NPROCESSORS_ONLN 2>/dev/null); fi
      case "$threads" in ''|*[!0-9]*) threads=0;; esac
      [ "$cores" -le "$threads" ] || cores=0
      [ "$cores" -ne 0 ] || cores=
      [ "$threads" -ne 0 ] || threads=
      printf '[cores]\n%s\n[threads]\n%s\n' "$cores" "$threads"
    )
    """#
}
