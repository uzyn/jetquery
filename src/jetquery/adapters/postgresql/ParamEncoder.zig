const std = @import("std");
const mem = std.mem;

/// Encodes a Zig slice into a PostgreSQL array parameter format.
/// PostgreSQL array literals use the syntax '{1,2,3}' for arrays.
pub fn encodeSliceAsArray(allocator: mem.Allocator, slice: anytype) ![]const u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try buffer.append('{');
    
    // Add each element, separated by commas
    for (slice, 0..) |element, index| {
        if (index > 0) {
            try buffer.append(',');
        }

        switch (@TypeOf(element)) {
            // String types need special escaping
            []const u8, []u8 => {
                try escapeStringForArray(buffer.writer(), element);
            },
            // Numeric types are formatted directly
            i8, i16, i32, i64, u8, u16, u32, u64, f32, f64 => {
                try std.fmt.format(buffer.writer(), "{}", .{element});
            },
            // Boolean values
            bool => {
                try buffer.appendSlice(if (element) "true" else "false");
            },
            // Handle other types by converting to string for now
            else => {
                try std.fmt.format(buffer.writer(), "{any}", .{element});
            },
        }
    }

    try buffer.append('}');
    return buffer.toOwnedSlice();
}

/// Escapes a string for use in a PostgreSQL array.
/// This handles escaping quotes and special characters.
fn escapeStringForArray(writer: anytype, string: []const u8) !void {
    try writer.writeByte('"');
    
    for (string) |char| {
        switch (char) {
            '"' => try writer.writeAll("\\\""),  // Escape double quotes
            '\\' => try writer.writeAll("\\\\"), // Escape backslashes
            else => try writer.writeByte(char),
        }
    }
    
    try writer.writeByte('"');
}