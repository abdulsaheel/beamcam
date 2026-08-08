import Foundation
import CoreMediaIO

// A camera extension is a plain executable that hands a provider to CoreMediaIO
// and then parks on the run loop. macOS launches it on demand when something
// enumerates cameras, so there is no app lifecycle here to hook into.
let providerSource = BeamCamProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
