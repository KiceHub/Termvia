import Foundation

enum DarwinMetrics {
    static func network(_ rows: [String], physical: Set<String>) -> [String: IOCounters] {
        var result: [String: IOCounters] = [:]
        for row in rows.prefix(4096) {
            let fields = row.split(whereSeparator: \.isWhitespace)
            // inet/inet6 rows repeat the link totals; count each link once.
            guard fields.count >= 10, fields[2].hasPrefix("<Link#"), fields[0].utf8.count <= 64,
                  let read = UInt64(fields[fields.count - 5]), let write = UInt64(fields[fields.count - 2]) else { continue }
            let name = String(fields[0]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if physical.contains(name) { result[name] = IOCounters(read: read, write: write) }
        }
        return result
    }
    static func storage(_ rows: [String], physical: Set<String>) -> (counters: [String: IOCounters], capacities: [String: Double]) {
        var counters: [String: IOCounters] = [:], capacities: [String: Double] = [:]
        var device: String?, read: UInt64?, write: UInt64?, size: UInt64?
        func commit() {
            guard let device, physical.contains(device), let read, let write else { return }
            counters[device] = IOCounters(read: read, write: write)
            if let size { capacities[device] = Double(size) }
        }
        func number(_ key: String, in row: String) -> UInt64? {
            guard let range = row.range(of: "\"" + key + "\""), let equals = row[range.upperBound...].firstIndex(of: "=") else { return nil }
            return UInt64(row[row.index(after: equals)...].drop(while: \.isWhitespace).prefix(while: \.isNumber))
        }
        for row in rows.prefix(4096) {
            if row.hasPrefix("+-o ") { commit(); device = nil; read = nil; write = nil; size = nil }
            else if row.contains("+-o ") { commit(); device = nil; size = nil }
            if row.contains("\"Statistics\"") {
                read = number("Bytes (Read)", in: row); write = number("Bytes (Write)", in: row)
            }
            if row.contains("\"BSD Name\""), let equals = row.firstIndex(of: "=") {
                let name = row[row.index(after: equals)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !name.isEmpty && name.utf8.count <= 128 { device = name }
            }
            if let bytes = number("Size", in: row) { size = bytes }
        }
        commit(); return (counters, capacities)
    }

    /// One persistent iostat stream; expensive hardware/filesystem discovery
    /// is cached for 30 seconds. Only physical-device byte counters cross SSH.
    static let script = #"""
    sample_limit=${1:-0}; sample_interval=${2:-1}; sample_count=0; slow_elapsed=30
    case "$sample_interval" in ''|*[!0-9]*) exit 43;; esac
    [ "$sample_interval" -ge 1 ] && [ "$sample_interval" -le 30 ] || exit 43
    trap 'exit 0' HUP INT TERM
    boot_seconds=$(/usr/sbin/sysctl -n kern.boottime | /usr/bin/awk -F'[=,]' '{gsub(/[ \t]/,"",$2); print $2}')
    boot_id=$(/usr/sbin/sysctl -n kern.bootsessionuuid)
    memory_bytes=$(/usr/sbin/sysctl -n hw.memsize)
    info=$(
      printf '[platform]\nDarwin\n[boot]\n%s\n[hostname]\n' "$boot_id"; /bin/hostname
      printf '[kernel]\n'; /usr/bin/uname -r
      printf '[architecture]\n'; /usr/bin/uname -m
      printf '[processor]\n'; /usr/sbin/sysctl -n machdep.cpu.brand_string
      printf '[cores]\n'; /usr/sbin/sysctl -n hw.physicalcpu
      printf '[threads]\n'; /usr/sbin/sysctl -n hw.logicalcpu
      printf '[os]\nPRETTY_NAME="macOS %s"\n' "$(/usr/bin/sw_vers -productVersion)"
    )
    termvia_storage() {
      /usr/sbin/ioreg -r -c IOBlockStorageDriver -l -d 2 | TERMVIA_PHYSICAL="$physical_disks" /usr/bin/awk -v kind="$1" '
        function commit() {if(dev in disks) {if(kind=="capacity" && size!="") print dev,size; else if(kind=="counters" && read!="" && write!="") print dev,read,write}}
        function number(key,row,at,tail) {at=index(row,"\"" key "\""); if(!at) return ""; tail=substr(row,at+length(key)+2); sub(/^[^=]*=[ \t]*/,"",tail); match(tail,/^[0-9]+/); return substr(tail,RSTART,RLENGTH)}
        BEGIN {n=split(ENVIRON["TERMVIA_PHYSICAL"],p,"\n"); for(i=1;i<=n;i++) disks[p[i]]=1}
        /\+-o / {commit(); dev=""; size=""; if($0 ~ /^\+-o /) {read=""; write=""}}
        /"Statistics"/ {read=number("Bytes (Read)",$0); write=number("Bytes (Write)",$0)}
        /"BSD Name"/ {split($0,q,"\""); dev=q[4]}
        {v=number("Size",$0); if(v!="") size=v}
        END {commit()}'
    }
    termvia_slow() {
      printf '[physical-network]\n%s\n[physical-disks]\n%s\n' "$physical_network" "$physical_disks"
      printf '[primary-interface]\n'; /sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/ {print $2; exit}'
      printf '[disk-layout-darwin]\n%s\n[apfs-darwin]\n' "$disk_layout"
      /usr/sbin/diskutil apfs list -plist 2>/dev/null
      printf '[capacities]\n'; termvia_storage capacity
      printf '[volumes]\n'; /bin/df -Pk -l 2>/dev/null
    }
    if [ "$sample_limit" -gt 0 ]; then set -- -c "$sample_limit"; else set --; fi
    /usr/sbin/iostat -C -U -d -n 0 -w "$sample_interval" "$@" |
    /usr/bin/awk 'NF==6 && $1 ~ /^[0-9.]+$/ && $3 ~ /^[0-9.]+$/ {if(seen++==0) print "baseline",$4,$5,$6; else print 100-$3,$4,$5,$6; fflush()}' |
    while read -r cpu load1 load5 load15; do
      changed=
      if [ "$slow_elapsed" -ge 30 ]; then
        hardware_ports=$(/usr/sbin/networksetup -listallhardwareports 2>/dev/null | /usr/bin/awk '$1=="Device:" {print $2}')
        physical_network=$(/usr/sbin/ioreg -r -c IOEthernetInterface -l -d 1 | TERMVIA_PORTS="$hardware_ports" /usr/bin/awk -F '"' 'BEGIN {n=split(ENVIRON["TERMVIA_PORTS"],p,"\n"); for(i=1;i<=n;i++) hardware[p[i]]=1} $2=="BSD Name" && hardware[$4] {print $4}')
        disk_layout=$(/usr/sbin/diskutil list -plist physical 2>/dev/null)
        physical_disks=$(printf '%s\n' "$disk_layout" | /usr/bin/plutil -extract WholeDisks xml1 -o - - 2>/dev/null | /usr/bin/awk -F '[<>]' '/<string>disk[0-9]+<\/string>/ {print $3}')
        slow=$(termvia_slow)
        if [ "$slow" != "$previous_slow" ]; then changed=$slow; previous_slow=$slow; fi
        slow_elapsed=0
      fi
      clock=$(/bin/date '+%s %z'); now=${clock%% *}
      [ "$sample_count" -ne 0 ] || counter_epoch=$now
      counter_time=$((counter_epoch + sample_count * sample_interval))
      clock_drift=$((now - counter_time))
      if [ "$clock_drift" -gt "$((sample_interval * 2))" ] || [ "$clock_drift" -lt "$((0 - sample_interval * 2))" ]; then
        counter_epoch=$((now - sample_count * sample_interval)); counter_time=$now
      fi
      printf '@termvia-begin-v2\n' || exit 0
      [ "$sample_count" -ne 0 ] || printf '%s\n' "$info"
      [ -z "$changed" ] || printf '%s\n' "$changed"
      printf '[uptime]\n%s\n[clock]\n%s\n[counter-time]\n%s\n' "$((now - boot_seconds))" "$clock" "$counter_time"
      if [ "$cpu" = baseline ]; then printf '[cpu-baseline]\n'; else printf '[cpu-percent]\n%s\n' "$cpu"; fi
      printf '[load]\n%s %s %s\n[memory]\n' "$load1" "$load5" "$load15"
      # One encoder handles all three raw tool streams, rather than forking
      # an awk process for every metric on every sample.
      {
        printf '[vm-raw]\n'; /usr/bin/vm_stat
        printf '[net-raw]\n'; /usr/sbin/netstat -ibn 2>/dev/null
        printf '[disk-raw]\n'; /usr/sbin/ioreg -r -c IOBlockStorageDriver -l -d 2
      } | TERMVIA_NETWORK="$physical_network" TERMVIA_DISKS="$physical_disks" /usr/bin/awk -v total="$memory_bytes" '
        function commit() {if(dev in disks && read!="" && write!="") print dev,read,write}
        function number(key,row,at,tail) {at=index(row,"\"" key "\""); if(!at) return ""; tail=substr(row,at+length(key)+2); sub(/^[^=]*=[ \t]*/,"",tail); match(tail,/^[0-9]+/); return substr(tail,RSTART,RLENGTH)}
        BEGIN {n=split(ENVIRON["TERMVIA_NETWORK"],p,"\n"); for(i=1;i<=n;i++) net[p[i]]=1; n=split(ENVIRON["TERMVIA_DISKS"],p,"\n"); for(i=1;i<=n;i++) disks[p[i]]=1}
        /^\[vm-raw\]$/ {section="vm"; next}
        /^\[net-raw\]$/ {if(page>0) printf "MemTotal: %.0f kB\nMemAvailable: %.0f kB\n",total/1024,available*page/1024; print "[network-compact]"; section="net"; next}
        /^\[disk-raw\]$/ {print "[disks-compact]"; section="disk"; next}
        section=="vm" {if(/page size of/) page=$8; if(/^Pages (free|inactive|speculative):/) {gsub(/\./,"",$3); available+=$3}; next}
        section=="net" {if(NF>=10 && $3 ~ /^<Link#/) {sub(/\*$/,"",$1); if($1 in net) print $1,$(NF-4),$(NF-1)}; next}
        section=="disk" {
          if(/\+-o /) {commit(); dev=""; if($0 ~ /^\+-o /) {read=""; write=""}}
          if(/"Statistics"/) {read=number("Bytes (Read)",$0); write=number("Bytes (Write)",$0)}
          if(/"BSD Name"/) {split($0,q,"\""); dev=q[4]}
        }
        END {commit()}'
      printf '@termvia-end\n' || exit 0
      sample_count=$((sample_count + 1)); if [ "$sample_limit" -gt 0 ] && [ "$sample_count" -ge "$sample_limit" ]; then break; fi
      slow_elapsed=$((slow_elapsed + sample_interval))
    done
    """#
}
