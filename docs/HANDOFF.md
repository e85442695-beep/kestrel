# Handoff: the two open shader classes

Written at the end of a long session, so a fresh one can continue without re-deriving anything. Every
number here comes from `FINDINGS.md`; the section is named next to it.

## Where the corpus stands

```
29 FSPX programs unpacked from amd_fidelityfx_upscaler_xbox.dll
23 translated, 23 pass spirv-val
 4 fall through into undecodable words        -> class A (section 47-52)
 2 refused by the encoding check              -> class B (section 53-56)
```

The runtime's FidelityFX index (`D:\Leonida-work\shaders\spirv\fspx`) carries the 23; the game asks for none
of the missing ones. So both classes are *corpus* work, not blockers for a run.

## Class A — four programs, one SMEM instruction

The word is `0xf4301734`, followed by a well-formed SMEM tail (`0xfa01a190`). Top bits `0x3D` are the SMEM
encoding; opcode field `[25:18]` is 12, which on gfx1030 is `s_buffer_load_dwordx16` — and the corpus agrees:
1070 such words, 848 of them legal, so the opcode is not in doubt.

Measured field layout, gfx1030, by assembling with known registers:

| field | bits | encoding |
|---|---|---|
| SDATA | `[12:6]` | raw register index, quantum 1 |
| SBASE | `[5:0]` | register index / 2 |
| opcode | `[25:18]` | 12 = 16-dword buffer load |

The blob decodes to SDATA = 92 and SBASE = 104. A 16-dword destination at s92 runs past s103, and no base
at s104 exists — so llvm-mc refuses it and cannot reproduce the bytes:

```
s_buffer_load_dwordx16 s[92:107], s[104:107], 0x1a190  ->  none
```

**Open question, one measurement:** does the console's gfx1013 have a larger scalar register file than the
PC's 104? If yes, the disassembler should accept these two fields as they are (ranges past s103 are the
console's, not an error) and print the instruction; that closes all four programs. If no, the word means
something else and the opcode table of gfx1013 is needed — the checkout has no gfx1013 decoder
(`--mcpu gfx1013` gives 5889 invalid words in one program against 1 on gfx1030).

## Class B — two programs, a literal llvm-mc misreads

Blob against llvm-mc's printing:

```
blob:    24 40 16 cc | 2b ff 65 19
printed: 24 50 16 cc | 2f 3d 91 0c
```

Source-field layout of `v_dot4_i32_i8` (VOP3P), measured by assembly:

- `byte0` = src0 index raw,
- `byte1` = src1 as `reg*2 + is_vgpr`,
- `byte2` carries src2, `byte3` the modifier bits.

The blob's `byte1` is `0xff`: **src1 is a 32-bit literal**, so the instruction is twelve bytes and the
literal is the dword after it. llvm-mc read the field as a register, decoded eight bytes and re-encoded the
word — which is why every field differs and why the listing below that point is shifted.

Two placements were tried and both are wrong, recorded in sections 55 and 56:

- a branch in `mix_literal` — unreachable, the caller passes eight bytes;
- a one-word patch `dot_literal_patch` — llvm-mc then decodes the literal dword as an instruction, so the
  rest of the file misaligns.

**The fix is in the re-anchoring path of `tools/shader_disasm.py`:** replace the literal dword with a
decodable filler (`s_nop 0`), drop that line from the listing, print the literal as src1's value
(`lit(0x…)`) and give the line the blob's twelve bytes. The value-carrying half already exists:
`restore_mix_literal` sets any source whose field is `0xff` to the literal.

Check afterwards that `v_fma_mix*` still translate — they use the same helper and are the reason it is not
being changed casually.

## Rules that shaped this

- No guessing encodings: every rule above was measured by assembly or cited from AMD's own emulator
  (`rocjitsu`, `rdna2/vop3p.h`, `vop3p_exec.cpp`, cited in section 44).
- A field is only forgiven when it is proved not to change semantics (section 46); differences that change
  which register or constant is read are not tolerated (section 30).
- Every experiment that failed is written down with the reason it failed (sections 40, 42, 55, 56), so the
  same path is not walked twice.
