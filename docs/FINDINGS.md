# Findings

Measurements from one machine, Windows 11, MSVC 19.44, Windows SDK 10.0.26100,
Vulkan SDK 1.4.363.0, LLVM 21.1.8 (AMDGPU), against the Xbox Series 1.0.2.1 package.

## 1. Missing `XErrorReport` export (fixed)

`xgameruntime.lib`'s thunk `GetProcAddress`es `XErrorReport` and treats a missing export
as fatal. Without a debugger that surfaces as `int3` â†’ `0xC0000374`, which reads exactly
like heap corruption and sends you looking in the wrong place.

Fixed in `runtime/shims/xgameruntime.cpp`: the named export now exists, with the same body
as the `IXErrorImpl` slot 3 (`HRESULT XErrorReport(HRESULT, const char*)`, extra arguments
ignored).

## 2. Static TLS read through TEB slot 0 (resolved in the forge runtime)

The crash after the fix is deterministic and small:

```
1412d883e  mov  rcx, gs:[58h]        ; TEB->ThreadLocalStoragePointer
1412d8847  mov  rax, [global]
1412d884e  mov  rcx, [rcx]           ; slots[0] â€” hardcoded
1412d8855  mov  rcx, [rcx+1258h]
1412d885c  test rcx, rcx
1412d885f  cmovne rax, rcx
1412d8863  test byte [rax+12h], 10h  ; rax = 1 â†’ fault
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

## LLVM disassembler diagnostics

The first pipeline-library build hit Python `MemoryError` while reading
`llvm-mc` diagnostics. The disassembler sent each program as one line, and
LLVM repeated that line for every invalid encoding. A single listing reached
95 MB.

The patch in `patches/llvm-mc-diagnostics.patch` wraps the byte tokens after
every 32 bytes and sends the whole stream to the same `llvm-mc` invocation.
On ten programs, the emitted instruction text and invalid-encoding counts
matched the unpatched output. The largest sample's diagnostics fell to 42 KB.

From an unpatched Leonida checkout, apply the patch with `git apply <path to
llvm-mc-diagnostics.patch>` before building the shader library.

## Wave64 scheduling for LDS append and consume

The compute library hit the translator's sync-free multi-wave assertion.
`ds_append` reached a conditional inline block even though the instruction
broadcasts the old LDS value through a wave exchange. The same path handles
`ds_consume`.

`patches/wave64-lds-barriers.patch` classifies both operations as requiring
synchronization, so the existing scheduler can use an exchange in guarded
blocks. The program that hit the assertion translated and passed
`spirv-val`. All 31 tests in the wave64 scheduler suite passed, including
the new synthetic test for both opcodes.

## Partial compute pipeline cache

After applying both patches, all 2,684 compute programs were disassembled.
The translator indexed 1,716 modules that passed `spirv-val`. It rejected
968 programs, including 894 where a reachable instruction falls through
into bytes the disassembler could not decode.

The index now contains the code keys of 163 of the 174 compute programs
missing from the earlier `black-frames-2` run. With the new index loaded,
`ca96814` logged 16,384 successful presents. At present 4,096, the count
of slot 67 failures dropped from 144 to 9. The client-area capture still
sampled only black (`#000000`). Replaying the remaining sampled programs
in the translator found two blockers, reachable undecoded words and
`s_bitreplicate_b64_b32` operating on a lane mask.

The focused loader, shader-library and descriptor-heap CTest run passed
five tests. The optional full `shader_library_corpus` run exited with
`0xC0000409`.

## Wave64 bit replication into EXEC

Seven compute programs sampled from the slot 67 failures use
`s_bitreplicate_b64_b32` with a scalar source and the full `EXEC` register
as the destination. The translator already computes the correct per-lane
bit when the destination is `VCC`. The patch in
`patches/wave64-bitreplicate-exec.patch` reuses that computation and writes
the bit through the existing EXEC setter. A synthetic test starts with
every lane disabled, checks that each scalar bit enables the correct pair
of lanes, and checks that both possible SCC values are preserved.

## Leonardo fallback window

The local build of Leonida's `forge/adopt/leonardo` at `a08e887` mapped
four modules with zero unimplemented imports. Its fallback PresentX
window stayed hidden. The patch in
`patches/leonardo-show-present-window.patch` adapts Leonida forge commit
`9dbc9da` by enx and shows the fallback window when the runtime owns it.
Apply this patch to the Leonardo checkout. The rebuilt runtime created a
visible window titled Leonida with the same launcher and shader cache.

With the EXEC patch applied, the translated compute library grew from
1,716 to 1,725 modules that passed `spirv-val`. The Leonardo runtime loaded
all 1,725, alongside the other shader indexes. It still logged missing
compute shaders in slot 67. Xbox device slot 81 also returned
`E_NOTIMPL`. Its call contract has yet to be identified.

## Leonardo CPU-visible textures

With `LEONIDA_LAZY_PSO=1`, the title reached a texture initialization
routine that uses the result of `ID3D12Resource::GetGPUVirtualAddress`
as a writable address. Under CDB, the runtime stopped in a guest call to
`memset`, writing through a null base with an offset of 32 bytes. Raising
the arena to 1 GiB moved the same fault later in the run.

`patches/leonardo-cpu-texture-shadow.patch` enables the fork's write-watched
texture buffers with `LEONIDA_TEXTURE_SHADOW=1`. The runtime uploads CPU
writes before queue submission and removes the buffer from the upload
registry before freeing it. The setting also works with real pipeline
objects and `LEONIDA_LAZY_PSO=1`. The patched build returned addresses and
logged successful texture uploads. The next observed failure occurred at
a guest null write, separate from the earlier crash in `memset`. A usable
menu remains unverified.

## Leonardo host-side copies

After the texture shadow fix, CDB stopped at a guest null write in the
startup hang checker. The checker samples per-thread timestamps. The
runtime was copying console buffers and uploading CPU-written textures
before host submissions. Some buffer copies took hundreds of
milliseconds per submission.

`patches/leonardo-track-copy-stalls.patch` uses the existing
`host_stall::Scope` for these host-side copies, as the runtime already
does for pipeline compilation. It applies after the CPU-visible texture
patch. The host-stall CTest passed. With `LEONIDA_LAZY_PSO=1`,
`LEONIDA_TEXTURE_SHADOW=1` and `LEONIDA_ARENA_MB=1024`, the build stayed
alive beyond the earlier watchdog failure and logged 32 successful
presents. Later logs reported incompatible depth/stencil views and an
unsupported texture staging copy. The client capture sampled only black.
There were zero missing shader messages and zero slot 67 failures in
this run. The test process was stopped after the capture.

---

## 6. Depth/stencil views and the swizzle answer

Two changes this round, both saved under `patches/`.

### Plain typed views of a depth-stencil plane

The runtime refused three view casts the console allows:

```
depth view refused:   resource 19 (R32G8X24_TYPELESS)   requested 41 (R32_FLOAT)
depth view refused:   resource 118 (D16_UNORM_S8_UINT)  requested 56 (R16_UNORM)
stencil view refused: resource 118 (D16_UNORM_S8_UINT)  requested 62 (R8_UINT)
```

The console lets a depth plane be read through the plain typed format of the same
width, and the stencil plane as a plain 8-bit unsigned. Vulkan expresses the same cast
through its depth-stencil compatibility family, and the runtime already builds the view
on the resource's own VkFormat, so only the guest-facing T# changes.

`patches/depth-stencil-plain-views.patch` adds those pairs. The rebuild produces a
runtime with those three refusals gone.

### XGSuggestSwizzleMode answered linear

`menu-stack` answered `E_NOTIMPL` to `XGSuggestSwizzleMode` and `XGCreateTextureComputer`,
so the title described every texture through a layout that was never filled in. The
`forge/adopt/leonardo` branch answers linear instead, which is the PC-correct answer:
there is no console layout to describe.

`patches/linear-swizzle-answer.patch` ports that behaviour to `menu-stack` — mode 0,
`S_OK` from the computer stand-in, and `S_OK` from its methods.

The result is not a picture yet. With the answer in place the title takes the texture
path for real and then stops at a null read in guest code:

```
00000001`455aa6f0  c4a2ebf70cc1  shrx rcx,qword ptr [rcx+r8*8],rdx   ds:00000000`00000000
```

That is the same stop the Leonardo branch reaches, right after
`IDStorageFactoryX2::CreateQueue1`. Both branches now die in the same place, which makes
the DirectStorage queue and its status array the next object to finish: the interfaces
are served, the queue behind them is not.

### State of the two branches after this round

| Branch | Presents | Stops at |
|---|---|---|
| `menu-stack` as it was | 256 | black frames, swizzle never answered |
| `menu-stack` + linear answer | 0 | null read after `CreateQueue1` |
| `leonardo` + texture shadow | 32 | the same null read |

Reverting the swizzle patch brings the 256 presents back; the frame stays black either
way, so the patch is kept as the honest next step rather than a regression.

---

## 7. The present path works; the title simply draws nothing

`LEONIDA_DEBUG_CLEAR=1` replaces every all-zero clear colour with opaque magenta. The window
comes out **entirely magenta** ([docs/magenta-clear.png](magenta-clear.png)).

That settles the shape of the black-frame problem:

- the swapchain exists, frames are presented (256 in 45 s, `PresentX` returning `S_OK`),
- the title's clears reach the screen through the compose path,
- so the frame is black because the title clears to black and then **draws nothing**.

`LEONIDA_PROBE=all`, which replaces the vertex and pixel stages with a pass-through pair,
leaves the frame black as well, so the missing output is not a broken shader in a drawn
triangle. Nothing is being drawn at all.

## 8. What the title is doing instead

Three measurements from the same run:

1. A thread sits in the title's own hang checker (`game+0x2215B0B`): it samples a timestamp,
   sleeps 1 s, samples again, and reports a stall when the delta is too large.
2. 2,689 failures of `DeserializeComputePipelineStateX` (Xbox slot 67, called by
   `amd_fidelityfx_upscaler_xbox.dll`), all `0x80004005`. These are the DLL's own FSR
   programs, which are not in `shaders.rpf` and therefore not in the translated index, so the
   translator has nothing to resolve. They are not what stops the frame.
3. `slot-133` shadow buffers are copied from the title's pages on every submission; the
   largest seen is 12 MiB at 193 MiB/s, 62 ms per submission.

So the title is loading, not drawing: it still runs its own watchdog and its buffer copies,
and the render target only ever receives the clear.

## 9. Diagnostics added

`patches/xmem-map-refusal-log.patch` makes `XMemMapPhysicalPages` say **why** it returns
null — bad address, placeholder API missing, or "not inside a reserved placeholder window".
The title turns a null there into an `int3`, and the int3 is skipped, so without the line the
run simply stops somewhere else.

## Next

The question is no longer "why is the frame black" but "what is the title waiting for".
The candidates, in order:

1. DStorage reads that never complete: the queue is served, the reads behind it need to be
   confirmed against the status array the title polls.
2. Content package mounts that return a path with nothing behind it.
3. The hang checker's own threshold: it may be firing on the host copies before loading ever
   finishes.

---

## 10. The missing piece was native_hashes.txt

`make_game.py` writes `<spirv>/native_hashes.txt` next to the translator's index (the HASH digest of
every carved container, keyed to its stage and path). It is what device slot 57 — the title's
"create a graphics pipeline from native code" call — looks its programs up in.

Our work folder never had it, because the shader stage that produces it was never run for this
checkout. The consequences were 16,384+ refusals in one forty-second run:

```
[rt] d3d12_xs: slot 57: no native_hashes.txt (block 0); refused with E_NOTIMPL (16384 so far)
```

Every native pipeline refused means every draw is skipped, which is exactly what a black frame
looks like.

Generated with the tool the build calls:

```
python tools/native_pso_hashes.py D:\Leonida-work\shaders\dxbc D:\Leonida-work\shaders\spirv
native_pso_hashes: 25321 digests -> D:\Leonida-work\shaders\spirv\native_hashes.txt
```

After that, in a forty-second run: **zero** slot 57 refusals, zero pipeline failures.

## 11. The title does draw

With the digests in place the same run records:

| Call | Count (40 s) |
|---|---|
| `SetPipelineState` | 601 |
| `Draw*` | 601 |
| `ExecuteCommandLists` | 810 |
| `PresentX` | 128 > 2048 over 55 s |

So the title is not "still loading" and it is not skipping draws. It draws 601 times and presents
the result, and the result is black.

## 12. The draw path itself is sound

`LEONIDA_PROBE=all` replaces the vertex and pixel stages with a built-in pass-through pair. The
window comes out **fully green** ([docs/probe-green.png](probe-green.png)).

That rules out the whole plumbing: geometry reaches the rasteriser, the pipeline state is accepted,
the render target is bound, and the compose step puts it on screen. What is missing is what the
title's own shaders compute.

Replacing only one stage (`LEONIDA_PROBE_MODE=ps` or `=vs`) leaves the frame black, because the
built-in stage and the title's stage disagree on the interface, so that split does not localise
the fault any further.

`LEONIDA_TEXTURE_SHADOW=1` with `LEONIDA_LAZY_PSO=1` still gives a black frame and 2048 presents,
so CPU-written textures alone do not explain it either.

## 13. Loads do complete

`patches/dstorage-load-counters.patch` counts what the title hands to its DirectStorage queue. One
run:

```
[rt] dstorage: Submit #1, 43 entries queued, 42 requests and 1 statuses so far
[rt] dstorage: 1 status entries completed
... (11 and counting)
```

DirectStorage is not what the title is waiting for.

## Next

The frame is drawn and then goes missing between the shader and the swapchain. Candidates:

1. The translated shaders write to a render target the compose does not read (a resolve, an
   MSAA target, or an Xbox-only alias).
2. Wave64 emulation is wrong in a way that keeps every fragment but zeroes its colour.
3. The pixel shader reads textures that are still black, and everything else is correct — the
   next measurement is a texture read back from the GPU after a frame.

---

## 14. Every draw is a full-screen triangle, and the textures are empty

Two measurements narrow the black frame to one subsystem.

**The draws are quads.** The first thirty draws of a run, with arguments:

```
[rt] draw #1 instanced: vertices=3 instances=1 first_vertex=0 first_instance=0
... (601 draws, all 3 vertices)
```

Every draw is a single full-screen triangle. So the geometry is not off-screen, the viewport is not
wrong, and the vertex shader is not misplacing a mesh: the title is running a chain of full-screen
passes, one per draw, and each samples the previous pass's output.

**The textures are empty.** Title-placed resources (Xbox device slot 133) take one of three paths in
`create_at_host_address`:

| Resource | Path |
|---|---|
| buffer | host-visible import of the title's pages, or a shadow buffer copied before every submission |
| texture | **an ordinary committed texture; the title's pages never reach it** |

That log line, once per run:

```
[rt] d3d12: a title-placed texture (device slot 133) is an ordinary committed texture,
            not the title's pages; dimension 3
```

and a sample of the pages at creation time, for the first eight textures:

```
placed texture sample at ...: 3840x2160x1 fmt 65 mips 1, first 4096 B sum 0, non-zero 0
placed texture sample at ...: 2048x2048x1 fmt 87 mips 1, first 4096 B sum 0, non-zero 0
```

The pages are all zero at creation, so the title fills them afterwards. A one-shot upload at
creation would copy nothing; the copy has to happen after the title's own writes, on the path the
shadow buffers already use.

So the black frame is a texture-visibility problem: the passes run, sample textures that never
receive the title's data, and produce black.

## Next

Give title-placed textures the same treatment as title-placed buffers:

1. a staging buffer holding the texture's texel data in the title's layout (linear, since
   `XGSuggestSwizzleMode` now answers linear),
2. an upload before a submission that uses the texture,
3. a dirty rule so a 2048x2048 texture is not re-uploaded every frame.

`patches/placed-texture-sampling.patch` adds the draw-argument logging and the page sample that
produced the numbers above.

---

## 15. The upload path exists, and it is too slow

`patches/placed-texture-upload.patch` gives a title-placed texture what a title-placed buffer already
has: the pages it was placed on are remembered, and the image is filled from them before the
submission that follows creation. The upload goes through the existing `staged_copy` replay, so the
layout transitions and the D3D12 footprint are the ones the title's own copies use.

It runs, gated behind `LEONIDA_PLACED_TEXTURES=1`:

```
[rt] d3d12: title-placed texture 3840x2160 fmt 65: uploaded 8100 KiB from the title's pages in 107.82 ms
[rt] d3d12: title-placed texture 2048x2048 fmt 87: uploaded 16384 KiB from the title's pages in 238.20 ms
[rt] d3d12: title-placed texture 2048x2048 fmt 87: uploaded 16384 KiB from the title's pages in 174.35 ms
```

and it is unusable as written: `staged_copy` creates a buffer, replays one copy region and **waits for
the queue to go idle**, once per subresource. Three textures cost over half a second, and the run
crawled — one present in fifty seconds instead of two thousand.

The flag is off by default so the runtime keeps its speed. The next version has to:

1. put every subresource of every pending texture into **one** command buffer,
2. wait once, not once per copy,
3. upload on the barrier the title uses to say its writes are done, not on the next submission.

The data is there and the path works; what is missing is batching.
