# Portable Name Profile

## Status

`portable-v1` is persisted in v2.1 container headers when selected with
`--name-profile portable-v1`. Existing images and newly created images without
that option use the v2.0 `legacy-raw` profile and retain byte-exact,
case-sensitive namespace behavior. `portable-v1` is not yet enforced by
`Volume`, FUSE, WinFsp, or macFUSE.

## Stable Contract

`portable-v1` pins utf8proc 2.11.3 and Unicode 17.0.0. A component is prepared
as follows:

1. Reject input longer than 1,020 bytes before normalization.
2. Require assigned, valid UTF-8 according to the pinned Unicode data.
3. Normalize the persisted spelling to NFC.
4. Build the lookup key by applying Unicode default case folding and NFC.
5. Require at most 255 UTF-8 bytes and 255 UTF-16 code units after NFC.
6. Reject empty components, `.` and `..`, ASCII control characters, DEL,
   Windows-forbidden punctuation, and trailing ASCII spaces or periods.
7. Reject Windows device names, including extension forms, numbered COM/LPT
   names, superscript-number variants, `CLOCK$`, `CONIN$`, and `CONOUT$`.

The spelling is case-preserving. The lookup key is locale-independent and must
be unique within a directory. A case-only or normalization-only rename may
change the persisted spelling without changing object identity.

Symbolic-link targets are path text and are not component-normalized as a whole.
Each component is resolved under the active profile when the target is followed.

## Compatibility

The library and Unicode versions are part of the profile definition, not build
environment details. Changing either requires a new profile identifier or proof
that every accepted spelling and lookup key is unchanged. Runtime tests verify
both embedded version strings and representative normalization/case-fold vectors.
