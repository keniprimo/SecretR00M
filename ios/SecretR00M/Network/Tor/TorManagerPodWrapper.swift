import Foundation

// NOTE: These classes are no longer used. TorManager.swift now uses raw Tor.framework
// (TorThread + TorController) directly, bypassing the TorManager pod entirely.
// This file is kept to avoid Xcode project file changes but can be safely deleted.

#if !targetEnvironment(simulator)
import TorManager
import Tor

/// Subclass of TorManager (pod) that adds torrc options optimized for onion-service-only usage.
///
/// Problem: The default TorManager configuration causes Tor to download the full relay directory
/// which requires connecting to many relay nodes to fetch microdescriptors. On slow mobile
/// connections through bridges, this can take a long time and some relay connections fail
/// with TLS handshake errors, causing bootstrap to stall at 50% ("loading relay descriptors").
///
/// The iOS Tor build reports "Libzstd N/A" — Zstandard compression is not available.
/// Relay nodes serving Zstandard-compressed directory data will cause decompression failures
/// (matching the server-side "compression bomb" errors). This further slows descriptor fetching.
///
/// Fix: Add torrc options that:
/// 1. Use microdescriptors (compact format, less data to download)
/// 2. Let Tor learn appropriate timeouts for this device/network
/// 3. Set connection padding to reduce fingerprinting
final class OnionServiceTorManager: TorManager {

    override func createTorConf(_ bypassPort: UInt16?) -> TorConfiguration {
        let conf = super.createTorConf(bypassPort)

        let onionOptions: [String: String] = [
            // Use compact microdescriptors instead of full server descriptors.
            // This is usually the default, but we set it explicitly.
            "UseMicrodescriptors": "1",

            // Let Tor learn appropriate circuit build timeouts for this
            // device/network combination, rather than using hardcoded defaults.
            "LearnCircuitBuildTimeout": "1",

            // Enable connection padding for onion service traffic.
            "ConnectionPadding": "1",
        ]

        conf.options.addEntries(from: onionOptions)

        return conf
    }
}

/// Wrapper to hold the TorManager pod instance
/// Uses OnionServiceTorManager subclass to add torrc options for onion-service-only usage
final class TorManagerPodWrapper {
    let instance: TorManager

    init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let torDir = cacheDir.appendingPathComponent("tor", isDirectory: true)
        instance = OnionServiceTorManager(directory: torDir)
    }
}
#endif
