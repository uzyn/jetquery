const std = @import("std");
const jetquery = @import("jetquery");
const t = jetquery.schema.table;

pub fn up(repo: anytype) !void {
    try repo.createTable(
        "cats",
        &.{
            t.primaryKey("id", .{}),
            t.column("name", .string, .{ .unique = true }),
            t.column("paws", .integer, .{ .index = true }),
            t.column("human_id", .integer, .{ .reference = .{ "humans", "id" } }),
            t.timestamps(.{}),
        },
        .{},
    );

    // Create an index using the built-in method
    try repo.createIndex("cats", &.{ "name", "paws" }, .{});
    
    // Alternative approach using raw SQL to add a unique constraint
    // This demonstrates how to use raw SQL for operations not fully supported by JetQuery
    try repo.executeSqlRaw(
        "ALTER TABLE cats ADD CONSTRAINT unique_name_paws UNIQUE (name, paws)",
    );
}

pub fn down(repo: anytype) !void {
    // Raw SQL can also be used in the down function
    try repo.executeSqlRaw(
        "ALTER TABLE cats DROP CONSTRAINT IF EXISTS unique_name_paws",
    );
    
    try repo.dropTable("cats", .{});
}
