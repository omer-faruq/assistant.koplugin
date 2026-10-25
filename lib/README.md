# lib/ — native hoedown binaries

The `lib/<arch>/libhoedown.so.3` files are built from
[boypt/hoedown4eink](https://github.com/boypt/hoedown4eink), which
cross-compiles upstream `hoedown` plus `lua-resty-hoedown` for KOReader's
e-ink targets (koxtoolchain and Android NDK, including Docker-based builds).

For build details, toolchain versions, and reproducible build steps, see
that repository directly.