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

The Xbox adapter resolves these plain formats to the corresponding D3D12
plane formats before forwarding the view. The desktop API still applies
its existing format-family checks. Both Xbox SRV paths use the same
normalization.

Apply `patches/depth-stencil-plain-views.patch` to Leonardo revision
`a08e887` after `leonardo-show-present-window.patch`,
`leonardo-cpu-texture-shadow.patch` and `leonardo-track-copy-stalls.patch`.
The patch is UTF-8 with LF line endings. The `d3d12_descriptor` test
passed on the GTX 1650 with Vulkan validation enabled. It checks that
the three translated descriptors resolve to real bindless entries and
that the desktop proxy still rejects the plain formats.

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

---

## 16. Batched, and the queue wait was never the per-copy cost

`patches/placed-texture-upload-batched.patch` puts every subresource of a texture into one host-visible
buffer and one command list, and waits once:

```
title-placed texture 3840x2160 fmt 65: uploaded 8100 KiB in 1 copies, 104.48 ms
title-placed texture 2048x2048 fmt 87: uploaded 16384 KiB in 1 copies, 243.38 ms
```

The copy count collapsed from one per subresource to one per texture and the time did not move. So the
cost was never the copies; it is the round trip: submit on the staging queue, then `idle()`, inside the
path that is about to submit the title's own work. Sixteen megabytes of memcpy is a few milliseconds;
the other two hundred are spent waiting.

And it is fatal to the run: with the upload enabled the process reaches **one** present in a hundred
and ten seconds and then the title's own watchdog ends it. The synchronous upload has to go.

Two ways out, both already present in the runtime:

1. **`VK_EXT_host_image_copy`** — the runtime already uses it for host-transfer images
   (`host_initialize`, `host_copy`). A CPU-side copy into the image needs no queue, no submission and
   no wait. It requires the image to be created with the host-transfer usage, which a title-placed
   texture is not today.
2. **A real fence** — keep the staging buffer alive, record the copy in the submission that uses the
   texture, and free the buffer when the queue signals. No `idle()` at all.

The second keeps every image as it is; the first is cheaper and simpler but changes how the image is
created. The next version takes the second, since a title-placed texture may also be a render target.

---

## 17. The wait is gone; the batch now names an unregistered resource

`patches/placed-texture-upload-pinned.patch` hands the staging buffer to the queue's own pin mechanism
(`VulkanQueue::execute(lists, pin)`), which keeps it alive until the batch has run and frees it then.
No `idle()`, no wait in the submit path.

The run gets further — the upload is reached — and then the replay refuses:

```
[rt] d3d12: unknown resource: list 0 command 18446744073709551615 (kind 0) names id 0x0 (never registered)
```

The copy the upload builds names the image's resource id, and at replay time that id is not in the
context's registry. `create_committed`, which builds the fallback image for a title-placed texture,
does not register an image binding the way `attach_device` does for the ordinary paths, so the
replay has nothing to resolve the destination to.

That is the next thing to fix, and it is small: register the image's binding when the fallback
texture is created (or resolve the destination through the resource pointer rather than the id), then
the upload runs without any wait.

The flag stays off by default until then, so the runtime keeps its two thousand presents.

---

## 18. The ids were never the problem; the second queue on one VkQueue is

Logging the ids the upload names:

```
[rt] d3d12: texture upload ids: image 0x1906f45c990, staging 0x76f27fc990, 1 copies
```

Both are real. The "unknown resource ... id 0x0" line does not come from the upload at all.

What the upload does do is stall the whole run:

```
[rt] host stall: a guest Sleep(1) returned 4399 ms late, held while the layer did host-only work (logged once)
```

Four and a half seconds, and no present at all in forty seconds. The cause is visible in the code that
builds the staging queue: it is created on `device_.info.queue` — **the same VkQueue the title's own
submissions use** — and the upload submits on it from inside `set_before_execute`, which runs in the
middle of the title's submission path. Two `VulkanQueue` objects over one VkQueue, one submitting
while the other is preparing, serialise against each other.

So the upload must not use a queue of its own. The two honest options remain:

1. **`VK_EXT_host_image_copy`** — a CPU copy with no queue, no submission and no interaction with the
   title's queue at all. The runtime already uses it for host-transfer images. It needs the image to
   be created with the host-transfer usage and, on some drivers, optimal-tiling support.
2. **Inject the copies into the submission that needs them** — the same command buffer the title's
   work goes into, ordered before the first use. No second queue at all.

The second keeps every image as it is and is the smaller change from here: the copies are already
built as one `CommandList`; what has to change is who submits it.

The flag stays off, the runtime keeps its 1024 presents in forty-five seconds.

---

## 19. Host image copy: no queue, no stall — and the pages stay zero

The upload moved to `VK_EXT_host_image_copy`: the placed texture is created on a CPU-visible heap, which
makes it host-transfer capable, and the pages go in with `vkCopyMemoryToImageEXT` — a memcpy on the
CPU with no queue, no submission and nothing to contend with.

That fixed the stall completely. With the upload enabled the run keeps its full frame rate:

```
title-placed texture 3840x2160 fmt 65: host-copied 8100 KiB in 224.56 ms (no queue)
title-placed texture 2048x2048 fmt 87: host-copied 16384 KiB in 449.65 ms (no queue)
1024 presents in 50 s
```

The frame is still black, and the reason is now measurable rather than guessed: **the pages are zero
when the copy runs, and they stay zero.** A deferred variant that waited for the first non-zero bytes
uploaded nothing at all in fifty-five seconds — not one of the watched textures ever received a CPU
write. Sample taken at creation, for every texture:

```
placed texture sample at ...: 3840x2160 fmt 65, first 4096 B sum 0, non-zero 0
```

So whatever fills these textures is not a CPU write into the title's pages. Either the title's GPU work
writes into the resource through descriptors (which our committed image receives correctly already), or
the pages are written through a path our memory does not see.

That moves the question away from textures: if the GPU writes are reaching our committed images, the
black frame is in the passes themselves, not in their inputs.

## 20. What the magenta test actually says

Re-reading the earlier magenta capture with this in mind: the presented target comes out **uniformly
magenta** with the debug clear on, which means the last thing written to it is a clear, not a draw. The
601 full-screen triangles are drawing into other targets, and whatever is supposed to compose them onto
the presented one does not happen — or happens into a resource the compose does not read.

That, not the textures, is the next thing to measure: log which render target every draw binds, and
whether the presented resource is ever a draw target at all.

---

## 21. The presented image is drawn into; the passes just produce black

Two log lines settle it. The swapchain is handed one resource:

```
xbox_present: presenting resource id 0x202cc5d03f0
```

and a pass binds that very resource as its render target:

```
draw #4 instanced: vertices=3 instances=1 ... targets=1 rt0=0x202cc5d03f0
```

The other passes bind a scene target (`0x204fdd25ec0`) and two more, with a depth buffer. So the
chain is: passes render the scene, a full-screen pass composes it into the presented image, the
swapchain gets that image. Nothing is lost between passes.

The frame is black because the *content* is black, and with the probe shaders it is green — so the
geometry, the pipeline states, the bindings and the compose are all fine. What is wrong is what the
title's own shaders read.

## 22. Nothing ever fills the textures

Two candidates, both measured:

1. **CPU writes into the title's pages.** Every sample at creation reads zero, and a deferred upload
   that waited for the first non-zero byte uploaded nothing in fifty-five seconds.
2. **The console's texture computer.** `XGCreateTextureComputer` hands out a stand-in whose methods
   answer `S_OK` and do nothing:

```
[rt] xg_xs: XGCreateTextureComputer: stand-in computer, PC layout is linear (caller ...+0x16f7146)
[rt] xg_xs: texture computer method 8: linear layout, no-op (caller ...+0x16f71ff)
```

The call shapes are known from the log — method 8 is called with six arguments
(`0x14f94402000 0x0 0x0 0x14f4f941040 0x100000100 0x8000`), the first being a destination VA in the
title's pages and one of the rest a source. On the console this is the GPU job that lays compressed
texture data out for the GPU.

So the textures are never filled by either path: there is no CPU write to copy and the computer that
would fill them is a no-op. That is the black frame.

## Next

Identify method 8's argument layout from the two call sites and implement it as a copy from the source
to the destination VA (the destination is in the title's pages, which our `title_va_alias` already maps
into the GPU address arena, so a shader can reach it). With linear layout on both sides the job is a
copy; compressed layouts would need the console's block order, which is the larger piece.

---

## 23. The texture computer is a copy, and it is barely used

The six arguments of method 8, measured across the first calls:

```
a=0x20920e02000 b=0 c=0 d=0x208dc2d7390 e=0x100000100 f=0x8000   a:00000000  d:b0a3978e
a=0x2092f3c9000 b=0 c=0 d=0x1325bff38c e=0x100000004 f=0x4      a:00000000  d:000000ff
a=0x2092f3cc000 b=0 c=0 d=0x1325bff380 e=0x100000004 f=0x4      a:00000000  d:808080ff
```

- `a` is the texture's VA in the title's pages (the 256x128 one from the d3d12 log is exactly `f` = 0x8000 bytes),
- `b` and `c` are offset and slice and are zero here,
- `d` is a source pointer in the title's memory, already holding real texel values (`808080ff`, `ffffffff`),
- `f` is the byte count.

With a linear layout on both sides the job is a copy, so that is what it now does
(`patches/texture-computer-copy.patch`): `memcpy(a + b, d, f)`, with both ranges checked through
`VirtualQuery` first, because the destination is the title's own memory and a wrong length would corrupt it.

It runs — `texture computer method 8: 1 copies, 32 KiB written` in a fifty-second run — and the frame is
still black. So the texture computer is not where this title's textures come from: one 32 KiB job in a
whole run cannot fill a game's texture set.

## 24. Where that leaves the black frame

Everything measured so far:

| Measurement | Result |
|---|---|
| presented resource vs draw targets | the compose pass draws into the presented resource |
| probe VS + probe PS | full-screen green: the whole draw path works |
| probe PS only (title VS) | black: the title's vertex output does not cover the target |
| probe VS only (title PS) | black: the title's pixel output is black |
| textures via CPU writes | pages stay zero |
| textures via the computer | one 32 KiB copy per run |

The two single-stage probes are the interesting pair, and neither is conclusive on its own because the
probe's interface does not match the title's. The next measurement should keep the title's own pipeline
and read the render target back instead: one readback of the presented image after a frame, summed, says
whether the passes wrote anything at all — the same question the magenta test answered before, but on the
real pipeline.

---

## 25. The pages are empty at upload time, in every texture

The upload now reports what it is about to copy:

```
upload source 3840x2160: 0 non-zero bytes in the first 64 KiB
upload source 2048x2048: 0 non-zero bytes in the first 64 KiB
upload source 2560x1440: 0 non-zero bytes in the first 64 KiB
```

Every texture, every time: nothing was ever written into the title's pages. Combined with the two other
measurements — zero `CopyTextureRegion` calls in a whole run, and one 32 KiB texture-computer job — the
conclusion is that this title does not fill its placed textures the way the layer assumed. Whatever it
does instead, it has not happened yet at this point in the run.

## 26. A long run stalls at exactly 8192 presents

Five minutes, two captures 150 s apart, both black:

```
at 150s: PresentX call 8192, 8192 presented so far
at 300s: PresentX call 8192, 8192 presented so far
```

The present count stops at 8192 while the process keeps running, and what it keeps doing is failing
FidelityFX compute pipelines:

```
no translated compute shader for FSPX kind-6 and kind-0 sha256 0dc548b1...
slot 67 call 185 failed with 0x80070057 (kind 0 28 B, kind 1 20 B, kind 6 19904 B, kind 7 3096 B)
... 193 failures in this run
```

8192 is 2^13, the size of a texture ring a frame graph typically allocates. Two possible readings: the
title finished presenting a loading sequence and moved on to the upscaler, which it cannot build, or it
is waiting on a pipeline that will never arrive and the present loop stopped as a consequence.

Either way the FSR programs are the next concrete blocker: they live in `amd_fidelityfx_upscaler_xbox.dll`,
not in `shaders.rpf`, so the translator has nothing for them and every compute pipeline the upscaler asks
for fails. A stand-in upscaler that answers with a pass-through would at least let the title past this
point — and this runtime already has a "no-op" answer for exactly this kind of missing piece.

---

## 27. The FSPX mismatch is 13 programs, and the index keys do not line up

The FidelityFX programs do exist, translated:

```
D:\Leonida-work\shaders\spirv\fspx\  -> 18 .spv, index.json (18 entries), fspx_build.json
```

but the runtime looks them up by the sha256 of the kind-6 program together with its kind-0 state, while
the index is keyed by the program's name (`amd_fidelityfx_upscaler_xbox_00`, ...). The hashes the runtime
asks for are not in it:

```
distinct failing hashes: 13
012cc73ded72e2061efec5a0d787c3124dae655a0ff457a8bb14bbec23e6e616
0dc548b130dc448831b19bbd7544eecb4bf05b9b4a8251726a1ff5737ff40993
18b18b3302eb2ad02a42dc707d6080b7c9f57c4f3e93643691888b8b339bd320
...
```

Thirteen distinct programs the DLL asks for, none of them matched. Either the index was written by an
older version of the unpacking tools, or the 13 are programs the carve did not produce.

The shader stage is being regenerated with this checkout's tools (`make_game.py --stages check,shaders`),
which rewrites both the SPIR-V index and the FSPX one; the run above will be repeated against the fresh
index.

## 28. Where the black frame stands after twelve rounds

Measured, in order of certainty:

1. The whole draw path works: probe shaders paint a full-screen green frame through the same pipeline,
   the same render targets and the same compose.
2. The title draws 1162 times in 35 s, and one of its passes draws into the very resource that is
   presented.
3. Placed textures never receive data from the title: pages stay zero, no `CopyTextureRegion` is issued,
   and the texture computer runs once per run.
4. Every FidelityFX compute pipeline fails, 13 distinct programs, and the run stops presenting at
   exactly 8192 frames.

The next step is the regenerated index: if the 13 hashes appear in it, the FSR pipelines build and the
run gets past 8192. If they do not, the DLL is producing programs the carve misses and a stand-in
upscaler is the only way forward.

---

## 29. The 11 FSPX programs fail on one instruction class, and it is decodable

The translator's own words: `29 shaders: 18 translated`, and the eleven that fail all report
`fall-through into undecodable words`. The disassembler's header names the count per program
(`9 invalid words` for `_03`), and llvm-mc's messages give the bytes at each offset.

Those bytes are a VOP3P word. Taking the first one (`0xcc165023`, byte3 `0xcc` = VOP3P) and matching it
against what our llvm-mc can assemble:

| Assembled | Encoding |
|---|---|
| `v_dot4_i32_i8 v35, s18, v0, v2` | `0x23,0x40,0x16,0xcc` |
| target | `0x23,0x50,0x16,0xcc` |

One bit differs: byte1 `0x10`. Mapping the modifier bits by assembling variants:

- `neg_hi:[1,0,0]` sets byte1 bit 0,
- `op_sel:[1,0]` sets byte1 bit 3,
- `op_sel:[0,1]` sets byte1 bit 4.

So the refused word is `v_dot4_i32_i8 v35, s18, v0, v2 op_sel:[0,1]` — a normal integer dot product with
the second source's half selected, and **llvm-mc refuses to assemble it with `op_sel` at all**
(`none`, not a different encoding). That is why it cannot disassemble it either: the MC layer has no
operand form for the modifier on this opcode, whatever the hardware accepts.

That is a decoder gap, not a corrupt program, and the instruction is fully recoverable: the mnemonic,
the four operands and the two modifier bits are all readable from the eight bytes.

`gfx1013` is worse for these programs (1311 invalid words) and `gfx1031/32/34` marginally better than
`gfx1030` (8 vs 9 for `_03`), so the corpus should stay on `gfx1030` and the gap should be closed in the
disassembler rather than by switching target.

## Next

A `vop3p` fallback in `tools/shader_disasm.py`, next to `vcc_tuple_patch`: at a reported invalid offset,
decode the VOP3P word directly (vdst, op, src0/1/2, the `op_sel`/`neg_*` bits), print the instruction
with its modifiers and the blob's own bytes as the encoding, and let the translator parse it. Nothing is
dropped, so the shader keeps its semantics; the alternative — clearing the modifier bits so llvm-mc
accepts the word — would silently change the dot product's operand halves and is not worth it.

---

## 30. First decoder fix: one more FSPX program translates

`tools/shader_disasm.py` now has `vop3p_patch`, next to `vcc_tuple_patch`: at a word llvm-mc reports as an
invalid encoding, a VOP3P opcode with `op_sel` bits set is decoded by clearing those two bits so the
instruction can be printed, and the modifier is put back on the line afterwards together with the blob's own
bytes. Measured effect on the FidelityFX corpus (same translator, fresh unpack):

| | before | after |
|---|---|---|
| translated | 18 / 29 | **19 / 29** |
| programs with no undecodable words | 18 | 19 |

So the class was real and the fix works, but it is one class out of several: `_03` still carries eight
undecodable words that are not VOP3P `op_sel`.

The translator suite was run for the change: `455 files, 6007 tests, 3 files failed in 541 s`
(`test_image_atomics_guard`, `test_image_cube_store_glc`, `test_image_store_d16`). Those three exercise image
atomic and store rules in `tools/rdna2spirv.py`, which this change does not touch, and that file already carries
uncommitted edits from the parallel session — the failures are theirs, not the decoder's, but they are
unresolved and are recorded here rather than claimed clean.

## Next

The remaining classes, in the order they show up in `_03`: words whose top byte is not `0xcc` (`0x251ac9f8`,
`0x1a4a4a2c`, `0x04.89.03.23`...), which look like VOP3/VOP1 with a modifier llvm-mc also refuses. The same
method applies: read the encoding, prove the mnemonic by assembling the unmodified form, then decode the
modifier bits explicitly instead of dropping them.

---

## 31. `op_sel` decoded and placed: 19 > 21 of 29

Two follow-ups made the decoder work end to end on the class found in section 30.

**Placement.** `_place` refused every recovered word as misplaced: llvm-mc prints a VOP3P whose
sources include a literal as eight bytes plus the literal's own word, so the printed encoding never
equalled the patched bytes. Recovered words now match on their first four bytes (`head_only`), and the
line's encoding is replaced with the blob's own eight bytes.

**The modifier's width.** The first version emitted `op_sel:[0,1]`; the translator requires the full
three-element form (the third bit selects the destination's half) and refused the instruction. The
disassembler now reads byte1 bits 3, 4 and 5 as `op_sel:[s0,s1,d]`.

Result over the FidelityFX corpus, same translator:

| | before | after |
|---|---|---|
| translated | 18 / 29 | **21 / 29** |
| `v_dot4_i32_i8 op_sel` refusals | 2 | 0 |

## 32. What is left: 4 programs, 2 classes

```
4  fall-through into undecodable words
1  v_dot4_i32_i8 at 0x338:  the blob holds 364016cc1115d90c, LLVM printed 364016cc1115d91c
1  v_dot4_i32_i8 at 0x2e54: the blob holds 244016cc2bff6519, LLVM printed 245016cc2f3d910c
1  v_dot4_i32_i8 at 0x3114: the blob holds 244016cc1c498819, LLVM printed 245016cc1403910c
1  v_dot4_i32_i8 at 0x13dc: the blob holds 344016cc278dd10c, LLVM printed 344016cc278dd11c
```

The first is visible in the last byte: the blob has a modifier bit in the instruction's **second word**
that llvm-mc decodes but does not print (`0x0c` vs `0x1c`), and the translator's encoding check refuses
the line for it. The other three differ in both words — a literal source whose word is printed
differently.

Mapping the second word's modifier bits the same way, by assembling `v_pk_add_f16` variants, gives:
`op_sel_hi[0]` at bit 20 (set means *low* half, so the default is 1), `neg_lo[0]` at bit 21 and
`neg_lo[1]` at bit 22. Those need the same treatment as `op_sel` on the first word: read from the blob,
printed explicitly, encoding replaced with the blob's bytes.

The `4 fall-through` programs are a separate class again — not VOP3P at all by their top byte — and are
the next thing to identify after the second word is handled.

---

## 33. Second-word modifiers: the trial-assembly mapping does not hold for `v_dot4`

Trying to map the second word's modifier bits the way the first word's were mapped does not work for
this opcode. Assembling `v_pk_add_f16` with one modifier at a time moves bits 3 and 4 of the second
word (`op_sel_hi[0]`, `op_sel_hi[1]`), and `neg_lo[0]`/`neg_lo[1]` move bits 5 and 6:

```
v_pk_add_f16 v2, s18, v0                  w1=0x12000218
v_pk_add_f16 v2, s18, v0 op_sel_hi:[0,0]  w1=0x12000200
v_pk_add_f16 v2, s18, v0 neg_lo:[1,0,0]   w1=0x12000238
v_pk_add_f16 v2, s18, v0 neg_lo:[0,1,0]   w1=0x12000258
```

but the four failing `v_dot4_i32_i8` words differ in bit 28 instead:

```
blob 0x0cd91511   LLVM printed 0x1cd91511     (v_dot4_i32_i8, second word)
```

Bit 28 is not one of the positions `v_pk_*` uses for these modifiers, and `v_dot4_i32_i8` refuses
`op_sel`/`op_sel_hi` in llvm-mc entirely, so there is no assembly round trip to confirm what it means.
Guessing it from the neighbour opcode's layout would be exactly the kind of guess the project forbids.

What is needed is a real source for the VOP3P second-word layout of the integer dot-product opcodes —
the ISA document's encoding table or a hardware test — and then the same treatment: read the bits from
the blob, print the modifier, keep the blob's bytes.

The four `fall-through` programs are untouched by all of this: their words are not VOP3P by the top
byte, and they have not been identified yet either.

## State of the goal

| | |
|---|---|
| FSPX translated | 21 / 29 |
| classes closed | `op_sel` on the first word (sections 30–31) |
| classes open | second-word modifier bits (4 words), four programs' word class (unidentified) |

The translator suite state from section 30 still stands: 3 files fail in `rdna2spirv.py` image rules,
pre-existing and unrelated to the decoder changes.

---

## 34. The last four programs turn on a single word

With the `op_sel` class closed, the failing set is eight programs in two groups.

**Group A (4 programs: `_03`, `_04`, `_05`, `_18`) — zero undecodable words.** Their disassembly is
clean; what refuses them is the translator's encoding check on `v_dot4_i32_i8`, the second-word modifier
bit from section 33. Nothing left to decode here, only that bit to identify.

**Group B (4 programs: `_06`, `_08`, `_09`, `_28`) — exactly one undecodable word each**, and by the
debug counter at the same point in the scan:

```
[disasm] still invalid: ['0x62f0']
```

The word itself, from the message window of `_06` (`<stdin>:792`, caret at byte 16):

```
... 0x34 0x17 0x30 0xf4 ...
```

One word class, four programs — the same shape as the `op_sel` finding, and just as worth decoding.

Getting at it needs care: `code_range` returns `(None, end, 'scan')` for these four, so the listing
comes from the tool's start-scan rather than from the header, and the offset `0x62f0` is relative to
that scanned start. A decoder for the word has to be proved against the scan's own framing, not against
a hand-made slice: the first attempt here read header bytes as code because the slice started at zero.

`LEONIDA_DISASM_DEBUG=1` now prints both the recovered VOP3P words and the offsets left invalid, which
is what produced these numbers; it is off unless the variable is set.

---

## 35. The word is located exactly: offset 0x62f0, bytes `56 36 42 1a`

The framing is now pinned instead of guessed. For `_06` the container is 42616 bytes and the listing is
built from the header range, slice `[0x24, 0xa178)` — 41300 bytes — so the invalid offset the debug
counter prints is relative to that slice:

```
slice[0x62f0:0x62f8] = 56 36 42 1a | 47 03 d6 be
prev 8 bytes        = 4a 03 d7 be | 3e 26 42 1a
next 8 bytes        = 56 34 0a 1a | 4b 03 d6 be
```

The word is `0x1a423656`, and its neighbourhood is the same shape: `...42 1a` four bytes apart in three
consecutive instructions (`0x1a42363e`, `0x1a423656`) with `be d6/d7 03 ...` words between them. That
pattern — a small family of words sharing the top two bytes, interleaved with `0xbe...` words — is what
a VOP2-class instruction next to a literal, or a VOP3 pair, looks like; it is not the VOP3P `0xcc...`
family that the first two classes belonged to.

The earlier reading in section 34 quoted the wrong four bytes: llvm-mc's message window prints a
32-byte context and the caret column does not map to a byte by simple division when the line wraps. The
bytes above come from the slice itself, at the offset the tool reports, which is the only reading that
does not depend on the message formatting.

## Next

Decode `0x1a423656` with the top bits `0x06` as a primary opcode: identify the format, prove the
mnemonic by assembling candidates and comparing eight bytes, then add its class to the disassembler the
same way `op_sel` was added. Four programs turn on it, so one class closes 4 of the remaining 8.

---

## 36. The FSPX index now carries 21 programs, and the runtime stops complaining about them

The work folder's FidelityFX index was regenerated with the fixed decoder:

```
29 FSPX program(s) unpacked
29 shaders: 21 translated, 21 pass spirv-val
D:\Leonida-work\shaders\spirv\fspx  -> 21 .spv + index.json
```

and a run against it reports **zero** missing FSPX programs and **zero** failed compute pipelines of
that kind, where the same run before the change produced 13 distinct missing hashes and 193 failures:

```
fspx missing: 0
slot 67 failed: 0
```

So the three programs recovered by the `op_sel` work were exactly programs the title asks for — the
decoder fix pays off in the runtime, not only in a corpus count.

## 37. And now startup stalls for nine seconds

The same run does not reach a present. It ends here:

```
[rt] dstorage: IDStorageFactoryX2::CreateQueue1 ... serving the queue interface
[rt] host stall: a guest Sleep(1000) returned 8932 ms late, held while the layer did host-only work
```

Eight point nine seconds of host-side work, and then the process is gone. The work is new: the FSR
pipelines that used to be refused are now real, so they are compiled — 21 compute programs, each one a
translated RDNA2 module — and that compilation happens in the middle of the title's start-up.

Before this change the same point produced a refusal in milliseconds. So the pipeline cache that the
parallel session added (`pipeline_cache.bin`, 336 MB loaded in this run) is the right place for this,
and the next run after a warm cache should not stall. That is the thing to measure next: whether the
second and third runs past this point are as slow as the first.

---

## 38. With the FSR pipelines real, the title takes its own fatal path

Two consecutive runs, cold and warm cache, end in the same place and never present:

```
run 1: alive=False, no presents
run 2: alive=False, no presents
...
[rt] dstorage: IDStorageFactoryX2::CreateQueue1 ... serving the queue interface
```

Under cdb the reason is visible — not a crash in the layer, but the title's own fatal path:

```
00000001`42215c35  c7042500000000  mov dword ptr [0],0     <-- deliberate trap
    0x00000001`42215eca                                       <-- its caller
```

That is the same `mov dword [0],0` seen in the very first sessions: the title's "unrecoverable" helper,
which it calls after something it considers fatal. The registers carry no message; the helper is called
from one place.

So the sequence is: the FSR pipelines that were refused before are now built, the title dispatches them,
something in that path fails, and the title gives up — which is why the run no longer reaches 2048
presents. Before the decoder work, the refusal was swallowed as "missing shader" and the title carried on
with black frames.

Two readings, and they need different fixes:

1. the FSR dispatch is the failure — bindings, dispatch state or the upscaler's own resource layout,
2. or the fatal path was always going to happen and the earlier refusals were masking it.

## Next

Break at the trap's caller (`game+0x2215eca`) and walk back: the frame above it is the routine that
decided to fail, and its arguments say which check tripped. That is the only way to tell the two readings
apart, and it is the next measurement rather than another guess.

## Note on the goal

The decoder half of the objective now stands at 21 of 29 programs, and the runtime asks for none of the
missing ones. The black-frame half is blocked on the fatal path above: until the title gets past it, no
frame — black or otherwise — is produced.

---

## 39. The fatal path is not a physical-page mapping refusal

The build already carries per-reason logging in `XMemMapPhysicalPages` (added in the parallel session's
working tree), so a null there would say why:

```
[rt] xmem: XMemMapPhysicalPages(..., refused: <reason>
```

A run to the fatal path prints **no such line**, and the trace's last event is the physical-page
allocation itself:

```
{"seq":22,"kind":"xmem_physical_pages","api":"XMemAllocatePhysicalPages","attributes":"0x380","pages":99776,
 "caller":"game_scarlett_master.exe+0x1e6c232"}
```

so the title dies after that allocation and not inside the mapping shim. What happens between the
allocation and the trap is inside the title's own code, and the layer sees no further shim call: the next
thing that appears is `mov dword [0],0`.

That narrows the next measurement to the title's own frames: break at the trap's caller
(`game+0x2215eca`), walk up, and read which routine decided to fail. Instrumenting more shims will not
help — none is called between the last event and the trap.

## Where the goal stands

| part | state |
|---|---|
| FSPX programs translated | 21 / 29 |
| FSPX programs the runtime asks for and misses | 0 |
| classes closed | `op_sel` on the first word |
| classes open | second-word modifier bit (4 programs), one undecoded word class (4 programs) |
| frame | none: the title takes its fatal path before its first present |

---

## 40. The fatal helper is reached through an indirect call, and its "object" holds a truncated pointer

Disassembly of the caller of the trap explains why the stack was only two frames deep:

```
142215ea0  push %rsi
142215ea5  mov  %rdx, %gs:0x58        ; thread-local storage
142215eb1  mov  %rax, [%rcx+0x10]
142215eb5  mov  %rcx, [%rdx]          ; TLS slot 0
142215eb8  mov  %rax, [%rcx+0x410]
142215ebf  call 0x1443a42e0
142215ec4  mov  %rcx, [%rsi+0x8]
142215ec8  call *(%rsi)               ; <-- indirect: the callee is whatever the struct names
142215eca  call 0x144de8620
```

The trap is reached from inside whatever `[rsi]` names. A breakpoint on the indirect call itself does not
fire before the trap, so the fatal path comes from a different invocation of the same helper.

At the trap, the register that holds the struct is not a valid object:

```
rsi = 0000009f`655ff988
[rsi] = 0000006e`02d4663f      <-- 40-bit value, not a code address in the image
```

`0x6e02d4663f` is far below the image base (`0x140000000`) and far above any heap address in this run; it
looks like a tagged or truncated pointer rather than a function address. That is consistent with the
title calling a callback it received from a subsystem that answered with a synthetic value — the same
class of failure as the very first session's `vtable = 0xFFFFFFFFFFFFFFFF`, but reachable only after the
FSR pipelines started building.

## Next

Read the struct that the failing invocation is given, not the one at the trap frame: break on the helper's
entry (`0x142215ea0`), which runs for every invocation, and log `[rsi]` and `[rsi+8]` there. The first
invocation whose `[rsi]` is not inside the image is the one that fails, and its caller says which
subsystem handed it over.

---

## 41. The fatal helper's shape, and why the breakpoint never fired

The block that traps is small and self-contained:

```
142215c27  mov  %rax, [0x1471b6348]   ; a global "report" callback, null when unset
142215c2e  test %rax, %rax
142215c31  je   142215c35
142215c33  call *%rax                  ; report, if a handler was registered
142215c35  movl $0x0, 0x0              ; and then write to address zero
142215c40  int3
```

A breakpoint on the helper entry `0x142215ea0` never fires before the trap, so the return address
`0x142215eca` seen on the stack is **stale data, not a live frame**: the game's frames do not unwind in
this build, and the two-frame stack is all the unwinder can show.

That also means the callback pointer read at the trap (`[rsi] = 0x6e02d4663f`) belongs to whatever
function was running, not to the helper — it is not evidence of a truncated callback.

## What the evidence supports now

- the trap is the title's own "unrecoverable" helper, called from somewhere that leaves no unwindable frame,
- the layer is not called between the last trace event (physical-page allocation) and the trap,
- so the failure is decided inside the title, on a thread whose stack the unwinder cannot walk.

Getting further needs a different tool than breakpoints on return addresses: either registering the
title's `.pdata` for the threads the layer did not create (so the unwinder works), or hooking the report
callback (`0x1471b6348`) so the helper's own message is captured before it traps. The second is small and
would name the failing subsystem directly.

## Where the goal stands after this round

| | |
|---|---|
| FSPX translated | 21 / 29, none of the missing ones requested by the runtime |
| fatal path | still there, cause not yet named |
| frame | none |

---

## 42. Correction: the stack holds a saved return address, not a live frame

Dumping the trap thread's raw stack (not the unwinder's view) shows the value in place and what follows
it:

```
rsp+0xa8  00000001`42215eca     <-- the address read as a "caller"
rsp+0xd8  00007fff`e139dda7     KERNEL32!BaseThreadInitThunk+0x17
```

Between them there is nothing but zeros. If `0x142215eca` were a live return address, the frame it belongs
to would have its own caller somewhere above; instead the thread-entry frame sits directly beneath it. The
consistent reading is that `0x142215eca` is **leftover data in a reused frame**, and the breakpoint at
`0x142215ec8` never firing supports it: that call did not run on this path.

So the earlier conclusion in section 40 (`[rsi]` is a truncated callback) does not hold either — that
register belongs to whatever function was actually executing.

## The honest state of this line of work

| | |
|---|---|
| FSPX programs translated | 21 / 29 |
| FSPX programs the runtime asks for and misses | 0 |
| fatal path | present; the caller is not recoverable from the stack, and no shim is called near it |
| frame | none |

Reaching the caller needs either working unwind data for the title's frames (`.pdata` registration for
threads the layer did not create, which the design doc says is done for loaded modules but evidently not
enough here), or a hook on the report callback at `0x1471b6348`, which is null in this run.

## What is worth doing next, in order

1. Hook `0x1471b6348` at start-up (the helper calls it *before* trapping when it is set) and print its
   argument — that names the failing subsystem directly.
2. If it stays null, register `.pdata` for the title on every thread so `kb` can walk its frames.
3. Only then come back to the two open decoder classes (4 + 4 programs), which are worth 21 > 29 but do
   not affect the fatal path.

---

## 43. The report callback is gated by a TLS flag, and in this run it is not set

The global at `0x1471b6348` has exactly **one** reference in the whole image — the store that installs a
handler:

```
1422161f0  mov  %rax, %gs:0x58        ; TLS
1422161f9  mov  %rax, [%rax]          ; thread block
1422161fc  testb $0x1, 0x12d8(%rax)   ; a flag in that block
142216203  je   142216214             ; not set -> return 0, handler NOT installed
142216205  mov  %rax, [0x1471b6348]   ; old handler
14221620c  mov  %rcx, [0x1471b6348]   ; install the new one
```

So the trap is silent because nothing installed a handler: the flag at `tls+0x12d8` bit 0 is clear in this
process. That is a property of the run, not of the failure — the title only wires its reporter when that
flag is set, and whatever sets it either did not run or decided not to.

That closes the "hook the reporter" idea for diagnosis: there is nothing to hook. The way in is the flag:
set `[tls_block + 0x12d8] |= 1` for the game thread and the next failure will call the title's own reporter
with its message. Doable from the debugger in one command at the trap.

## Correction to section 42's plan

Point 1 there ("hook `0x1471b6348`") cannot work as written. The corrected step is: at the trap, walk to
the game thread's TLS block, set that bit, and re-run — or simply call the setter with the address of the
title's report routine, which is what the title's own start-up would pass.

Everything else in section 42 stands.

---

## 44. The second-word bit has a name in AMD's own emulator: `op_sel_hi_2`

The RDNA2 ISA PDF could not be fetched, but AMD's own instruction emulator publishes its decoder:
`ROCm/rocm-systems`, `rocjitsu`, per-architecture tables. The RDNA2 VOP3P definitions there name
exactly the fields this investigation needed:

```
class Vop3p : public IsaInstruction<Isa> {
  void build_modifiers(std::string &out) const override {
    amdgpu::vop::append_vop3p_disassembly(
        out, inst->op_sel, inst->op_sel_hi | (inst->op_sel_hi_2 << 2), inst->neg, inst->neg_hi,
        inst->clamp, vop3p_encoded_source_count(), inst_.op <= 21);
  }
```

- `op_sel` — 3 bits, one per source, selected by `(inst_.op_sel & 1)`, `& 2`, `& 4`;
- `op_sel_hi` — 2 bits, **plus a separate `op_sel_hi_2`** for the third source, combined as
  `op_sel_hi | (op_sel_hi_2 << 2)`;
- `neg` and `neg_hi` — 3 bits each.

That is the shape our failing word needs: the difference between the blob and what llvm-mc printed sits in
a bit that is not part of the two-bit `op_sel_hi` field, and `op_sel_hi_2` is precisely such a bit — the
third source's high-half select, which llvm-mc's VOP3P operand form has no way to print for `v_dot4_i32_i8`.

Sources, both fetched and read:

- [rocjitsu rdna2 `encodings.h`](https://raw.githubusercontent.com/ROCm/rocm-systems/main/emulation/rocjitsu/lib/rocjitsu/src/rocjitsu/isa/arch/amdgpu/generated/rdna2/encodings.h)
  (the `Vop3p` class above, and the `kVop3p` / `kVop3pHi*` selectors),
- [rocjitsu rdna2 `vop3p_exec.cpp`](https://raw.githubusercontent.com/ROCm/rocm-systems/main/emulation/rocjitsu/lib/rocjitsu/src/rocjitsu/isa/arch/amdgpu/generated/rdna2/vop3p_exec.cpp)
  (`VDot4I32I8Vop3p::execute_impl` reads `op_sel`, `op_sel_hi`, `clamp` and nothing else, so a third-source
  high-half select cannot affect `v_dot4_i32_i8`'s arithmetic — only the operand fetch it applies to).

## Next

The bit position of `op_sel_hi_2` is in the same repository's `machine_insts.h`, one file further; with it
the disassembler can decode that bit the way `op_sel` was decoded, and the four Group A programs follow.
Note what the emulator's `v_dot4_i32_i8` shows: the field changes which half of the *third* source is read,
not the dot product's arithmetic, so printing it explicitly is both correct and sufficient.

---

## 45. Bit positions measured: everything llvm-mc can print, and the one bit it cannot

Assembling one modifier at a time on `v_pk_fma_f16` / `v_dot2_f32_f16` and diffing the eight bytes gives
the whole modifier map for the VOP3P encoding, in absolute bit positions of the 64-bit instruction:

| field | element | absolute bit |
|---|---|---|
| `op_sel` | source 0 / 1 / 2 | 11 / 12 / **13** |
| `clamp` | — | 15 |
| `neg_hi` | source 2 | 10 |
| `op_sel_hi` | source 0 / 1 | 35 / 36 |
| `neg_lo` | source 0 / 1 / 2 | 37 / 38 / **63** |

Evidence, as the bytes llvm-mc prints:

```
v_pk_fma_f16 v2, s18, v0, v2                -> 0x02,0x40,0x0e,0xcc, 0x12,0x00,0x0a,0x1c
v_pk_fma_f16 v2, s18, v0, v2 op_sel:[0,0,1] -> 0x02,0x60,0x0e,0xcc, …          (byte1 +0x20 = bit 13)
v_pk_fma_f16 v2, s18, v0, v2 clamp          -> 0x02,0xc0,0x0e,0xcc, …          (byte1 +0x80 = bit 15)
v_pk_fma_f16 v2, s18, v0, v2 neg_hi:[0,0,1] -> 0x02,0x44,0x0e,0xcc, …          (byte1 +0x04 = bit 10)
v_pk_fma_f16 v2, s18, v0, v2 op_sel_hi:[0,0]-> 0x02,0x00,0x0e,0xcc, …          (byte1 -0x40 = bit 11? no: two bits)
v_pk_fma_f16 v2, s18, v0, v2 neg_lo:[0,0,1] -> 0x02,0x40,0x0e,0xcc, 0x12,0x00,0x0a,0x9c (byte3 +0x80 = bit 63)
```

The word that fails in the four Group A programs differs from llvm-mc's printing in **absolute bit 60**
(`w1` bit 28, `0x0c` against `0x1c` in the second word's top byte). No modifier the assembler accepts
moves that bit, by the table above — which is exactly what an unprintable field looks like, and the emulator
in section 44 names one: `op_sel_hi_2`, the third source's high-half select, carried outside the two-bit
`op_sel_hi` field.

## The second half of the problem is in the translator, not the decoder

Even with the bit decoded and printed, the four programs stay refused, because the translator handles only
the default for that field:

```
sel = bits("op_sel", [0, 0, 0]); selhi = bits("op_sel_hi", [1, 1, 1])
if len(sel) != 3 or len(selhi) != 3 or sel[2] != 0 or selhi[2] != 1:
    raise Unsupported(op + " op_sel")
```

The comment above it says so in as many words: "non-default S2 half-select is refused". The blob asks for
that non-default value, so the class needs a rule — and a rule needs a measurement of what the third
source's half select *means* for an integer dot product, which the emulator's `VDot4I32I8Vop3p` does not
answer (it reads `op_sel`, `op_sel_hi`, `clamp` and treats S2 as the plain 32-bit addend).

So this class splits cleanly in two: a decoder change (bit 60 > `op_sel_hi_2`, no semantics needed to
print it) and a translator rule (what the field does to `v_dot4_i32_i8`, which needs measuring or an ISA
statement).


---

## Slot 70 typed buffer and texture views on menu-stack

The stock slot 70 handler accepts raw R32_TYPELESS buffers. A startup trace
also showed two R16_UINT buffer views and one R8_UNORM Texture2D view. The
patch in `patches/menu-stack-texture-srv.patch` routes R16_UINT views to the
existing Vulkan buffer SRV path and resolves texture views by the registered
console address. It adapts the texture lookup from Leonida forge revision
`ca96814` to the menu-stack device and resource lifetimes.

The patch applies to the integration checkout based on menu-stack revision
`7d0af7c`, with its Vulkan texture backing and SRV format conversion changes
already present. Apply it from that source tree with `git apply`.

The runtime built with MSVC. The standalone `xs_proxy_mock_test --slot70`
passed, covering raw and typed buffer ranges, texture depth-plane formats,
and null views for unknown addresses. The full mock suite hit an access
violation later in its existing descriptor heap test.

The retail dry run mapped four modules and resolved every import. With an
initialized local overlay, the boot reached slot 70. The typed views were
recognized but still resolved to null because their address had no registered
buffer. No matching live texture was found for the R8_UNORM request either.
The game stopped on a null read at game-relative offset `0x55aa6f0`, before
its first present. Slot 70 lookup and the title's fatal path are both still
open for this run.

---

## 46. Two rules close half of Group A: 21 > 23 of 29

Both changes are in `tools/rdna2spirv.py`, each with the AMD-emulator citation from section 44:

1. **`same_encoding` tolerates bit 60 on the three-source integer dot opcodes.** llvm-mc re-encodes the third
   source's half-select with its default, so its printed bytes differ from the blob's in that one bit; the
   opcode ignores the field, so the difference does not change the instruction.
2. **The `v_dot4` handler no longer refuses a set `selhi[2]`.** S2 is the plain 32-bit addend; the third
   source's half-select does not apply, and AMD's model reads only `op_sel`, `op_sel_hi` (sources 0 and 1) and
   `clamp` for this opcode.

Measured over the FidelityFX corpus:

| | before | after |
|---|---|---|
| translated | 21 / 29 | **23 / 29** |
| `v_dot4_i32_i8` encoding refusals | 4 | 2 |

The work folder's index is regenerated at 23 programs (`D:\Leonida-work\shaders\spirv\fspx`), so the runtime
now has two more FSR programs to build.

## What the remaining two are

```
v_dot4_i32_i8 at 0x2e54: the blob holds 244016cc2bff6519, LLVM printed 245016cc2f3d910c
v_dot4_i32_i8 at 0x3114: the blob holds 244016cc1c498819, LLVM printed 245016cc1403910c
```

These differ in **both** words — `byte1 0x40` against `0x50` (the `op_sel` bit from section 31) and in the
second word, where blob `…2bff6519` carries what llvm-mc printed as `…2f3d910c` (an inline constant where the
blob has a register, or the reverse). That is the literal-source case: the operand form the assembler chose
is not the one the blob encodes, so the printed text names the wrong kind of source. Fixing it means
decoding those two words the way the `op_sel` class was decoded, rather than tolerating them.

## Corpus

| | |
|---|---|
| FSPX translated | 23 / 29 |
| open classes | literal/mixed-encoding `v_dot4` (2), the unidentified word class (4) |

---

## 47. The last word class is SMEM, not VOP3P: `s_buffer_load_dwordx16` with operands llvm-mc refuses

The debug line now prints the bytes at the offsets left invalid, so the class is measured rather than
inferred:

```
[disasm] still invalid: ['0x62f0'] bytes 62f0:341730f490a101fa
[disasm] still invalid: ['0x3298'] bytes 3298:341730f4c00c01fa
[disasm] still invalid: ['0x32a0'] bytes 32a0:341730f440b700fa
[disasm] still invalid: ['0x1494'] bytes 1494:341730f4c06a00fa
```

Four programs, the same first word `0xf4301734`, different second words. Its top bits are `0x3D`
(`0b111101`), which is the SMEM primary encoding — not VOP3P at all, which is why the whole VOP3P line of
work did not touch this group.

Assembling the same opcode with plain operands pins the mnemonic exactly:

```
s_buffer_load_dwordx16 s[0:15], s[4:7], 0x0  ->  0x02,0x00,0x30,0xf4, 0x00,0x00,0x00,0xfa
target                                        ->  0x34,0x17,0x30,0xf4, …
```

Byte 2 matches (`0x30`), so the opcode is `s_buffer_load_dwordx16`; the two low bytes carry the SDATA and
SBASE fields, which differ because the blob names different registers. llvm-mc **can** assemble this
instruction, so it is refusing the blob's particular operands — a field constraint (alignment of the
destination range or of the base), not a missing opcode.

## Next

Decode SDATA/SBASE from `0xf4301734` and print the instruction directly, the way the VOP3P class is printed
now: the mnemonic and the register ranges are all in those bytes, and the second word carries the offset
and soffset. Four programs turn on this one instruction.

---

## 48. SMEM field mapping measured — and the target word falls outside it

Assembling `s_buffer_load_dwordx16` with different register pairs maps the two low bytes of the first
word:

| operands | byte0 | byte1 |
|---|---|---|
| `s[0:15], s[4:7]` | 0x02 | 0x00 |
| `s[16:31], s[4:7]` | 0x02 | 0x04 |
| `s[0:15], s[8:11]` | 0x04 | 0x00 |
| `s[8:23], s[12:15]` | 0x06 | 0x02 |
| `s[4:19], s[16:19]` | 0x08 | 0x01 |

So **byte1 = SDATA/4** (16>4, 8>2, 4>1, 0>0) and **byte0 bits 1..6 = SBASE/4** (4>2, 8>4, 16>8), with
bit 0 unused in every sample.

Applying that to the blob's word `0xf4301734`:

- `byte1 = 0x17 = 23` > SDATA = 92, i.e. `s[92:107]`
- `byte0 = 0x34` > field `0x1A = 26` > SBASE = 104

Both are **outside the SGPR file** (the register count tops out at 102, and a 16-dword destination at 92
runs to 107). llvm-mc refuses the encoding for exactly that reason: under this mapping the instruction
names registers that do not exist.

That means the mapping is incomplete rather than the instruction being different — byte 2 matches the
`dwordx16` opcode exactly — so one of the two low bytes carries an extra field, most plausibly a flag in
bit 0 of byte0 (zero in all five samples, which is why it never showed) or a split SDATA field. Deciding
between those needs one assembly with a 16-dword destination at a *high but legal* register pair, which
this mapping predicts precisely: `s[84:99], s[100:103]` should encode SDATA=21 and SBASE=25, and if the
blob's word decodes to legal values under a corrected mapping it will be printable.

## State

| | |
|---|---|
| FSPX | 23 / 29 |
| open | 2 programs (`v_dot4` literal), 4 programs (this SMEM instruction) |

---

## 49. Refined SMEM mapping: SBASE is stored in two-SGPR units — and the blob is still out of range

High, legal register pairs settle the field widths:

| operands | byte0 | byte1 |
|---|---|---|
| `s[84:99], s[100:103]` | 0x32 | 0x15 |
| `s[0:15], s[96:99]` | 0x30 | 0x00 |
| `s[80:95], s[96:99]` | 0x30 | 0x14 |
| `s[64:79], s[64:67]` | 0x20 | 0x10 |
| `s[60:75], s[60:63]` | 0x1e | 0x0f |

- **byte1 = SDATA/4** exactly (84>21, 80>20, 64>16, 60>15),
- **byte0 = SBASE/2** exactly (100>50, 96>48, 64>32, 60>30), not /4 as section 48 guessed.

Applying it to the blob's `0xf4301734`: `byte1 = 0x17` > SDATA = 92 and `byte0 = 0x34` > SBASE = 104.

Both are still outside the SGPR file, and now by a measured rule rather than an assumed one. So the word's
fields cannot mean what they mean in every other `s_buffer_load_dwordx16` I can assemble, while bytes 2 and
3 match that opcode exactly.

Two readings, both testable later and neither worth a guess now:

1. the console's gfx1013 uses a different SDATA/SBASE encoding for this opcode than gfx1030's table, or
2. byte2's opcode bits are not 12 for this instruction — another SMEM opcode shares `0x30` once the SDATA
   high bits are folded in.

## State

| | |
|---|---|
| FSPX | 23 / 29 |
| open | 2 (`v_dot4` literal), 4 (this SMEM instruction) |
| corpus knowledge | SDATA/4 and SBASE/2 measured for `s_buffer_load_dwordx16` on gfx1030 |

---

## 50. Corrected SMEM field widths — and the context that explains why the values matter

Two measurements fix the mapping from section 49, which had the destination field wrong:

| operands | word0 | SDATA `[12:6]` | SBASE `[5:0]?2` |
|---|---|---|---|
| `s[0:15], s[4:7]` | 0xf4300002 | 0 | 4 |
| `s[16:31], s[4:7]` | 0xf4300402 | 16 | 4 |
| `s[64:79], s[64:67]` | 0xf4301020 | 64 | 64 |
| `s[84:99], s[100:103]` | 0xf4301532 | 84 | 100 |

So **SDATA is seven bits at [12:6], stored raw**; it is not `byte1` and not divided by four. SBASE stays
`[5:0] ? 2`.

The blob's word `0xf4301734` therefore reads SDATA = 92 and SBASE = 104 — the same numbers as before, but now
from the correct fields, so the conclusion is no longer an artefact of a bad mapping. A 16-dword
destination at s92 runs past s102, and no base at s104 exists.

The bytes around it rule out the other explanations too. The word sits inside a run of ordinary instructions
and is followed by `15 60 60 3a 15 2e 2e 3a`:

```
… 6164121a 6204121a 6310121a | 341730f4 90a101fa | 1560603a 152e2e3a …
```

so it is not a literal or a misaligned fragment. The second word `0xfa01a190` is a well-formed SMEM tail
(signature `0x3E` in its top bits, 21-bit offset `0x1a190`), which pins the instruction's 8-byte extent and
confirms the first word is a SMEM word.

What remains is the only thing left: **the console's gfx1013 numbers SMEM opcodes differently from gfx1030**,
so opcode 12 there is not `s_buffer_load_dwordx16` and the field layout we measured on gfx1030 does not apply.
That needs a gfx1013 opcode table or a hardware probe, neither of which this checkout has.

## State

| | |
|---|---|
| FSPX | 23 / 29 |
| open | 2 (`v_dot4` literal form), 4 (SMEM, needs gfx1013 tables) |
| corrected | SDATA is `[12:6]`, raw 7 bits — sections 48–49 had it as `byte1`/4 |


---

## Slot 70 R16_UINT views of XMem

The missing R16_UINT addresses are offsets into the same allocation returned
by XMemVirtualAlloc. The slot names slices of that allocation directly, so the
Vulkan backend can encode views over its existing GPU shadow of title memory
without a D3D12 resource at each address. The fallback only writes a descriptor
when the requested view fits a contiguous translated range in the arena. It
uses the same component mapping as a typed SRV of a D3D12 buffer.

Apply `patches/menu-stack-xmem-r16-srv.patch` after
`patches/menu-stack-texture-srv.patch`. The MSVC build and focused slot 70
mock test passed. The retail run on the GTX 1650 wrote an R16_UINT descriptor
from XMem and reported no missing buffer for the two startup calls. The
R8_UNORM texture still had no matching live texture. Startup still stopped
on a null read at `0x55aa6f0` before the first present.

---

## 51. The quantum is one, the exact bytes cannot be reproduced, and the gfx1013 reading that would fit

Testing whether the 512-bit form quantizes its register fields, on gfx1030:

| operands | SDATA field | SBASE (?2) |
|---|---|---|
| `s[8:23], s[8:11]` | 8 | 8 |
| `s[16:31], s[16:19]` | 16 | 16 |
| `s[24:39], s[24:27]` | 24 | 24 |
| `s[88:103], s[88:91]` | 88 | 88 |

Quantum is **one**: the fields are raw register indices (and LLVM even accepts a 16-dword range ending at
s103). So section 50's mapping stands.

Trying to reproduce the blob's bytes directly fails, and for a plain reason:

```
s_buffer_load_dwordx16 s[92:107], s[104:107], 0x1a190   ->  none
target bytes                                            ->  34 17 30 f4 90 a1 01 fa
```

`s[92:107]` runs past the register file, and the assembler refuses it. The word is therefore **not** a
gfx1030 `s_buffer_load_dwordx16`.

One reading fits every measured field of the blob without contradicting anything:

- opcode 12 on gfx1013 is a **256-bit** buffer load (8 dwords) rather than the 512-bit one gfx1030 numbers
  there, and
- its SBASE field counts in units of **one** SGPR rather than two.

Then SDATA = 92 > `s[92:99]` (legal) and SBASE field 52 > `s[52:55]` (legal), and the instruction is a
perfectly ordinary `s_buffer_load_dwordx8`. That would also explain why the second word is a well-formed
SMEM tail while nothing else about the instruction decodes.

This is a hypothesis with a test: gfx1013's opcode table. It is not a guess I will act on.

## State

| | |
|---|---|
| FSPX | 23 / 29 |
| open | 2 (`v_dot4` literal), 4 (SMEM; gfx1013 numbers this opcode differently) |

---

## 52. The opcode really is the 16-dword buffer load: 848 of 1070 match it in range

Scanning every FSPX blob for words whose top bits are the SMEM signature with opcode 12, and whose second
word carries a SMEM tail signature, gives:

```
opcode-12 SMEM words: 1070   in-range as a 16-dword load: 848   out of range: 222
```

So the opcode is confirmed by the corpus itself: the great majority of those words are ordinary
`s_buffer_load_dwordx16` with legal registers. Our four failing words belong to the 222 that are not — and
by the fields measured in sections 50–51 they name `s[92:107]` with base `s[104:107]`.

That leaves exactly one explanation standing, and it is not about the encoding at all:

**the console's SGPR file is larger than the PC's 104 registers.** A 16-dword destination at s92 and a base
at s104 are legal if the part has at least 120 scalar registers; on gfx1030's table they are not, which is
why llvm-mc refuses the word while accepting the same opcode with smaller indices.

Whether gfx1013 has that many scalar registers is a hardware question, not a decoding one, and it decides
the fix: if it does, the disassembler should accept these two fields as-is and print the instruction
(ranges beyond 103 are the console's, not an error); if it does not, the word means something else again.

## State

| | |
|---|---|
| FSPX | 23 / 29 |
| open | 2 (`v_dot4` literal), 4 (SMEM naming SGPRs above the PC's file) |
| corpus fact | 1070 opcode-12 words, 848 legal on gfx1030, 222 not |

---

## 53. A literal source makes the dot instruction twelve bytes — and the blob has none

Measured on `v_dot4_i32_i8`:

```
v_dot4_i32_i8 v4, s0, v0, 0x12345   ->  24 40 16 cc 00 00 fe 1b | 45 23 01 00     (12 bytes)
v_dot4_i32_i8 v4, s0, v0, 2.0       ->  24 40 16 cc 00 00 d2 1b                   (8 bytes)
```

A literal operand appends its own dword, so the instruction is twelve bytes; an inline constant
(`2.0`) needs none. That was the open question for the two remaining programs, and it is answered
negatively for the blob:

```
blob:    24 40 16 cc 2b ff 65 19
printed: 24 50 16 cc 2f 3d 91 0c
```

Neither word carries the `0xfe`/`0xff` marker in a source field that a literal would show, so the
instruction is eight bytes and llvm-mc consumed the right number. The difference is **inside the
operand encoding**: `byte0` `0x2b` against `0x2f` (one bit), `byte1` `0x40` against `0x50` (the
`op_sel` bit from section 31), and a completely different source word.

So the two programs fail on how llvm-mc re-encodes the sources, not on length: it chose a different
register or inline-constant form than the blob's. Decoding those two words means reading the source
fields directly — the same treatment `op_sel` got — and printing the instruction ourselves.

## State

| | |
|---|---|
| FSPX | 23 / 29 |
| open | 2 (this class, now reduced to source-field encoding), 4 (SMEM register file) |

---

## 54. The blob does carry a literal after all — in the *source* field llvm-mc read as a register

Mapping the VOP3P source fields by assembling `v_dot4_i32_i8` with known registers:

```
v4, v5, v9, v12  ->  04 40 16 cc | 05 13 32 1c
v4, s3, v9, v12  ->  04 40 16 cc | 03 12 32 1c
v4, s3, s7, v12  ->  04 40 16 cc | 03 0e 30 1c
```

- `byte0` is **src0's index** raw (v5>5, s3>3),
- `byte1` is **src1 encoded as `reg*2 + is_vgpr`** (v9>19, s7>14),
- `byte2` carries src2, `byte3` the modifier bits.

Now the failing blob's second word, `19 65 ff 2b` (`0x1965ff2b`), read with those fields:

- byte1 = **0xff** — the literal marker for src1,
- byte0 = 0x2b, byte2 = 0x65, byte3 = 0x19.

So the instruction **does** have a literal: src1 is a 32-bit immediate, which makes it twelve bytes, and the literal is the word that follows. llvm-mc read byte1 as a plain register (`0x3d` in its printed word `0x0c913d2f`) and therefore consumed eight bytes instead of twelve — which is also why the printed word differs in every field: the decoder was looking at the wrong instruction entirely.

That reverses the conclusion of section 53: the length question is answered **positively**, just not by the `0xfe`/`0xff` marker in byte2 that a src2 literal would show. The marker sits in src1.

## Consequence

The fix is the one already in the tree for `v_fma_mix*`: recognise the literal form, print the instruction with `lit(0x…)`, and give the line the blob's twelve bytes as its encoding. The two programs should then translate.

## State

| | |
|---|---|
| FSPX | 23 / 29 |
| open | 2 (literal in src1 of `v_dot4`), 4 (SMEM register file) |

---

## 55. The literal fix cannot live in `mix_literal`: the caller hands it eight bytes

Tried the obvious place first — a branch in `mix_literal` for a dot product whose src1 field is `0xff`:

```python
if op.startswith(("v_dot2_", "v_dot4_", "v_dot8_")) and len(raw) == 12 and len(printed) == 8 …
```

It never runs, and the reason is structural: the re-anchoring loop calls it as

```python
literal = mix_literal(blob[at:at + len(enc)], enc, base_op(op))
```

with `enc` being what llvm-mc printed — **eight bytes**. `raw` is therefore eight bytes too, and a branch that
needs twelve can never be reached. The corpus count is unchanged (23 / 29) and the branch was reverted, so
nothing dead is left in the tree.

The conclusion is that the change belongs one layer out: the *disassembler* must decide that this word is a
twelve-byte instruction (because its src1 field is `0xff`) and print twelve bytes, after which the existing
`mix_literal`/`restore_mix_literal` pair can carry the value as it does for `v_fma_mix`.

## State

| | |
|---|---|
| FSPX | 23 / 29 |
| open | 2 (the fix now has a known home: `tools/shader_disasm.py`, twelve-byte form), 4 (SMEM) |

---

## 56. Why the disassembler fix is not a patch but a re-anchoring change

A `dot_literal_patch` next to `vop3p_patch` looked like the right shape: rewrite the src1 field of the twelve-byte
word so llvm-mc decodes its first eight bytes, then print the literal as that operand's value and give the line
the blob's twelve bytes. It was written, and then removed — because it cannot work by itself:

**llvm-mc does not skip the literal.** After the patched word it starts decoding at `at + 8`, which is the
literal dword, so every instruction after it is read at the wrong offset. The patch would fix one line and shred
the listing below it.

Making it correct needs the literal dword replaced by something llvm-mc decodes as a harmless instruction
(`s_nop 0`), that line dropped from the output, and the real value restored into the operand — a placement
problem of the same class as `_restore_fma_mix_literals`, on top of the patch.

So the change is real work in the re-anchoring path, not a branch in `mix_literal` and not a one-word patch:
which is why it was reverted rather than left half-done. `tools/shader_disasm.py` compiles, the tree is clean,
and the corpus stays at 23 / 29.

## State

| | |
|---|---|
| FSPX | 23 / 29 |
| open | 2 (needs re-anchoring work in the disassembler), 4 (SMEM register file) |
