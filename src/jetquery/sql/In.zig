const std = @import("std");

/// Generic wrapper for IN queries.
/// Allows users to write `.id = in(i32, ids_slice)` for cleaner syntax.
/// Renders as "= ANY()" in PostgreSQL.
pub fn in(comptime T: type, values: []const T) InExpr(T) {
    return .{ .val = values };
}

/// Generic wrapper for NOT IN queries.
/// Allows users to write `.id = notIn(i32, ids_slice)` for cleaner syntax.
/// Renders as "<> ALL()" in PostgreSQL.
pub fn notIn(comptime T: type, values: []const T) NotInExpr(T) {
    return .{ .val = values };
}

/// Type wrapper for IN expressions.
pub fn InExpr(comptime T: type) type {
    return struct {
        val: []const T,
        
        // Tag to identify this as an IN expression
        pub const __jetquery_in_expr = true;
    };
}

/// Type wrapper for NOT IN expressions.
pub fn NotInExpr(comptime T: type) type {
    return struct {
        val: []const T,
        
        // Tag to identify this as a NOT IN expression
        pub const __jetquery_not_in_expr = true;
    };
}

/// Determines if a type is an IN expression.
pub fn isInExpr(comptime T: type) bool {
    return @hasDecl(T, "__jetquery_in_expr");
}

/// Determines if a type is a NOT IN expression.
pub fn isNotInExpr(comptime T: type) bool {
    return @hasDecl(T, "__jetquery_not_in_expr");
}