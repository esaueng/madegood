#ifndef CZLIB_H
#define CZLIB_H

#include <zlib.h>

/// deflateInit2 with gzip framing (RFC 1952). zlib's init functions are
/// macros, which Swift cannot call directly.
static inline int czlib_deflate_init_gzip(z_streamp stream, int level) {
    return deflateInit2(stream, level, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY);
}

/// inflateInit2 accepting gzip framing only.
static inline int czlib_inflate_init_gzip(z_streamp stream) {
    return inflateInit2(stream, 15 + 16);
}

#endif
