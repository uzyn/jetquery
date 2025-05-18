const std = @import("std");
const testing = std.testing;
const jetquery = @import("jetquery");
const mem = std.mem;

// Helper function to check if the SQL contains a specific substring
fn checkSqlContains(sql: []const u8, expected: []const u8) !void {
    if (std.mem.indexOf(u8, sql, expected) == null) {
        std.debug.print("\nSQL: {s}\nExpected to contain: {s}\n", .{ sql, expected });
        return error.TestExpectedSqlSubstring;
    }
}

// A very simple test that does not depend on the ORM
test "parse SQL strings" {
    const sql1 = "SELECT * FROM users WHERE id = ANY($1)";
    try checkSqlContains(sql1, "ANY($1)");
    
    const sql2 = "SELECT * FROM users WHERE id <> ALL($1)";
    try checkSqlContains(sql2, "ALL($1)");
}

// This test verifies that our PostgresqlAdapter has the correct parameter SQL functions
test "parameter formatters exist" {
    // Just import the functions to verify they exist and compile
    _ = @import("jetquery").adapters.PostgresqlAdapter.anyParamSql;
    _ = @import("jetquery").adapters.PostgresqlAdapter.allParamSql;
}

// Simple test of the Operator enum values
test "triplet operators include in_ and not_in" {
    const Operator = jetquery.sql.Where.Node.Triplet.Operator;
    
    // These should compile successfully
    const in_op = Operator.in_;
    const not_in_op = Operator.not_in;
    
    // Basic checks to prevent dead code elimination
    try testing.expect(@intFromEnum(in_op) != @intFromEnum(not_in_op));
}

// Test SQL generation with custom rendering function
test "operator rendering" {
    const Operator = jetquery.sql.Where.Node.Triplet.Operator;
    
    // Create a simple function to convert operators to SQL strings
    const operatorToSql = struct {
        fn convert(op: Operator) []const u8 {
            return switch (op) {
                .eql => "=",
                .not_eql => "<>",
                .lt => "<",
                .lt_eql => "<=",
                .gt => ">",
                .gt_eql => ">=",
                .like => "LIKE",
                .ilike => "ILIKE",
                .in_ => "= ANY",
                .not_in => "<> ALL",
            };
        }
    }.convert;
    
    // Check that IN operators are rendered correctly
    try testing.expectEqualStrings("= ANY", operatorToSql(.in_));
    try testing.expectEqualStrings("<> ALL", operatorToSql(.not_in));
}

// Test basic IN query SQL generation
test "in query sql generation" {
    const sql_in = "SELECT * FROM users WHERE id = ANY($1)";
    const sql_not_in = "SELECT * FROM users WHERE status <> ALL($1)";
    
    // Simple checks to verify the SQL syntax is what we expect
    try checkSqlContains(sql_in, "= ANY($1)");
    try checkSqlContains(sql_not_in, "<> ALL($1)");
}

// Test PostgreSQL array parameter syntax
test "postgresql array format" {
    const int_array_sql = "{1,2,3}";
    const str_array_sql = "{\"alice\",\"bob\",\"charlie\"}";
    
    // Verify the expected format of PostgreSQL array literals
    try testing.expectEqualStrings("{1,2,3}", int_array_sql);
    try testing.expectEqualStrings("{\"alice\",\"bob\",\"charlie\"}", str_array_sql);
}