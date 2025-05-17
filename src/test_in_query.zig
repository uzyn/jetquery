const std = @import("std");
const jetquery = @import("jetquery.zig");

const testing = std.testing;

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

// Test: IN query using helper function with integer array
test "IN query with integer array using In helper" {
    // Sample data
    const ids = &[_]i32{ 1, 2, 3 };
    
    // Use the In helper (which doesn't exist yet, so this will fail)
    const query = jetquery.Query(.postgresql, TestSchema, .User)
        .where(.{ .id = jetquery.sql.In(i32, ids) });
    
    // This should generate SQL with ANY operator
    const sql = query.render();
    try testing.expectStringContains(sql, "\"users\".\"id\" = ANY($1)");
}

// Test: NOT IN query using helper function with integer array
test "NOT IN query with integer array using NotIn helper" {
    const ids = &[_]i32{ 1, 2, 3 };
    
    const query = jetquery.Query(.postgresql, TestSchema, .User)
        .where(.{ .id = jetquery.sql.NotIn(i32, ids) });
    
    const sql = query.render();
    try testing.expectStringContains(sql, "\"users\".\"id\" <> ALL($1)");
}

// Test: IN query using explicit .in_ operator
test "IN query with integer array using explicit .in_ operator" {
    const ids = &[_]i32{ 1, 2, 3 };
    
    const query = jetquery.Query(.postgresql, TestSchema, .User)
        .where(.{ .id = .{ .in_ = ids } });
    
    const sql = query.render();
    try testing.expectStringContains(sql, "\"users\".\"id\" = ANY($1)");
}

// Test: NOT IN query using explicit .not_in operator
test "NOT IN query with integer array using explicit .not_in operator" {
    const ids = &[_]i32{ 1, 2, 3 };
    
    const query = jetquery.Query(.postgresql, TestSchema, .User)
        .where(.{ .id = .{ .not_in = ids } });
    
    const sql = query.render();
    try testing.expectStringContains(sql, "\"users\".\"id\" <> ALL($1)");
}

// Test: IN query with strings
test "IN query with string array" {
    const statuses = &[_][]const u8{ "active", "pending", "approved" };
    
    const query = jetquery.Query(.postgresql, TestSchema, .User)
        .where(.{ .status = jetquery.sql.In([]const u8, statuses) });
    
    const sql = query.render();
    try testing.expectStringContains(sql, "\"users\".\"status\" = ANY($1)");
}

// Test: IN query with empty array
test "IN query with empty array" {
    const empty_ids = &[_]i32{};
    
    const query = jetquery.Query(.postgresql, TestSchema, .User)
        .where(.{ .id = jetquery.sql.In(i32, empty_ids) });
    
    const sql = query.render();
    try testing.expectStringContains(sql, "\"users\".\"id\" = ANY($1)");
}

// Test: Complex query combining IN with other conditions
test "Complex query with IN and other conditions" {
    const ids = &[_]i32{ 1, 2, 3 };
    
    const query = jetquery.Query(.postgresql, TestSchema, .User)
        .where(.{
            .id = jetquery.sql.In(i32, ids),
            .status = "active",
        });
    
    const sql = query.render();
    try testing.expectStringContains(sql, "\"users\".\"id\" = ANY($1)");
    try testing.expectStringContains(sql, "\"users\".\"status\" = $2");
}

// Test: OR conditions with IN
test "OR conditions with IN query" {
    const user_ids = &[_]i32{ 1, 2, 3 };
    const post_ids = &[_]i32{ 4, 5, 6 };
    
    const query = jetquery.Query(.postgresql, TestSchema, .Post)
        .where(.{
            .{
                .id = jetquery.sql.In(i32, post_ids),
            },
            .OR,
            .{
                .user_id = jetquery.sql.In(i32, user_ids),
            },
        });
    
    const sql = query.render();
    try testing.expectStringContains(sql, "\"posts\".\"id\" = ANY($1)");
    try testing.expectStringContains(sql, "\"posts\".\"user_id\" = ANY($2)");
    try testing.expectStringContains(sql, "OR");
}

// Test: Nested queries with relations using IN
test "Query with relations using IN" {
    const ids = &[_]i32{ 1, 2, 3 };
    
    const query = jetquery.Query(.postgresql, TestSchema, .Post)
        .where(.{
            .user = .{
                .id = jetquery.sql.In(i32, ids),
            },
        });
    
    const sql = query.render();
    try testing.expectStringContains(sql, "\"user\".\"id\" = ANY($1)");
}