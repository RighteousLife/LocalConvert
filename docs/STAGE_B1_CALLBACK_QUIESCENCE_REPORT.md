# Stage B.1 — AudioRingBuffer Callback Quiescence Report

**Date:** 2026-11-23  
**Owner:** Codex (temporary, user-authorized delegation)  
**Scope:** Callback quiescence, playback-generation isolation, producer cancellation, and ring-buffer lifetime only. Stage B.2 and Stage C were not started.

## Root Cause

`AudioPlaybackEngine` reused a single `AudioRingBuffer` across play, seek, and stop. `halt()` and `beginStreaming()` called `AVAudioEngine.pause()` and then reset the ring’s storage and atomic indices. Apple documents `pause()` as stopping the engine and audio hardware, but does not document a callback-drain barrier for an `AVAudioSourceNode` render block. A callback already inside `read()` could therefore publish its old `readIndex` after reset wrote zero. See [Apple’s AVAudioEngine pause documentation](https://developer.apple.com/documentation/avfaudio/avaudioengine/pause()).

## Synchronization Protocol

The mutable ring reset was removed. Each playback run now owns an `AudioRenderGeneration` containing a fresh `AudioRingBuffer` and a permanent-close callback gate. The source-node callback and its producer capture that same generation; a later playback receives a different ring, indices, and gate.

Before pausing or retiring a source node, control code permanently closes its gate. Callback admission uses sequentially consistent atomics: it checks `closed`, claims the single-consumer slot, then checks `closed` again. If close wins either race, the callback is rejected and writes silence without accessing the ring. A callback that passes the second check is accounted as active until its bounded ring read finishes. The control-side retirement task keeps the old generation alive until the gate is quiescent; the callback closure and producer also retain their generation while executing.

Correctness follows from those states:

1. Once the gate is closed, a callback cannot pass both admission checks, so no later callback can read the old generation.
2. A callback admitted before close may finish, but it only reads and publishes indices in its captured old ring. That ring is never reset or reused.
3. A delayed producer writes only to its captured old ring. Producer tasks are cancelled and drained through a shared drain task before a current generation starts; even a late old write cannot change the new ring’s indices or storage.
4. New playback installs a fresh source node with a fresh open gate. A stale node’s permanently closed gate cannot be reopened.
5. The callback path performs bounded atomic operations, pointer copies, and deterministic zero-fill only. It has no lock, allocation, logging, I/O, actor hop, async work, or wait. Quiescence polling uses a 1 ms asynchronous sleep on control tasks, not a blocked render or control thread.

This design does not require `pause()` to establish callback completion before ring mutation: the ring is no longer mutated or reused at generation changes. Pause remains for stopping hardware work; the gate and per-generation ownership provide the memory/index safety independently.

## Files and Ownership

- `LocalConvert/Engines/AudioEditor/PlaybackEngine.swift` — per-generation callback gate/ring ownership, close-before-pause retirement, fresh ring/source node per playback, producer cancellation/drain serialization, and teardown retention.
- `LocalConvertTests/Phase67AudioEffectsAndPreviewTests.swift` — deterministic in-flight retirement and stale-generation isolation, callback admission, fresh-generation underrun/recovery, gated zero-allocation path, and rapid play/seek/stop regression.
- `docs/STAGE_B1_CALLBACK_QUIESCENCE_REPORT.md` — this report.
- `docs/AGENT_HANDOFF.md` — ownership was recorded before implementation and is explicitly released after this delivery.

All pre-existing user changes and untracked files remain preserved. No project manifest, Xcode project, bundled dependency, or unrelated source file was changed.

## Tests and Validation

All commands used the `LocalConvert` scheme on macOS arm64, Debug configuration, with `CODE_SIGNING_ALLOWED=NO`.

- `xcodebuild test ... -only-testing:LocalConvertTests/Phase67AudioEffectsAndPreviewTests` — **20 passed, 0 failed, 0 skipped**.
- Focused Thread Sanitizer run for callback-gate admission, in-flight generation retirement, SPSC continuity, and rapid engine cancellation/replacement — **4 passed, 0 failed, 0 skipped**. The final in-flight stale-producer test was rerun under Thread Sanitizer — **1 passed, 0 failed, 0 skipped**. No TSAN reports were emitted. Xcode emitted a linker warning that duplicate `-rpath '@executable_path'` was ignored.
- Playback/editor regressions (`Phase64AudioPlayerTests`, `AudioEditorCoreTests`, `AudioTimelineTests`) — **18 passed, 0 failed, 0 skipped**.
- `xcodebuild build -quiet -project LocalConvert.xcodeproj -scheme LocalConvert -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO` — **exit 0**.
- `./scripts/verify-dependencies.sh` — **all checked dependency and binary requirements passed**, including arm64, deployment target, linkage, signatures, and notices.

The test target emitted warnings in existing Phase 67 test code (unused `var`/closure results). No warning was emitted from the new callback gate or generation implementation. The initial pre-fix focused test compile also exposed a test-only `DispatchSemaphore.wait()` call from an async context; that test was corrected to use deterministic XCTest expectations before successful runs.

## Remaining Risks and Limits

- Thread Sanitizer and deterministic barriers validate the protocol and its races, but cannot force every CoreAudio driver’s live callback scheduling or teardown timing. No physical DAC loopback or hardware stress run was performed.
- An already-admitted callback may finish copying one hardware buffer after retirement begins. It cannot publish into or read from the next generation; `pause()` stops further hardware rendering as documented.
- If a callback never returns, its retired generation remains retained rather than freeing memory under a possible reader. The callback contains only a bounded ring copy and atomics, so this would indicate a framework/runtime failure outside the application’s progress guarantee.

## Final Classification

**PASS WITH DOCUMENTED LIMITATIONS** — the reset race is eliminated by immutable per-playback ring generations and permanent callback gates. Targeted tests, TSAN, arm64 Debug build, and dependency verification passed. Live hardware timing remains an environmental verification limit.
