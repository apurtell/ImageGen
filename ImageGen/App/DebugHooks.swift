#if DEBUG
// The single entry point from non-DEBUG code into DebugSupport/ (IMPLEMENTATION_PLAN.md section 2.6).
// M4 and M5 fill in this branch; the Release branch keeps no-op stubs with the same signatures.
enum DebugHooks {}
#else
enum DebugHooks {}
#endif
