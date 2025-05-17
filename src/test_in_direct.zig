const std = @import("std");
const jetquery = @import("jetquery.zig");

pub fn main() !void {
    std.debug.print("Testing IN query functionality...\n", .{});
    
    // Define a simple test schema
    const TestSchema = struct {
        pub const User = jetquery.Model(
            @This(),
            "users",
            struct {
                id: i32,
                name: []const u8,
                email: []const u8,
                status: []const u8,
            },
            .{}
        );
    };

    // Sample data
    const ids = &[_]i32{ 1, 2, 3 };
    
    // Use the in helper (which tests our implementation)
    const query = jetquery.Query(.postgresql, TestSchema, .User)
        .where(.{ .id = jetquery.sql.in(i32, ids) });
    
    // Get the SQL directly
    const sql_statement = query.sql;
    std.debug.print("SQL statement: {s}\n", .{sql_statement});
    
    if (std.mem.indexOf(u8, sql_statement, "\"users\".\"id\" = ANY($1)") != null) {
        std.debug.print("Test passed ✓\n", .{});
    } else {
        std.debug.print("Test failed ✗\n", .{});
        return error.TestFailed;
    }
    
    // Test the explicit .in_ operator
    const query2 = jetquery.Query(.postgresql, TestSchema, .User)
        .where(.{ .id = .{ .in_ = ids } });
    
    // Get the SQL directly
    const sql_statement2 = query2.sql;
    std.debug.print("SQL statement (explicit operator): {s}\n", .{sql_statement2});
    
    if (std.mem.indexOf(u8, sql_statement2, "\"users\".\"id\" = ANY($1)") != null) {
        std.debug.print("Test passed ✓\n", .{});
    } else {
        std.debug.print("Test failed ✗\n", .{});
        return error.TestFailed;
    }
    
    std.debug.print("All tests passed!\n", .{});
}