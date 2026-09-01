import AppKit
import SwiftUI

final class AppIconCache {
    static let shared = AppIconCache()
    private let cache = NSCache<NSString, NSImage>()
    private let pending = NSLock()
    private var completions: [String: [(NSImage) -> Void]] = [:]

    private init() { cache.countLimit = 160 }

    func cachedIcon(for path: String) -> NSImage? {
        cache.object(forKey: path as NSString)
    }

    func load(path: String, completion: @escaping (NSImage) -> Void) {
        if let image = cachedIcon(for: path) {
            completion(image)
            return
        }
        pending.lock()
        let shouldLoad = completions[path] == nil
        completions[path, default: []].append(completion)
        pending.unlock()
        guard shouldLoad else { return }

        // NSWorkspace resolves bundle icons through Launch Services. It must
        // run on the main thread to avoid generic fallback artwork for some
        // app bundles, but it is only invoked for visible icons and cached.
        DispatchQueue.main.async { [weak self] in
            let image = NSWorkspace.shared.icon(forFile: path)
            image.size = NSSize(width: 128, height: 128)
            self?.cache.setObject(image, forKey: path as NSString)
            self?.pending.lock()
            let callbacks = self?.completions.removeValue(forKey: path) ?? []
            self?.pending.unlock()
            callbacks.forEach { $0(image) }
        }
    }
}

struct CachedAppIcon: View {
    let path: String
    let size: CGFloat
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.medium)
            } else {
                Image(systemName: "app.dashed")
                    .resizable().scaledToFit().padding(size * 0.14)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: path) {
            if let cached = AppIconCache.shared.cachedIcon(for: path) {
                icon = cached
            } else {
                AppIconCache.shared.load(path: path) { icon = $0 }
            }
        }
    }
}
