# Kestrel

Console → PC. Static recompilation of the Xbox Series build of *Grand Theft Auto VI*,
run on your own machine from your own copy.

No game data, no keys, no executable in this repository. Nothing here decrypts or works
around protection. Everything the build produces stays on your disk.

---

## Status

| Stage | State |
|---|---|
| package check (1.0.2.1) | 108 files, executable present |
| shaders carved from `shaders.rpf` | 26,506 containers |
| native RDNA2 unpack (FSSM, gfx1013) | 26,503 blobs, 0 problems |
| disassembly (`llvm-mc` 21, AMDGPU) | 26,503 / 26,503 |
| translation to SPIR-V | 26,503, wave64 emulation on |
| runtime build (`gta6rt`, MSVC, 316 targets) | builds |
| first boot | image mapped, imports bound, TLS callbacks run, entry entered |
| **blocked on** | title reads its static TLS through TEB slot 0 |

The first boot reaches the title's own startup code and dies there, in the static
initialisation path, because the executable assumes it is the first TLS module in the
process — which it is on the console and is not on Windows. Everything below that line is
still unwritten: no device, no mount, no frame.

## What is proven

- The package layout is the reference 1.0.2.1 Xbox Series layout; all 108 files match.
- All 26,503 shaders translate to SPIR-V and pass `spirv-val`.
- The loader maps the real executable, its five modules, resolves 63 shimmed imports,
  432 host imports, 72 module imports; 20 are unimplemented, all audio.
- `xgameruntime.lib`'s missing `XErrorReport` export was a fatal assert; it is served now.

## What is not

Nothing after static initialisation. Not the D3D12 device, not RPF9 mounting, not a
single draw. See [docs/FINDINGS.md](docs/FINDINGS.md) for the two crashes that were
chased down and the one that is still open.

## Attribution

Kestrel continues the work of the **Leonida** project by [ItsNotRexed](https://github.com/ItsNotRexed),
which went offline on 2026-11-24. The recompiler, the D3D12→Vulkan layer, the shader
translator and the loader are theirs; the toolchain in this repository descends from it
under GPL-3.0. A mirror with the integration forge is preserved at
[avivetech/Leonida](https://github.com/avivetech/Leonida).

Without their work none of this would run at all.

## License

GPL-3.0-or-later, inherited. Third-party code keeps its own license.
