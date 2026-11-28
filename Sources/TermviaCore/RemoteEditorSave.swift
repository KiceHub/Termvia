import CryptoKit
import Foundation

/// The file browser may use SFTP alone. Editing requires an SSH exec channel
/// that can verify metadata and publish a complete replacement beside the target.
public enum RemoteEditorSave {
    public static let writableReply = "termvia-editor-writable-v1"

    public struct Request: Sendable {
        public let command: String
        public let input: Data
    }

    public enum RecoveryFailure: LocalizedError {
        case preserved(String)
        case unconfirmed(String)

        public var errorDescription: String? {
            switch self {
            case .preserved(let path): return T("远程文件保存冲突，原文件保留在 %@。请先另存本地副本。", path)
            case .unconfirmed(let path): return T("未能确认远程文件是否已保存。如果原路径缺少文件，请检查 %@。", path)
            }
        }
    }

    public static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func probe(remote: String) throws -> Request {
        try request(remote: remote, size: 0, expectedDigest: "", mode: "probe")
    }

    public static func upload(remote: String, size: UInt64, expectedDigest: String) throws -> Request {
        guard size <= EditorFileInspection.editorLimit, expectedDigest.utf8.count == 64,
              expectedDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw SFTPFailure.malformed
        }
        return try request(remote: remote, size: size, expectedDigest: expectedDigest, mode: "transfer")
    }

    private static func request(remote: String, size: UInt64, expectedDigest: String, mode: String) throws -> Request {
        guard remote.hasPrefix("/"), !remote.contains("\0"), !(remote as NSString).lastPathComponent.isEmpty else {
            throw SSHError.invalid("本地和远程路径必须是绝对路径")
        }
        let path = remote as NSString
        let script = Data((helpers + "\n" + commitScript + "\n" + transferScript).utf8)
        let variables = [
            ("TV_EDITOR_PARENT", path.deletingLastPathComponent),
            ("TV_EDITOR_TARGET", "./" + path.lastPathComponent),
            ("TV_EDITOR_STAGE", "./.termvia-editor-" + UUID().uuidString),
            ("TV_EDITOR_LIMIT", String(EditorFileInspection.editorLimit)),
            ("TV_EDITOR_SIZE", String(size)),
            ("TV_EDITOR_DIGEST", expectedDigest),
        ]
        let environment = variables.map { "\($0.0)=\(SSHRoute.shellQuote($0.1))" }.joined(separator: " ")
        let launch = #"PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH; IFS= read -r n && TV_EDITOR_SCRIPT=$(head -c "$n") && export TV_EDITOR_SCRIPT && exec /bin/sh -c "$TV_EDITOR_SCRIPT" termvia-editor "$1""#
        let command = "LC_ALL=C " + environment + " /bin/sh -c " + SSHRoute.shellQuote(launch) + " termvia-editor " + mode
        // Read the script before the first reply. File bytes and the commit decision
        // follow only after the server has consumed exactly this prefix.
        return Request(command: command, input: Data("\(script.count)\n".utf8) + script)
    }

    private static let helpers = #"""
    PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
    unset COPYFILE_DISABLE
    parent=$TV_EDITOR_PARENT target=$TV_EDITOR_TARGET stage=$TV_EDITOR_STAGE
    staged=$stage/previous
    limit=$TV_EDITOR_LIMIT size=$TV_EDITOR_SIZE expected=$TV_EDITOR_DIGEST
    mode=$1
    umask 077
    readonly_target() { [ "$mode" = probe ] || printf 'R'; exit 1; }
    changed() { printf 'C'; exit 1; }
    case "$(uname -s)" in
      Darwin)
        stat_size() { stat -f '%z' "$1"; }
        stat_identity() { stat -f '%d:%i' "$1"; }
        stat_version() { stat -f '%d:%i:%p:%l:%u:%g:%f:%z:%m:%c' "$1"; }
        stat_moved() { stat -f '%d:%i:%p:%l:%u:%g:%f:%z:%.9Fm' "$1"; }
        stat_metadata() { stat -f '%p:%u:%g:%f' "$1"; }
        eligible() {
          [ "$(stat -f '%l:%f' "$target")" = '1:0' ] || return 1
          permissions=$(stat -f '%p' "$target") || return 1
          case "$permissions" in 100[0-7][0-7][0-7]) return 0 ;; *) return 1 ;; esac
        }
        hash_file() {
          /usr/bin/perl -MDigest::SHA -MFcntl=:DEFAULT,:mode -e '
            sysopen(my $file, $ARGV[0], O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or exit 1;
            my @info = stat($file);
            @info && S_ISREG($info[2]) or exit 1;
            my $sha = Digest::SHA->new(256);
            my $size = 0;
            while (1) {
                my $count = sysread($file, my $bytes, 65536);
                defined($count) or exit 1;
                last if $count == 0;
                $size += $count;
                $size <= $ARGV[1] or exit 1;
                $sha->add($bytes);
            }
            print $sha->hexdigest;' "$target" "$limit"
        }
        private_stage() { chmod -N "$stage"; }
        copy_target() { cp -Pp "$target" "$staged"; }
        compare_attributes() {
          xattr -lx "$target" > "$stage/source-xattr" && xattr -lx "$staged" > "$stage/stage-xattr" &&
            cmp -s "$stage/source-xattr" "$stage/stage-xattr" && [ ! -e "$stage/._previous" ] || return 1
          old=$(ls -ledb "$target") && new=$(ls -ledb "$staged") || return 1
          [ "$(printf '%s\n' "$old" | sed '1d')" = "$(printf '%s\n' "$new" | sed '1d')" ]
        }
        exchange() {
          /usr/bin/ruby -rfiddle/import -e '
            module Native
              extend Fiddle::Importer
              dlload Fiddle.dlopen(nil)
              extern "int renamex_np(const char *, const char *, unsigned int)"
            end
            exit(Native.renamex_np(ARGV[0], ARGV[1], 2) == 0 ? 0 : 1)' "$1" "$2"
        }
        with_commit_lock() {
          /usr/bin/perl -MFcntl=:flock,F_SETFD -MTime::HiRes=sleep -e '
            open(my $dir, "<", ".") or exit 1;
            my $remaining = 60;
            while (!flock($dir, LOCK_EX | LOCK_NB)) {
                --$remaining > 0 or exit 1;
                sleep(0.05);
            }
            fcntl($dir, F_SETFD, 0) or exit 1;
            exec {"/bin/sh"} "sh", "-c", $ENV{TV_EDITOR_SCRIPT}, "termvia-editor", @ARGV;' "$@"
        }
        ;;
      Linux)
        stat_size() { stat -c '%s' "$1"; }
        stat_identity() { stat -c '%d:%i' "$1"; }
        stat_version() { stat -c '%d:%i:%f:%h:%u:%g:%s:%y:%z' "$1"; }
        stat_moved() { stat -c '%d:%i:%f:%h:%u:%g:%s:%y' "$1"; }
        stat_metadata() { stat -c '%f:%u:%g' "$1"; }
        eligible() {
          [ "$(stat -c '%h' "$target")" = 1 ] || return 1
          permissions=$(stat -c '%a' "$target") && ordinary_mode "$permissions" || return 1
          flags=$(lsattr -d "$target") || return 1
          case "${flags%% *}" in ''|*[!e-]*) return 1 ;; esac
        }
        hash_file() {
          python3 -c 'import hashlib, os, stat, sys
    path, limit = sys.argv[1], int(sys.argv[2])
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        raise SystemExit(1)
    digest = hashlib.sha256()
    with os.fdopen(fd, "rb", buffering=0) as file:
        size = 0
        while True:
            data = file.read(65536)
            if not data:
                break
            size += len(data)
            if size > limit:
                raise SystemExit(1)
            digest.update(data)
    print(digest.hexdigest())' "$target" "$limit"
        }
        private_stage() {
          python3 -c 'import os, sys
    path = sys.argv[1]
    for name in os.listxattr(path):
        if name in ("system.posix_acl_access", "system.posix_acl_default"):
            os.removexattr(path, name)
        elif "acl" in name:
            raise SystemExit(1)' "$stage"
        }
        copy_target() { cp -P --preserve=mode,ownership,xattr -- "$target" "$staged"; }
        compare_attributes() {
          python3 -c 'import os, sys
    def attributes(path):
        return {name: os.getxattr(path, name, follow_symlinks=False)
                for name in os.listxattr(path, follow_symlinks=False)}
    original, staged = (attributes(path) for path in sys.argv[1:])
    raise SystemExit(original != staged or "security.capability" in original)' "$target" "$staged"
        }
        exchange() {
          python3 -c 'import ctypes, os, sys
    rename = ctypes.CDLL(None).renameat2
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    raise SystemExit(rename(-100, os.fsencode(sys.argv[1]), -100, os.fsencode(sys.argv[2]), 2) != 0)' "$1" "$2"
        }
        with_commit_lock() {
          python3 -c 'import fcntl, os, sys, time
    try:
        fd = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
        os.set_inheritable(fd, True)
    except OSError:
        raise SystemExit(1)
    for _ in range(60):
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            time.sleep(0.05)
    else:
        raise SystemExit(1)
    os.execv("/bin/sh", ["sh", "-c", os.environ["TV_EDITOR_SCRIPT"], "termvia-editor"] + sys.argv[1:])' "$@"
        }
        ;;
      *) readonly_target ;;
    esac

    normal_file() { [ ! -L "$target" ] && [ -f "$target" ]; }
    ordinary_mode() {
      case "$1" in [0-7]|[0-7][0-7]|[0-7][0-7][0-7]) return 0 ;; *) return 1 ;; esac
    }
    compare_metadata() {
      original=$(stat_metadata "$target") && replacement=$(stat_metadata "$staged") &&
        [ "$original" = "$replacement" ] && compare_attributes
    }
    within_limit() {
      actual_size=$(stat_size "$target") && [ "$actual_size" -le "$limit" ] || return 1
    }
    matching_digest() {
      within_limit || return 1
      hash=$(hash_file) && [ "$hash" = "$expected" ]
    }

    has_recovery() {
      [ -n "${draft_identity:-}" ] && { [ -e "$staged" ] || [ -L "$staged" ]; } &&
        [ "$(stat_identity "$staged")" != "$draft_identity" ]
    }

    check_recovery_limit() {
      count=0
      for folder in ./.termvia-editor-*; do
        [ "$folder" != "$stage" ] && [ -d "$folder" ] && [ ! -L "$folder" ] || continue
        [ -e "$folder/previous" ] || [ -L "$folder/previous" ] || continue
        count=$((count + 1))
        if [ "$count" -ge 64 ]; then printf 'B'; exit 1; fi
      done
    }
    """#

    private static let transferScript = #"""
    cd "$parent" || readonly_target
    if [ "$mode" = transfer ]; then
      normal_file && version=$(stat_version "$target") && matching_digest &&
        [ "$version" = "$(stat_version "$target")" ] || changed
    fi
    normal_file && [ -r "$target" ] && [ -w "$target" ] && eligible && within_limit || readonly_target
    # A directory's sticky bit can prevent replacement despite permission to create siblings.
    if [ -k . ] && [ ! -O . ] && [ ! -O "$target" ]; then readonly_target; fi
    mkdir -m 700 "$stage" || readonly_target
    cleanup() {
      # If the transport interrupted an in-flight commit, only the locked
      # process knows whether the staging name still holds a disposable draft.
      [ "${committing:-}" != 1 ] || return 0
      rm -f "$stage/._previous" "$stage/source-xattr" "$stage/stage-xattr" "$stage/test"
      # After exchange this name holds the old inode, including any writes
      # that still reach it through an already-open file descriptor.
      if has_recovery; then return 0; fi
      rm -f "$staged" && rmdir "$stage"
    }
    trap cleanup EXIT
    trap 'exit 1' HUP INT TERM
    # Bound disk use if a writer grows the source between stat and cp.
    private_stage && (ulimit -f "$((limit / 512))" && copy_target) &&
      [ ! -L "$staged" ] && [ -w "$staged" ] && [ "$(stat_size "$staged")" -le "$limit" ] &&
      compare_metadata || readonly_target
    if [ "$mode" = probe ]; then
      with_commit_lock lock-test || exit 1
      printf '%s\n' 'termvia-editor-writable-v1'
      exit 0
    fi

    draft_identity=$(stat_identity "$staged") || readonly_target
    printf '\000%s\n' "${stage#./}/previous"
    head -c "$size" > "$staged" || exit 1
    [ "$(stat_size "$staged")" -eq "$size" ] || exit 1
    printf '\000'
    IFS= read -r decision && [ "$decision" = commit ] || exit 1
    # Directory identity survives rename and also coordinates aliases of the path.
    # The OS releases the advisory lock automatically when the commit shell exits.
    committing=1
    result=$(with_commit_lock commit "$version")
    status=$?
    committing=0
    if cleanup; then trap - EXIT; fi
    if [ "$status" -ne 0 ]; then
      if has_recovery; then printf 'P'
      else case "$result" in B|C) printf '%s' "$result" ;; *) printf 'R' ;; esac; fi
      exit 1
    fi
    printf '\000'
    """#

    private static let commitScript = #"""
    case "$mode" in
      lock-test)
        : > "$stage/test" && exchange "$staged" "$stage/test" || exit 1
        exit 0 ;;
      commit)
        version=$2
        normal_file && [ "$parent" -ef . ] && [ "$version" = "$(stat_version "$target")" ] && matching_digest || changed
        [ -w "$target" ] && eligible && compare_metadata || readonly_target
        check_recovery_limit
        destination=$target
        draft=$(stat_moved "$staged") && previous=$(stat_moved "$destination") &&
          [ "$version" = "$(stat_version "$destination")" ] || changed
        # The original pathname remains present even if the session ends just
        # after the exchange. The old entry is already at the recovery path.
        if ! exchange "$staged" "$destination"; then
          [ "$version" = "$(stat_version "$destination")" ] || changed
          readonly_target
        fi
        target=$staged staged=$destination
        if normal_file && [ "$previous" = "$(stat_moved "$target")" ] && matching_digest &&
           eligible && compare_metadata && [ "$previous" = "$(stat_moved "$target")" ]; then
          exit 0
        fi
        # A process outside the directory lock may have raced the exchange.
        # Restore only while our draft still occupies the original pathname.
        # An exchange preserves both entries even if another write races this check.
        if [ "$draft" = "$(stat_moved "$destination")" ]; then
          exchange "$target" "$destination" && [ "$draft" = "$(stat_moved "$target")" ] && changed
        fi
        exit 1 ;;
    esac
    """#
}
