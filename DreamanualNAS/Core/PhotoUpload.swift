import Foundation
import ImageIO

/// 照片上传的落点规则：按拍摄时间归到 `/photo/YYYY/MM`。
///
/// 为什么路径要客户端算（规划第六节第 3 条）：`Upload.Item` 的参数形态六轮没探通，
/// 走的是 `FileStation.Upload`，它只认一个 `path` —— 「按拍摄日期建文件夹」是
/// Photos 自己那条上传通道的行为，这条路没有，只能自己算。
///
/// 拍摄时间取 EXIF `DateTimeOriginal`（读不到回落文件修改时间）。早于 2000 年
/// 或在未来的值一律当异常回落当前月 —— 相机时间没设对时，把一整套照片甩进 1970 年
/// 比放进当月更难收。
enum PhotoUpload {
    /// 一个落点月。
    struct Month: Equatable {
        /// 相对照片库根的路径，如 `/photo/2026/10`。
        let path: String
        let count: Int
    }

    /// 拖入遮罩上那两句话。
    struct Summary: Equatable {
        let count: Int
        /// 按年月倒序（新的在前）。
        let months: [Month]

        var headline: String {
            count > 0 ? "松手即上传 \(count) 张" : "松手即上传照片"
        }

        /// 落点两态（2026-10-19 定）：同批同月给具体路径；跨月不写一个路径 ——
        /// 那是说谎 —— 写「按拍摄时间归类」加分月计数。
        var detail: String {
            guard let first = months.first else { return "" }
            if months.count == 1 {
                return "按拍摄时间归到 \(Self.display(first.path))"
            }
            let shown = months.prefix(3).map { "\(Self.display($0.path)) ×\($0.count)" }
            let rest = months.count > 3 ? " 等 \(months.count) 个月" : ""
            return "按拍摄时间归类：" + shown.joined(separator: " · ") + rest
        }

        /// `/photo/2026/10` → `2026/10`。
        static func display(_ path: String) -> String {
            path.hasPrefix("/photo/") ? String(path.dropFirst("/photo/".count)) : path
        }
    }

    /// 一批文件摊成上传项：每张各自算落点，跨月的一批会落到多个目录。
    ///
    /// 拖进来的文件夹直接略过 —— 照片库的归类靠拍摄日期，用户拖的目录名在这里没有
    /// 意义（要按目录搬东西走文件管理）。
    static func plan(urls: [URL]) -> [UploadQueue.Item] {
        urls.compactMap { url in
            guard !isDirectory(url) else { return nil }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            return UploadQueue.Item(
                localURL: url,
                name: url.lastPathComponent,
                directory: monthPath(for: captureDate(of: url)),
                isDirectory: false,
                byteCount: size
            )
        }
    }

    /// 拖入遮罩要写的摘要。要读每张的 EXIF，所以只在拖入的内容变化时算一次。
    static func summary(urls: [URL]) -> Summary {
        var counts: [String: Int] = [:]
        for url in urls where !isDirectory(url) {
            counts[monthPath(for: captureDate(of: url)), default: 0] += 1
        }
        // 路径补过零，字典序倒序就是年月倒序。
        let months = counts.keys.sorted(by: >).map { Month(path: $0, count: counts[$0] ?? 0) }
        return Summary(count: counts.values.reduce(0, +), months: months)
    }

    /// 一批文件的本机小图：文件名 → JPEG 字节。网格在服务端缩略图生成好之前拿它顶上。
    ///
    /// **只做图片。** 视频取首帧要解码整段，拖一批视频进来会把上传前的等待拉长；
    /// 视频那张图交给服务端（它生成得快，而且本来就是从原片抽的）。
    static func previews(urls: [URL], maxPixel: Int = 480) -> [String: Data] {
        var result: [String: Data] = [:]
        for url in urls where !isDirectory(url) {
            guard let data = previewData(of: url, maxPixel: maxPixel) else { continue }
            result[url.lastPathComponent] = data
        }
        return result
    }

    /// 降采样一张图并编码成 JPEG（质量 0.82，480 长边约 40–80 KB）。
    /// ImageIO 只解到目标尺寸，不把整张原图读进内存 —— 一张 100 MP 的 HEIC 也不会爆。
    static func previewData(of url: URL, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// 拍摄时间 → `/photo/YYYY/MM`。按本地日历 —— EXIF 里存的就是相机墙上时间。
    static func monthPath(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "/photo/%04d/%02d", parts.year ?? 2000, parts.month ?? 1)
    }

    /// 拍摄时间：EXIF → TIFF 时间 → 文件修改时间 → 当前时间。
    static func captureDate(of url: URL) -> Date {
        if let text = exifDateText(of: url),
           let date = exifFormatter.date(from: text),
           isSane(date) {
            return date
        }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        return isSane(modified) ? modified : Date()
    }

    private static func exifDateText(of url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            return text
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let text = tiff[kCGImagePropertyTIFFDateTime] as? String {
            return text
        }
        return nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// 相机时间没设对时会给出 1970、2038 一类的值。容忍「明天」—— 时区差一天是正常的。
    private static func isSane(_ date: Date) -> Bool {
        date >= Date(timeIntervalSince1970: 946_684_800)          // 2000-01-01
            && date <= Date().addingTimeInterval(86_400)
    }

    private static let exifFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter
    }()
}
