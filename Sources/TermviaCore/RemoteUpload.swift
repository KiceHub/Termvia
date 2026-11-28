import Foundation

/// Stage ordinary uploads next to their destination, then publish the whole file.
public enum RemoteUpload {
    static var unsupported: SSHError { .invalid("服务器不支持安全替换文件") }
    static func invalidTarget(_ path: String) -> SSHError { .invalid(T("目标类型不同或为符号链接：%@", path)) }
    static func destinationExists(_ path: String) -> SSHError { .invalid(T("文件已存在：%@", path)) }
    static func destinationChanged(_ path: String) -> SSHError { .invalid(T("远程目标已改变：%@", path)) }
    static func sourceChanged(_ path: String) -> SSHError { .invalid(T("本地源文件已改变：%@", path)) }
    public static func failure(_ reply: String, remote: String) -> SSHError {
        switch reply.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "termvia-upload-type": return invalidTarget(remote)
        case "termvia-upload-exists": return destinationExists(remote)
        case "termvia-upload-changed": return destinationChanged(remote)
        default: return unsupported
        }
    }

    static func stagingDirectory(for path: String) throws -> String {
        let name = (path as NSString).lastPathComponent
        guard !path.contains("\0"), !name.isEmpty, name != ".", name != "..", name != "/" else {
            throw SSHError.invalid("请输入有效的单个文件名")
        }
        return try FilePaths.child(".termvia-upload-" + UUID().uuidString, in: (path as NSString).deletingLastPathComponent)
    }

    public static func scpCommand(remote: String, overwrite: Bool) throws -> String {
        command(remote: remote, directory: try stagingDirectory(for: remote), mode: "scp", value: overwrite ? "yes" : "no")
    }

    /// SFTP carries the file bytes. An SSH command checks the original
    /// version and preserves metadata the SFTP v3 attributes cannot express.
    public struct Overwrite: Sendable {
        public let directory: String
        private let remote: String

        public init(remote: String) throws {
            self.remote = remote
            directory = try RemoteUpload.stagingDirectory(for: remote)
        }

        public var inspectCommand: String {
            RemoteUpload.command(remote: remote, directory: directory, mode: "inspect")
        }

        public func publishCommand(version: String) -> String {
            RemoteUpload.command(remote: remote, directory: directory, mode: "publish", value: version)
        }
    }

    private static func command(remote: String, directory: String, mode: String, value: String = "") -> String {
        let path = remote as NSString
        let arguments = [path.deletingLastPathComponent, "./" + path.lastPathComponent,
                         "./" + (directory as NSString).lastPathComponent, mode, value]
        return "LC_ALL=C /bin/sh -c " + SSHRoute.shellQuote(script) + " termvia-upload "
            + arguments.map(SSHRoute.shellQuote).joined(separator: " ")
    }

    private static let script = #"""
    set -f
    PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
    unset COPYFILE_DISABLE
    parent=$1 target=$2 directory=$3 operation=$4 value=$5
    stage=$directory/file
    fail() { if [ "$operation" = scp ]; then printf '\002'; fi; printf 'termvia-upload-%s\n' "$1"; exit 1; }
    cd "$parent" || fail unavailable
    case "$(uname -s)" in
      Darwin)
        [ -x /usr/bin/perl ] || fail unavailable
        version() { stat -f '%d:%i:%p:%l:%u:%g:%z:%.9Fm:%.9Fc' "$1"; }
        metadata() { stat -f '%Lp:%u:%g' "$1"; }
        eligible() { [ "$(stat -f '%l:%f' "$target")" = '1:0' ]; }
        copy_metadata() {
          /usr/bin/ruby -rfiddle/import -e '
            module Native
              extend Fiddle::Importer
              dlload Fiddle.dlopen(nil)
              extern "int copyfile(const char *, const char *, void *, unsigned int)"
            end
            exit(Native.copyfile(ARGV[0], ARGV[1], nil, 7 | (1 << 18) | (1 << 19)) == 0 ? 0 : 1)' "$target" "$stage"
        }
        metadata_matches() {
          xattr -lx "$target" > "$directory/source-xattr" && xattr -lx "$stage" > "$directory/stage-xattr" &&
            cmp -s "$directory/source-xattr" "$directory/stage-xattr" || return 1
          old=$(ls -ledb "$target") && new=$(ls -ledb "$stage") || return 1
          [ "$(printf '%s\n' "$old" | sed '1d')" = "$(printf '%s\n' "$new" | sed '1d')" ]
        }
        replace() { /usr/bin/perl -e 'exit(rename($ARGV[0], $ARGV[1]) ? 0 : 1)' "$stage" "$target"; }
        create() { /usr/bin/perl -e 'exit(link($ARGV[0], $ARGV[1]) ? 0 : 1)' "$stage" "$target"; }
        clear_inherited_access() { chmod -N "$directory"; }
        private_directory() { [ "$(stat -f '%Lp' "$directory")" = 700 ]; }
        ;;
      Linux)
        version() { stat -c '%d:%i:%f:%h:%u:%g:%s:%y:%z' -- "$1"; }
        metadata() { stat -c '%a:%u:%g' -- "$1"; }
        eligible() {
          [ "$(stat -c '%h' -- "$target")" = 1 ] && command -v python3 >/dev/null 2>&1 || return 1
          flags=$(lsattr -d -- "$target") || return 1
          case "${flags%% *}" in ''|*[!e-]*) return 1 ;; esac
        }
        copy_metadata() { cp --attributes-only --preserve=mode,ownership,xattr -- "$target" "$stage"; }
        metadata_matches() {
          python3 -c 'import os, sys
    def attrs(path):
        return {name: os.getxattr(path, name, follow_symlinks=False)
                for name in os.listxattr(path, follow_symlinks=False)}
    source, staging = map(attrs, sys.argv[1:])
    raise SystemExit(source != staging or "security.capability" in source)' "$target" "$stage"
        }
        replace() { python3 -c 'import os, sys; os.replace(sys.argv[1], sys.argv[2])' "$stage" "$target"; }
        create() { ln -T -- "$stage" "$target"; }
        # The group permission bits mask named entries in a Linux POSIX ACL.
        clear_inherited_access() { :; }
        private_directory() { [ "$(stat -c '%a' -- "$directory")" = 700 ]; }
        ;;
      *) fail unavailable ;;
    esac
    exists() { [ -e "$target" ] || [ -L "$target" ]; }
    regular_target() { [ -f "$target" ] && [ ! -L "$target" ]; }
    inspect_target() {
      regular_target || fail type
      [ -w "$target" ] && eligible || fail unavailable
      original=$(version "$target") && saved=$(metadata "$target") || fail unavailable
      case "${saved%%:*}" in [0-7]|[0-7][0-7]|[0-7][0-7][0-7]) ;; *) fail unavailable ;; esac
    }
    cleanup() { rm -f "$stage" "$directory/source-xattr" "$directory/stage-xattr"; rmdir "$directory"; }
    prepare_stage() {
      mkdir -m 700 "$directory" || fail unavailable
      trap cleanup EXIT
      trap 'exit 1' HUP INT TERM
      clear_inherited_access && private_directory || fail unavailable
    }
    publish() {
      [ "$parent" -ef . ] && [ -f "$stage" ] && [ ! -L "$stage" ] && [ -O "$stage" ] || fail unavailable
      regular_target && [ "$original" = "$(version "$target")" ] || fail changed
      copy_metadata && metadata_matches && touch -m "$stage" &&
        [ "$saved" = "$(metadata "$stage")" ] || fail unavailable
      regular_target && [ "$original" = "$(version "$target")" ] || fail changed
      replace || fail unavailable
    }
    case "$operation" in
      inspect)
        inspect_target
        prepare_stage
        printf '%s\n' "$original" || exit 1
        trap - EXIT
        exit 0 ;;
      publish)
        [ -d "$directory" ] && [ ! -L "$directory" ] && [ -O "$directory" ] && private_directory || fail unavailable
        trap cleanup EXIT
        trap 'exit 1' HUP INT TERM
        inspect_target
        [ "$value" = "$original" ] || fail changed
        publish
        exit 0 ;;
      scp) ;;
      *) fail unavailable ;;
    esac
    original=
    if exists; then
      regular_target || fail type
      [ "$value" = yes ] || fail exists
      inspect_target
    fi
    prepare_stage
    scp -t -- "$stage" || exit 1
    IFS= read -r decision && [ "$decision" = commit ] || exit 1
    [ "$parent" -ef . ] && [ -f "$stage" ] && [ ! -L "$stage" ] || fail unavailable
    if [ -n "$original" ]; then
      publish
    else
      if exists; then fail changed; fi
      create || { if exists; then fail changed; fi; fail unavailable; }
    fi
    printf '\000'
    """#
}
