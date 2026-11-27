// Loaded before the compiled Dart: dart2js looks for `self.scheduleImmediate`
// to run its async steps. Without it, every `await` waits for a timer.
globalThis.self ??= globalThis;
globalThis.scheduleImmediate ??= (callback) => queueMicrotask(callback);
