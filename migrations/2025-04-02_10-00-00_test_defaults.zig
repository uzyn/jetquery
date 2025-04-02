const std = @import("std");
const jetquery = @import("jetquery");
const t = jetquery.schema.table;

// This migration is for testing column default values
pub fn up(repo: anytype) !void {
    try repo.createTable(
        "defaults_test",
        &.{
            t.primaryKey("id", .{}),
            // String default with quotes
            t.column("name", .string, .{ .default = "'Unknown'" }),
            // Integer default
            t.column("count", .integer, .{ .default = "42" }),
            // Boolean default 
            t.column("active", .boolean, .{ .default = "true" }),
            // Text default with special characters
            t.column("description", .text, .{ .default = "'This is a default description with ''quotes'' and other special characters!'" }),
            // Float default
            t.column("score", .float, .{ .default = "3.14" }),
            // Field WITHOUT default (should not have DEFAULT in SQL)
            t.column("no_default", .string, .{ .optional = true }),
            // Decimal default
            t.column("price", .decimal, .{ .default = "19.99" }),
            // Smallint default
            t.column("small_count", .smallint, .{ .default = "5" }),
            // Bigint default
            t.column("big_count", .bigint, .{ .default = "9223372036854775807" }),
            // Double precision default
            t.column("precise_value", .double_precision, .{ .default = "3.141592653589793" }),
            // DateTime default using now()
            t.column("last_update", .datetime, .{ .default = "now()" }),
            // Timestamps
            t.timestamps(.{}),
        },
        .{},
    );
}

pub fn down(repo: anytype) !void {
    try repo.dropTable("defaults_test", .{});
}
