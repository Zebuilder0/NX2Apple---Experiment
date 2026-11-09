import Foundation

/// Wires a pipe's read end to a callback and detaches at end of output.
///
/// A `readabilityHandler` fires whenever the descriptor is readable, and at end of output (every writer has
/// closed) it stays readable forever: `availableData` returns empty data at once, the handler returns, and
/// the dispatch source fires again, which pins a CPU core (#201). So the handler removes itself the moment it
/// reads empty data.
package enum PipeReader {
    /// `onData` gets each non-empty chunk on a background queue, one at a time. Returns at once: the handler runs until
    /// the end of output and then removes itself, and `onEnd` is called once then, after the last `onData`. The exit of
    /// the process is not that moment (output can still be in the pipe): ProcessRunner.start waits for `onEnd` before it
    /// reports the exit, and capture and stream read to the end themselves.
    package static func attach(to handle: FileHandle, onData: @escaping (Data) -> Void, onEnd: (() -> Void)? = nil) {
        handle.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; onEnd?(); return }
            onData(d)
        }
    }
}
