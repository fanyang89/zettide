# utf8proc vendoring

- Upstream: <https://github.com/JuliaStrings/utf8proc>
- Release: `v2.11.3`
- Commit: `e5e799221b45bbb90f5fdc5c69b6b8dfbf017e78`
- Unicode data: `17.0.0`

The source, generated Unicode data, public header, and upstream license are
vendored without modification. Zettide compiles the library statically with
`UTF8PROC_STATIC` so every platform uses the same normalization and case-fold
tables.
