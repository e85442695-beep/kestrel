# Findings

Measurements from one machine, Windows 11, MSVC 19.44, Windows SDK 10.0.26100,
Vulkan SDK 1.4.363.0, LLVM 21.1.8 (AMDGPU), against the Xbox Series 1.0.2.1 package.

## 1. Missing `XErrorReport` export (fixed)

`xgameruntime.lib`'s thunk `GetProcAddress`es `XErrorReport` and treats a missing export
as fatal. Without a debugger that surfaces as `int3` → `0xC0000374`, which reads exactly
like heap corruption and sends you looking in the wrong place.

Fixed in `runtime/shims/xgameruntime.cpp`: the named export now exists, with the same body
as the `IXErrorImpl` slot 3 (`HRESULT XErrorReport(HRESULT, const char*)`, extra arguments
ignored).

## 2. Static TLS read through TEB slot 0 (resolved in the forge runtime)

The crash after the fix is deterministic and small:

```
1412d883e  mov  rcx, gs:[58h]        ; TEB->ThreadLocalStoragePointer
1412d8847  mov  rax, [global]
1412d884e  mov  rcx, [rcx]           ; slots[0] — hardcoded
1412d8855  mov  rcx, [rcx+1258h]
1412d885c  test rcx, rcx
1412d885f  cmovne rax, rcx
1412d8863  test byte [rax+12h], 10h  ; rax = 1 → fault
```

The title reads its static TLS through module index 0, because on the console the
executable is always the first TLS module. On Windows slot 0 belongs to the host
executable, so the title reads the host's block and walks into garbage. The system returns
`0xC0000005` reading `0xFFFFFFFFFFFFFFFF` (or `1` one frame earlier, depending on the run).

Two repairs were attempted and both reverted:

1. **Alias slot 0 to the title block on non-loader threads.** The host's own TLS broke the
   first time a shim ran on the game thread (`gta6rt.exe+0x136AC3`, null read).
2. **Move the host TLS to slot 15 and patch `_tls_index`.** The patch did not take: the
   shim table lookup crashed (`rt::shims::table+0x1c`) immediately after the move.

The reason neither works is that the host is re-entered on every shim call. The slot has to
switch at the call boundary, not the thread boundary, or the host must be built without a
static TLS directory so the title inherits slot 0 naturally.

## 3. Unimplemented imports in the first runtime (20)

All audio, plus one storage factory. They return success without doing anything, which is
worse than failing loudly:

```
chad.dll    XDspActivate, XDspConnectWithMaximumStreamLimit, XDspDeactivate,
            XDspDisconnect, XDspSubmitCommand
xapu.dll    XApuConnect, XApuDequeueResult, XApuDisconnect, XApuEnqueueCommand,
            XApuGetResultCount
AcpHal.dll  AcpHalCreate, AcpHalReleaseShapeContexts, AcpHalAllocateShapeContexts,
            ApuAlloc, ApuCreateHeap, ApuFree, ApuIsVirtualAddressValid,
            ApuMapApuAddress, ApuMapVirtualAddress
XCRDAPI.dll DStorageGetFactory
```

## 4. Toolchain notes

- `llvm-mc` must be built with the AMDGPU target; the official Windows LLVM has none.
- `gta6rt` needs Windows SDK 10.0.26100 for 1.2 root signatures. `vcvars64` keeps picking
  the older SDK unless `WindowsSDKVersion` is set before the build.
- The shader stage is CPU-bound: 26,503 translations on 6 shards, roughly 30 minutes on a
  12-thread machine once the fast shaders are past.

---

## 5. Forge branch: the game runs, frames are black

`forge/adopt/menu-stack` (worktree `D:\Kestrel-upstream`, built into `D:\Kestrel-out`)
changes everything below the loader. With it:

```
4 modules mapped, 0 unimplemented imports
running game_scarlett_master.exe
[rt] xbox_present: PresentX call 256 (1 planes) returned 0x00000000, 256 presented so far
```

Measured over one four-minute run:

- D3D12 device created, 92,071 recorded D3D12 calls in the trace
- command lists created, closed, reset, executed in a loop
- Xbox-only slots routed: 73 (CreateCommandListX), 78 (SetFrameIntervalX),
  79 (ScheduleFrameEventX), 133 (CreatePlacedResourceX), fence slot 8, allocator slot 8
- a window titled **Americas**, 1940x1100, appears about ten seconds in
- 256 successful `PresentX` calls

The frame is uniformly black. This is the known "black frames" work item: the forge has
`forge/fix/black-frames`, `forge/fix/black-frames-2` and `forge/fix/red-frames*` branches
for exactly this.

Required environment for a run that survives past the first asserts:

```
LEONIDA_D3D12=vulkan
LEONIDA_SKIP_INT3=1        (only takes effect together with --trace)
gta6rt.exe --run <exe> --game-dir <package> --trace trace.json
```

Without `--trace` the first `int3` ends the process with `0x80000003`; without
`LEONIDA_D3D12=vulkan` the device path is dead.

### Reproduction on GTX 1650, driver 591.86

The `menu-stack` runtime at Leonida revision `7d0af7c` mapped four modules
with zero unimplemented imports. At process initialization it loads a TLS
helper DLL with a copy of the host's TLS template. Windows assigns the helper
an index, the host updates its `_tls_index`, and the loader assigns slot 0 to
the mapped executable. This run assigned the host index 7. The trace recorded
physical page allocations and the runtime served the DirectStorage factory,
created the Vulkan device and called Xbox device slots 26, 48, 73 and 133.

With the original shader cache, 4,096 successful presents were logged before
the test was stopped. There were 14 missing vertex shader messages.
The cache lacked the `exe` and `library` shader indexes. After translating all
10 embedded executable programs with wave64 emulation, all 10 passed
`spirv-val`, the shader library grew from 26,573 to 26,583 entries, and the
missing vertex shader messages disappeared. Slot 67 still reported missing
compute programs. All 134 distinct missing compute code digests from the
original run matched programs in the extracted pipeline library. This
comparison covered the program bytes. Slot 67 also uses the dispatch-state
digest when looking up the translated program.

Leonida revision `ca96814` from `forge/fix/black-frames-2` adds descriptor
writeback and texture view lookup in slot 70. A separate build with the same
shader cache presented successfully through call 4,096. A client-area capture
of its fallback window sampled one color. Repeating with
`LEONIDA_DEBUG_CLEAR=1` produced a uniform magenta client area
(`#FF00FF`), confirming that a render-target clear reaches the window.
With `LEONIDA_PROBE=all`, the Vulkan layer logged that it installed the
full-screen triangle and solid-green shaders, while the sampled client
area stayed black. The translated compute pipeline library was absent
during these runs.

The all-target build of `ca96814` hit MSVC C1002 after producing the runtime
binaries. Packaging those binaries with `--runtime-build` succeeded.

## Build wrapper

Kestrel's wrapper previously looked for `make_game.py` in the Kestrel repository.
The entry point lives in the Leonida runtime checkout. `tools/build.cmd` now
finds the sibling `Kestrel-upstream` checkout or uses an explicit `KESTREL_SOURCE`.
Set `KESTREL_PYTHON` to the full interpreter path when Python 3.12 or newer
is outside PATH. Game, output and work paths are resolved before the wrapper
changes directories.
