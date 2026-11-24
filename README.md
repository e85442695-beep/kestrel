# Kestrel

Console → PC. Static recompilation of the Xbox Series build of *Grand Theft Auto VI*,
run on your own machine from your own copy.

No game data, no keys, no executable in this repository. Nothing here decrypts or works
around protection. Everything the build produces stays on your disk.

---

## Status

| Stage | State |
|---|---|
| Package check (1.0.2.1) | 108 files present |
| Shader archive | 26,503 FSSM programs translated and validated with `spirv-val` |
| Runtime | Builds from the Leonida forge checkout on Windows |
| Startup | `menu-stack` maps four modules with zero unresolved imports, passes TLS initialization and opens files through DirectStorage |
| Vulkan presentation | The render loop submits frames successfully. The previous visible run had a black frame. A usable menu is still unverified. |

Kestrel's build wrapper uses a sibling `Kestrel-upstream` checkout by default.
Set `KESTREL_SOURCE` to use a different checkout or `KESTREL_PYTHON` to point to
a Python 3.12+ interpreter outside PATH.

See [docs/FINDINGS.md](docs/FINDINGS.md) for the tested revisions and startup
diagnostics.

## Attribution

Kestrel continues the work of the **Leonida** project by [ItsNotRexed](https://github.com/ItsNotRexed),
which went offline on 2026-11-24. The recompiler, the D3D12→Vulkan layer, the shader
translator and the loader are theirs; the toolchain in this repository descends from it
under GPL-3.0. A mirror with the integration forge is preserved at
[avivetech/Leonida](https://github.com/avivetech/Leonida).

Without their work none of this would run at all.

## License

GPL-3.0-or-later, inherited. Third-party code keeps its own license.
