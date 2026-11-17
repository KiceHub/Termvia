import TermviaCore
extension SFTPOperation {
    var title: String {
        switch self {
        case .uploadFile: return "上传"
        case .downloadFile: return "下载"
        case .list: return "读取目录"
        case .makeDirectory: return "新建文件夹"
        case .makeFile: return "新建文件"
        case .copyFile: return "复制"
        case .rename: return "移动/重命名"
        case .removeFile, .removeDirectory, .removeTree: return "删除"
        case .batch: return "文件操作"
        }
    }
    var sourcePaths: [String] {
        switch self {
        case .copyFile(let source, _), .rename(let source, _), .removeFile(let source), .removeTree(let source), .removeDirectory(let source): return [source]
        case .batch(let items): return items.flatMap(\.sourcePaths)
        default: return []
        }
    }
    var displayPath: String {
        switch self {
        case .list(let path), .makeDirectory(let path), .makeFile(let path), .removeFile(let path), .removeDirectory(let path), .removeTree(let path): return path
        case .copyFile(let a, let b), .rename(let a, let b): return a + " → " + b
        case .uploadFile(let a, let b), .downloadFile(let a, let b): return a + " → " + b
        case .batch(let items): return items.map(\.displayPath).joined(separator: "\n")
        }
    }
}
