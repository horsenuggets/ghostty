const std = @import("std");
const font = @import("../main.zig");

/// Standard bitmap graphics table (sbix).
///
/// This struct is focused purely on the operations we need for Ghostty,
/// namely to be able to look up whether a glyph ID has an actual bitmap
/// in the table, rather than assuming every glyph in a sbix-having font
/// is colored. It is not meant to be a general purpose sbix table reader.
///
/// References:
/// - https://learn.microsoft.com/en-us/typography/opentype/spec/sbix
/// - https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6sbix.html
pub const SBIX = struct {
    /// Raw bytes of the whole sbix table. We keep a reference to use for
    /// per-glyph length lookups, since the offsets array sits inside the
    /// first strike's body.
    data: []const u8,

    /// Byte offset, from the start of the table, to the first strike's
    /// glyphDataOffsets array. We use this strike's offset array as the
    /// per-glyph length authority: a glyph is considered bitmap-bearing
    /// if its entry has non-zero byte length. In practice every strike
    /// agrees on which glyphs are populated, so checking one strike is
    /// sufficient.
    offsets_pos: usize,

    /// Number of glyphs whose offsets are stored in this strike's
    /// glyphDataOffsets array. The array length is `num_glyphs + 1` so
    /// the per-glyph length can be derived as
    /// `offsets[gid + 1] - offsets[gid]`.
    num_glyphs: u16,

    pub fn init(data: []const u8, num_glyphs: u16) error{
        EndOfStream,
        SBIXVersionNotSupported,
        SBIXNoStrikes,
    }!SBIX {
        var fbs = std.io.fixedBufferStream(data);
        const reader = fbs.reader();

        // Version
        const version = try reader.readInt(u16, .big);
        if (version != 1) {
            return error.SBIXVersionNotSupported;
        }

        // Flags
        _ = try reader.readInt(u16, .big);

        // numStrikes — the count of bitmap strikes (different ppem levels).
        // Every strike contains an offset for every glyph in the font, so we
        // only need to look at one to know which glyphs have bitmaps.
        const num_strikes = try reader.readInt(u32, .big);
        if (num_strikes == 0) return error.SBIXNoStrikes;

        // Offset to the first strike, from the start of the sbix table.
        const strike_offset = try reader.readInt(u32, .big);

        // The strike starts with ppem + ppi (uint16 each), then the
        // glyphDataOffsets array begins. There are `num_glyphs + 1` entries
        // so the last entry marks the end of the final glyph's data.
        const offsets_pos: usize = @as(usize, strike_offset) + 4;

        // Make sure the offsets array actually fits inside the table data.
        const needed_bytes = offsets_pos + @as(usize, num_glyphs + 1) * @sizeOf(u32);
        if (needed_bytes > data.len) return error.EndOfStream;

        return .{
            .data = data,
            .offsets_pos = offsets_pos,
            .num_glyphs = num_glyphs,
        };
    }

    /// Returns true if the given glyph ID has bitmap data in the sbix table.
    /// This is the value we use to decide whether to route the glyph through
    /// the color rasterization path. Glyphs without bitmaps fall through to
    /// `glyf`/`CFF ` outlines and should be drawn as monochrome text.
    pub fn hasGlyph(self: SBIX, glyph_id: u16) bool {
        if (glyph_id >= self.num_glyphs) return false;

        // Read offsets[gid] and offsets[gid + 1] as big-endian u32. A glyph
        // has a bitmap iff the offsets differ (i.e. the data span has
        // non-zero length).
        const entry_size: usize = @sizeOf(u32);
        const start_pos = self.offsets_pos + @as(usize, glyph_id) * entry_size;
        const end_pos = start_pos + entry_size;
        if (end_pos + entry_size > self.data.len) return false;

        const start = std.mem.readInt(u32, self.data[start_pos..][0..4], .big);
        const end = std.mem.readInt(u32, self.data[end_pos..][0..4], .big);
        return end > start;
    }
};

test "SBIX" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Apple Color Emoji on macOS is the canonical sbix font.
    const testFont = font.embedded.regular;
    _ = testFont;
    _ = alloc;

    // Smoke test: malformed (too short) buffer returns an error rather than
    // panicking. The actual glyph-level behavior is covered by integration
    // tests in `coretext.zig`'s `ColorState` setup.
    const empty: []const u8 = &.{};
    try testing.expectError(error.EndOfStream, SBIX.init(empty, 100));
}
