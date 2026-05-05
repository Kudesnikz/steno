import CoreAudio
import Foundation

public struct SystemInputVolumeState: Equatable, Sendable {
    public var volume: Double
    public var isAvailable: Bool
    public var isSettable: Bool
    public var deviceName: String?

    public init(
        volume: Double = 0,
        isAvailable: Bool = false,
        isSettable: Bool = false,
        deviceName: String? = nil
    ) {
        self.volume = min(1, max(0, volume))
        self.isAvailable = isAvailable
        self.isSettable = isSettable
        self.deviceName = deviceName
    }
}

public enum SystemInputVolumeError: LocalizedError, Sendable {
    case noInputDevice
    case inputVolumeUnavailable
    case inputVolumeNotSettable
    case setFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .noInputDevice:
            "No default input device is available."
        case .inputVolumeUnavailable:
            "The default input device does not expose input volume."
        case .inputVolumeNotSettable:
            "The default input device input volume is not writable."
        case let .setFailed(status):
            "Failed to set system input volume: \(status)."
        }
    }
}

public final class SystemInputVolumeService: @unchecked Sendable {
    public typealias UpdateHandler = @MainActor @Sendable (SystemInputVolumeState) -> Void

    private let lock = NSLock()
    private var updateHandler: UpdateHandler?
    private var isMonitoring = false
    private var observedDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var observedVolumeAddresses: [AudioObjectPropertyAddress] = []

    public init() {}

    deinit {
        stopMonitoring()
    }

    public func startMonitoring(_ handler: @escaping UpdateHandler) {
        lock.withLock {
            updateHandler = handler
            guard !isMonitoring else {
                return
            }
            isMonitoring = true
        }

        addDefaultInputDeviceListener()
        refreshObservedInputDevice()
        notifyStateChanged()
    }

    public func stopMonitoring() {
        let shouldStop = lock.withLock { () -> Bool in
            guard isMonitoring else {
                return false
            }
            isMonitoring = false
            updateHandler = nil
            return true
        }
        guard shouldStop else {
            return
        }

        removeDefaultInputDeviceListener()
        removeVolumeListeners()
    }

    public func currentState() -> SystemInputVolumeState {
        guard let deviceID = defaultInputDeviceID() else {
            return SystemInputVolumeState()
        }
        let channels = readableVolumeChannels(deviceID: deviceID)
        let volume = channels.compactMap { readVolume(deviceID: deviceID, element: $0) }.average
        return SystemInputVolumeState(
            volume: volume ?? 0,
            isAvailable: volume != nil,
            isSettable: channels.contains { isVolumeSettable(deviceID: deviceID, element: $0) },
            deviceName: deviceName(deviceID: deviceID)
        )
    }

    public func setVolume(_ value: Double) throws {
        guard let deviceID = defaultInputDeviceID() else {
            throw SystemInputVolumeError.noInputDevice
        }

        let channels = readableVolumeChannels(deviceID: deviceID)
        guard !channels.isEmpty else {
            throw SystemInputVolumeError.inputVolumeUnavailable
        }

        let settableChannels = channels.filter { isVolumeSettable(deviceID: deviceID, element: $0) }
        guard !settableChannels.isEmpty else {
            throw SystemInputVolumeError.inputVolumeNotSettable
        }

        let clamped = Float32(min(1, max(0, value)))
        for element in settableChannels {
            var address = volumeAddress(element: element)
            var mutableValue = clamped
            let status = AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &mutableValue
            )
            guard status == noErr else {
                throw SystemInputVolumeError.setFailed(status)
            }
        }
        notifyStateChanged()
    }

    private func refreshObservedInputDevice() {
        let nextDeviceID = defaultInputDeviceID() ?? AudioObjectID(kAudioObjectUnknown)
        let previousDeviceID = lock.withLock { observedDeviceID }
        guard previousDeviceID != nextDeviceID else {
            return
        }

        removeVolumeListeners()
        lock.withLock {
            observedDeviceID = nextDeviceID
        }
        addVolumeListeners(deviceID: nextDeviceID)
    }

    private func addDefaultInputDeviceListener() {
        var address = Self.defaultInputDeviceAddress
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            Self.propertyListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if status != noErr {
            AppLog.warning("Default input device listener unavailable status=\(status)", category: .app)
        }
    }

    private func removeDefaultInputDeviceListener() {
        var address = Self.defaultInputDeviceAddress
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            Self.propertyListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func addVolumeListeners(deviceID: AudioObjectID) {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return
        }

        let addresses = readableVolumeChannels(deviceID: deviceID).map(volumeAddress(element:))
        for var address in addresses {
            let status = AudioObjectAddPropertyListener(
                deviceID,
                &address,
                Self.propertyListener,
                Unmanaged.passUnretained(self).toOpaque()
            )
            if status != noErr {
                AppLog.debug("Input volume listener unavailable status=\(status)", category: .app)
            }
        }
        lock.withLock {
            observedVolumeAddresses = addresses
        }
    }

    private func removeVolumeListeners() {
        let snapshot = lock.withLock {
            (deviceID: observedDeviceID, addresses: observedVolumeAddresses)
        }
        guard snapshot.deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return
        }

        for var address in snapshot.addresses {
            AudioObjectRemovePropertyListener(
                snapshot.deviceID,
                &address,
                Self.propertyListener,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
        lock.withLock {
            observedVolumeAddresses = []
        }
    }

    private func handleAudioPropertyChanged() {
        refreshObservedInputDevice()
        notifyStateChanged()
    }

    private func notifyStateChanged() {
        let state = currentState()
        let handler = lock.withLock { updateHandler }
        guard let handler else {
            return
        }
        Task { @MainActor in
            handler(state)
        }
    }

    private func defaultInputDeviceID() -> AudioObjectID? {
        var address = Self.defaultInputDeviceAddress
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }
        return deviceID
    }

    private func readableVolumeChannels(deviceID: AudioObjectID) -> [AudioObjectPropertyElement] {
        let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain] + (1...32).map(AudioObjectPropertyElement.init)
        return elements.filter { element in
            var address = volumeAddress(element: element)
            return AudioObjectHasProperty(deviceID, &address) &&
                readVolume(deviceID: deviceID, element: element) != nil
        }
    }

    private func readVolume(deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Double? {
        var address = volumeAddress(element: element)
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else {
            return nil
        }
        return Double(min(1, max(0, volume)))
    }

    private func isVolumeSettable(deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Bool {
        var address = volumeAddress(element: element)
        var isSettable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        return status == noErr && isSettable.boolValue
    }

    private func deviceName(deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr, size >= UInt32(MemoryLayout<CFString>.size) else {
            return nil
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<CFString>.alignment
        )
        defer {
            storage.deallocate()
        }

        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, storage)
        guard status == noErr else {
            return nil
        }
        let name = storage.load(as: CFString.self)
        return name as String
    }

    private func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: element
        )
    }

    private static var defaultInputDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static let propertyListener: AudioObjectPropertyListenerProc = { _, _, _, clientData in
        guard let clientData else {
            return noErr
        }
        let service = Unmanaged<SystemInputVolumeService>.fromOpaque(clientData).takeUnretainedValue()
        service.handleAudioPropertyChanged()
        return noErr
    }
}

private extension Array where Element == Double {
    var average: Double? {
        guard !isEmpty else {
            return nil
        }
        return reduce(0, +) / Double(count)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
