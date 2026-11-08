import Foundation

/// Wires a pipe's read end to a callback and detaches at end of output.
///
/// A `readabilityHandler` fires whenever the descriptor is readable, and at end of output (every writer has
/// closed) it stays readable forever: `availableData` returns empty data at once, the handler returns, and
/// the dispatch source fires again, which pins a CPU core (#201). So the handler removes itself the moment it
/// reads empty data.
package enum PipeReader {
    /// `onData` gets each non-empty chunk on a background queue. Returns at once: the handler runs until the end of
    /// output and then removes itself. A caller that needs every byte before it goes on (the exit of the process is not
    /// that moment: output can still be in the pipe) reads to the end itself, as ProcessRunner.capture and stream do.
    package static func attach(to handle: FileHandle, onData: @escaping (Data) -> Void) {
        handle.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            onData(d)
        }
    }
}
