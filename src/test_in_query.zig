const std = @import("std");
const jetquery = @import("jetquery.zig");

// Test schema for all tests
const TestSchema = struct {
    pub const User = jetquery.Model(
        @This(),
        "users",
        struct {
            id: i32,
            name: []const u8,
            email: []const u8,
            status: []const u8,
            created_at: jetquery.DateTime,
        },
        .{}
    );

    pub const Post = jetquery.Model(
        @This(),
        "posts",
        struct {
            id: i32,
            title: []const u8,
            user_id: i32,
        },
        .{
            .relations = .{
                .user = jetquery.relation.belongsTo(.User, .{}),
            },
        }
    );
};

// Helper function to check if SQL contains a string
fn checkSqlContains(sql: []const u8, substr: []const u8) !void {
    const contains = std.mem.indexOf(u8, sql, substr) != null;
    if (!contains) {
        std.debug.print("Expected SQL to contain: {s}\nActual SQL: {s}\n", .{ substr, sql });
        return error.SqlDoesNotContainExpectedSubstring;
    }
}

// Test: IN query using helper function with integer array
test "IN query with integer array using in helper" {
    // Sample data
    const ids = &[_]i32{ 1, 2, 3 };
    
    // Use the in helper
    const query = jetquery.Query(.postgresql, TestSchema, .User)
        .where(.{ .id = jetquery.sql.in(i32, ids) });
    
    // Get the SQL directly via the public sql field
    const sql_statement = query.sql;
    try checkSqlContains(sql_statement, "\"users\".\"id\" = ANY $1");
}

// Test: NOT IN query using helper function with integer array
test "NOT IN query with integer array using notIn helper" {
    const ids = &[_]i32{ 1, 2, 3 };
    
    const query = jetquery.Query(.postgresql, TestSchema, .User)
        .where(.{ .id = jetquery.sql.notIn(i32, ids) });
    
    const sql_statement = query.sql;
    try checkSqlContains(sql_statement, "\"users\".\"id\" <> ALL $1");
}

// Test: IN query using explicit .in_ operator
test "IN query with integer array using explicit .in_ operator" {
    const ids = &[_]i32{ 1, 2, 3 };
    
    const query = jetquery.Query(.postgresql, TestSchema, .User)
        .where(.{ .id = .{ .in_ = ids } });
    
    const sql_statement = query.sql;
    try checkSqlContains(sql_statement, "\"users\".\"id\" = ANY $1");
}

// Test: NOT IN query using explicit .not_in operator
test "NOT IN query with integer array using explicit .not_in operator" {
    const ids = &[_]i32{ 1, 2, 3 };
    
    const query = jetquery.Query(.postgresql, TestSchema, .User)
        .where(.{ .id = .{ .not_in = ids } });
    
    const sql_statement = query.sql;
    try checkSqlContains(sql_statement, "\"users\".\"id\" <> ALL $1");
}

// Test: IN query with strings
test "IN query with string array" {
    const statuses = &[_][]const u8{ "active", "pending", "approved" };
    
    const query = jetquery.Query(.postgresql, TestSchema, .User)
        .where(.{ .status = jetquery.sql.in([]const u8, statuses) });
    
    const sql_statement = query.sql;
    try checkSqlContains(sql_statement, "\"users\".\"status\" = ANY $1");
}

// Test: IN query with empty array
test "IN query with empty array" {
    const empty_ids = &[_]i32{};
    
    const query = jetquery.Query(.postgresql, TestSchema, .User)
        .where(.{ .id = jetquery.sql.in(i32, empty_ids) });
    
    const sql_statement = query.sql;
    try checkSqlContains(sql_statement, "\"users\".\"id\" = ANY $1");
}

// Test: Complex query combining IN with other conditions
test "Complex query with IN and other conditions" {
    const ids = &[_]i32{ 1, 2, 3 };
    
    const query = jetquery.Query(.postgresql, TestSchema, .User)
        .where(.{
            .id = jetquery.sql.in(i32, ids),
            .status = "active",
        });
    
    const sql_statement = query.sql;
    try checkSqlContains(sql_statement, "\"users\".\"id\" = ANY $1");
    try checkSqlContains(sql_statement, "\"users\".\"status\" = $2");
}

// Test: OR conditions with IN
test "OR conditions with IN query" {
    const user_ids = &[_]i32{ 1, 2, 3 };
    const post_ids = &[_]i32{ 4, 5, 6 };
    
    const query = jetquery.Query(.postgresql, TestSchema, .Post)
        .where(.{
            .{
                .id = jetquery.sql.in(i32, post_ids),
            },
            .OR,
            .{
                .user_id = jetquery.sql.in(i32, user_ids),
            },
        });
    
    const sql_statement = query.sql;
    try checkSqlContains(sql_statement, "\"posts\".\"id\" = ANY $1");
    try checkSqlContains(sql_statement, "\"posts\".\"user_id\" = ANY $2");
    try checkSqlContains(sql_statement, "OR");
}

// Test: Nested queries with relations using IN
test "Query with relations using IN" {
    const ids = &[_]i32{ 1, 2, 3 };
    
    // Using the Post model with a relation to User
    // This should generate a JOIN with the users table
    // and apply the IN condition to the user.id column
    const query = jetquery.Query(.postgresql, TestSchema, .Post)
        .join(.inner, .user) // Add an explicit join to make sure the user table is included
        .where(.{
            .user = .{
                .id = jetquery.sql.in(i32, ids),
            },
        });
    
    const sql_statement = query.sql;
    try checkSqlContains(sql_statement, "\"user\".\"id\" = ANY $1");
}