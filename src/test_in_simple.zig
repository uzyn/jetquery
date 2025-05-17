const std = @import("std");
const jetquery = @import("jetquery.zig");

// Create a simple test schema with just a User model
const TestSchema = struct {
    pub const User = jetquery.Model(
        @This(),
        "users",
        struct {
            id: i32,
            name: []const u8,
        },
        .{}
    );
};

// Main function that will test our IN query implementation
pub fn main() !void {
    std.debug.print("Testing IN query functionality...\n", .{});
    
    // Sample data
    const ids = &[_]i32{ 1, 2, 3 };
    
    // Test 1: Using the in() helper function
    {
        const query = jetquery.Query(.postgresql, TestSchema, .User)
            .where(.{ .id = jetquery.sql.in(i32, ids) });
        
        const sql_statement = query.sql;
        std.debug.print("Test 1 SQL: {s}\n", .{sql_statement});
        
        // Check if it contains the expected ANY syntax
        const expected = "\"users\".\"id\" = ANY $1";
        const contains = std.mem.indexOf(u8, sql_statement, expected) != null;
        
        if (contains) {
            std.debug.print("Test 1 PASSED ✓\n", .{});
        } else {
            std.debug.print("Test 1 FAILED ✗\n", .{});
            std.debug.print("Expected to find: {s}\n", .{expected});
            return error.TestFailed;
        }
    }
    
    // Test 2: Using explicit .in_ operator
    {
        const query = jetquery.Query(.postgresql, TestSchema, .User)
            .where(.{ .id = .{ .in_ = ids } });
        
        const sql_statement = query.sql;
        std.debug.print("Test 2 SQL: {s}\n", .{sql_statement});
        
        // Check if it contains the expected ANY syntax
        const expected = "\"users\".\"id\" = ANY $1";
        const contains = std.mem.indexOf(u8, sql_statement, expected) != null;
        
        if (contains) {
            std.debug.print("Test 2 PASSED ✓\n", .{});
        } else {
            std.debug.print("Test 2 FAILED ✗\n", .{});
            std.debug.print("Expected to find: {s}\n", .{expected});
            return error.TestFailed;
        }
    }
    
    // Test 3: Using the notIn() helper function
    {
        const query = jetquery.Query(.postgresql, TestSchema, .User)
            .where(.{ .id = jetquery.sql.notIn(i32, ids) });
        
        const sql_statement = query.sql;
        std.debug.print("Test 3 SQL: {s}\n", .{sql_statement});
        
        // Check if it contains the expected ALL syntax
        const expected = "\"users\".\"id\" <> ALL $1";
        const contains = std.mem.indexOf(u8, sql_statement, expected) != null;
        
        if (contains) {
            std.debug.print("Test 3 PASSED ✓\n", .{});
        } else {
            std.debug.print("Test 3 FAILED ✗\n", .{});
            std.debug.print("Expected to find: {s}\n", .{expected});
            return error.TestFailed;
        }
    }
    
    std.debug.print("All basic IN/NOT IN tests passed!\n", .{});
}