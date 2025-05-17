const std = @import("std");
const mem = std.mem;

/// Encodes a Zig slice into a PostgreSQL array parameter format.
/// PostgreSQL array literals use the syntax '{1,2,3}' for arrays.
/// Returns a string in the appropriate format.
pub fn encodeSliceAsArray(allocator: mem.Allocator, slice: anytype) ![]const u8 {
    const T = @TypeOf(slice);
    const SliceInfo = @typeInfo(T).Pointer;
    const ElementType = SliceInfo.child;

    // We'll start with an opening brace
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try buffer.append('{');

    // Add each element, separated by commas
    for (slice, 0..) |element, index| {
        if (index > 0) {
            try buffer.append(',');
        }

        // Encode the element based on its type
        switch (@typeInfo(ElementType)) {
            .Int, .ComptimeInt => {
                // For integers, just convert to string
                try std.fmt.format(buffer.writer(), "{d}", .{element});
            },
            .Float, .ComptimeFloat => {
                // For floats, ensure proper formatting
                try std.fmt.format(buffer.writer(), "{d}", .{element});
            },
            .Bool => {
                // Booleans as lowercase true/false
                try buffer.writer().writeAll(if (element) "true" else "false");
            },
            .Pointer => |ptr_info| {
                if (ptr_info.size == .Slice and ptr_info.child == u8) {
                    // Strings need to be quoted and escaped
                    try buffer.append('"');
                    
                    // Escape any double quotes in the string
                    for (element) |char| {
                        if (char == '"') {
                            try buffer.append('\\');
                        }
                        try buffer.append(char);
                    }
                    
                    try buffer.append('"');
                } else {
                    // Other pointer types are not supported
                    @compileError("Unsupported array element type: " ++ @typeName(ElementType));
                }
            },
            .Optional => |opt_info| {
                if (element) |value| {
                    // Recursively handle the value
                    const encoded = try encodeSliceAsArray(allocator, &[_]opt_info.child{value});
                    try buffer.writer().writeAll(encoded[1..encoded.len-1]); // Strip the outer braces
                } else {
                    // NULL value
                    try buffer.writer().writeAll("NULL");
                }
            },
            else => {
                // Other types are not supported
                @compileError("Unsupported array element type: " ++ @typeName(ElementType));
            },
        }
    }

    try buffer.append('}');
    
    return buffer.toOwnedSlice();
}

/// Helper function to determine if a type is a slice
pub fn isSlice(comptime T: type) bool {
    // Check if the type is a slice by comparing to known slice types
    // This is a simpler approach that works well for our use case
    if (@typeInfo(T) != .Pointer) return false;
    
    const ptr_info = @typeInfo(T).Pointer;
    return ptr_info.size == .Slice;
}