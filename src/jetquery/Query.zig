const std = @import("std");

const jetcommon = @import("jetcommon");

const jetquery = @import("../jetquery.zig");

const coercion = @import("coercion.zig");
const sql = @import("sql.zig");

// Number of rows expected to be returned by a query.
const ResultContext = enum { one, many, none };

/// Create a new query by passing a table definition.
/// ```zig
/// const query = Query(.postgresql, Schema, .Cat);
/// ```
///
/// For convenience, use `repo.Query(.Cat)`.
pub fn Query(adapter: jetquery.adapters.Name, Schema: type, comptime model: anytype) type {
    const Adapter = jetquery.adapters.Type(adapter);
    const Model = switch (@typeInfo(@TypeOf(model))) {
        .enum_literal => @field(Schema, @tagName(std.enums.nameCast(
            std.meta.DeclEnum(Schema),
            model,
        ))),
        else => switch (@TypeOf(model)) {
            type => model,
            []const u8 => @field(Schema, @tagName(std.enums.nameCast(
                std.meta.DeclEnum(Schema),
                model,
            ))),
            else => @compileError("Expected enum literal, []const u8, or type, found `" ++ @typeName(@TypeOf(model)) ++ "`"),
        },
    };

    @setEvalBranchQuota(10000);
    return struct {
        table: Model,

        pub const Definition = Model.Definition;
        pub const info = .{
            .Model = Model,
            .Schema = Schema,
        };

        /// Create a `SELECT` query with the specified `columns`, e.g.:
        /// ```zig
        /// Query(.postgresql, Schema, .MyTable).select(.{ .foo, .bar }).where(.{ .foo = "qux" });
        /// ```
        /// Pass an empty `columns` array to select all columns:
        /// ```zig
        /// Query(.postgresql, Schema, .MyTable).select(.{}).where(.{ .foo = "qux" });
        /// ```
        pub fn select(
            comptime columns: anytype,
        ) @TypeOf(InitialStatement(Adapter, Schema, Model).select(columns)) {
            return InitialStatement(Adapter, Schema, Model).select(columns);
        }

        /// Create a `SELECT` query defaulting to all columns selected:
        /// ```zig
        /// Query(.postgresql, Schema, .MyTable).where(.{ .foo = "bar" })
        /// ```
        /// Short-hand for:
        /// ```zig
        /// Query(.postgresql, Schema, .MyTable).select(.{}).where(.{ .foo = "bar" })
        /// ```
        pub fn where(args: anytype) @TypeOf(InitialStatement(Adapter, Schema, Model).where(args)) {
            return InitialStatement(Adapter, Schema, Model).where(args);
        }

        /// Create an `UPDATE` query with the specified `args`. As a safety measure, an
        /// `update()` query **must** have a `.where()` clause attached or it will not be
        /// executed. Use `deleteAll()` if you wish to delete all records.
        /// ```zig
        /// Query(.postgresql, Schema, .MyTable).update(.{ .foo = "bar", .baz = "qux" }).where(.{ .quux = "corge" });
        /// ```
        pub fn update(args: anytype) @TypeOf(InitialStatement(Adapter, Schema, Model).update(args)) {
            return InitialStatement(Adapter, Schema, Model).update(args);
        }

        /// Create an `UPDATE` query that does not require a `WHERE` clause to update all records
        /// in a table.
        /// ```zig
        /// Query(.postgresql, Schema, .MyTable).updateAll(.{ .foo = "bar", .baz = "qux" });
        /// ```
        pub fn updateAll(args: anytype) @TypeOf(InitialStatement(Adapter, Schema, Model).updateAll(args)) {
            return InitialStatement(Adapter, Schema, Model).updateAll(args);
        }
        /// Create an `INSERT` query with the specified `args`, e.g.:
        /// ```zig
        /// Query(.postgresql, Schema, .MyTable).insert(.{ .foo = "bar", .baz = "qux" });
        /// ```
        pub fn insert(args: anytype) @TypeOf(InitialStatement(Adapter, Schema, Model).insert(args)) {
            return InitialStatement(Adapter, Schema, Model).insert(args);
        }

        pub fn returning(comptime columns: anytype) @TypeOf(InitialStatement(Adapter, Schema, Model).returning(columns)) {
            return InitialStatement(Adapter, Schema, Model).returning(columns);
        }

        /// Create a `DELETE` query. As a safety measure, a `delete()` query **must** have a
        /// `.where()` clause attached or it will not be executed. Use `deleteAll()` if you wish
        /// to delete all records.
        /// ```zig
        /// Query(.postgresql, Schema, .MyTable).delete().where(.{ .foo = "bar" });
        /// ```
        pub fn delete() @TypeOf(InitialStatement(Adapter, Schema, Model).delete()) {
            return InitialStatement(Adapter, Schema, Model).delete();
        }

        /// Create a `DELETE` query that does not require a `WHERE` clause to delete all records
        /// from a table.
        /// ```zig
        /// Query(.postgresql, Schema, .MyTable).deleteAll();
        /// ```
        pub fn deleteAll() @TypeOf(InitialStatement(Adapter, Schema, Model).deleteAll()) {
            return InitialStatement(Adapter, Schema, Model).deleteAll();
        }

        /// Create a `SELECT` query to return a single row matching the given ID.
        /// ```zig
        /// Query(.postgresql, Schema, .MyTable).find(1000);
        /// ```
        /// Short-hand for:
        /// ```zig
        /// Query(.postgresql, Schema, .MyTable).select(.{}).where(.{ .id = id }).limit(1);
        /// ```
        pub fn find(id: anytype) @TypeOf(InitialStatement(Adapter, Schema, Model).find(id)) {
            return InitialStatement(Adapter, Schema, Model).find(id);
        }

        /// Create a `SELECT` query to return a single row matching the given args.
        /// ```zig
        /// Query(.postgresql, Schema, .MyTable).findBy(.{ .foo = "bar", .baz = "qux" });
        /// ```
        /// Short-hand for:
        /// ```zig
        /// Query(.postgresql, Schema, .MyTable).select(.{}).where(args).limit(1);
        /// ```
        pub fn findBy(args: anytype) @TypeOf(InitialStatement(Adapter, Schema, Model).findBy(args)) {
            return InitialStatement(Adapter, Schema, Model).findBy(args);
        }

        /// Return all records from the current table.
        /// ```zig
        /// try Query(Schema, .MyTable).all(repo);
        /// ```
        pub fn all(
            repo: anytype,
        ) @TypeOf(InitialStatement(Adapter, Schema, Model).select(.{}).all(repo)) {
            return InitialStatement(Adapter, Schema, Model).select(.{}).all(repo);
        }

        /// Return the first record from the current table.
        /// ```zig
        /// try Query(Schema, .MyTable).first(repo);
        /// ```
        pub fn first(
            repo: anytype,
        ) @TypeOf(InitialStatement(Adapter, Schema, Model).select(.{}).first(repo)) {
            return InitialStatement(Adapter, Schema, Model).select(.{}).first(repo);
        }

        /// Indicate that a relation should be fetched with this query. Pass options to control
        /// the behaviour of the generated query.
        ///
        /// Select all columns and all rows of the association:
        /// ```zig
        /// Query(.postgresql, Schema, .MyTable).include(.my_relation, .{});
        /// ```
        /// Select specific columns:
        /// ```zig
        /// Query(.postgresql, Schema, .MyTable).include(.my_relation, .{ .select = .{ .foo, .bar } });
        /// ```
        /// Pass `limit` to limit the number of rows fetched for `hasMany` relations. This option
        /// is not supported for `belongsTo` relations. Note that the limit applies to the sum of
        /// all related records from the base result set so this option is only recommended when
        /// using `find` and `findBy`, e.g. fetch 1 blog post and 10 associated comments.
        /// ```zig
        /// Query(.postgresql, Schema, .MyTable).include(.my_relation, .{ .limit = 10 });
        /// ```
        pub fn include(
            comptime name: jetquery.relation.RelationsEnum(Model),
            comptime include_options: anytype,
        ) @TypeOf(InitialStatement(Adapter, Schema, Model).include(name, include_options)) {
            return InitialStatement(Adapter, Schema, Model).include(name, include_options);
        }

        /// Join to another table by association name. Columns on the joined table are not
        /// included in the result set. Use `include` to fetch associations, use `join` to filter
        /// results.
        /// ```zig
        /// Query(.postgresql, Schema, .MyTable).join(.inner, .my_relation);
        /// ```
        /// If required, call `.select` after a `.join` to specify association columns to select:
        /// ```zig
        /// Query(.postgresql, Schema, .MyTable).join(.inner, .my_relation)
        ///     .select(.{ .foo, .my_relation = .{ .bar, .baz } })
        /// ```
        pub fn join(
            comptime join_context: jetquery.relation.JoinContext,
            comptime name: jetquery.relation.RelationsEnum(Model),
        ) @TypeOf(InitialStatement(Adapter, Schema, Model).join(join_context, name)) {
            return InitialStatement(Adapter, Schema, Model).join(join_context, name);
        }

        /// Create a `SELECT DISTINCT` query with the specified `columns`, e.g.:
        /// ```zig
        /// Query(.postgresql, Schema, .MyTable).distinct(.{ .foo, .bar }).where(.{ .foo = "qux" });
        /// ```
        ///
        /// ```zig
        /// Query(.postgresql, Schema, .MyTable)
        ///     .include(.my_relation)
        ///     .distinct(.{ .foo, .{ .my_relation = .{.bar} });
        /// ```
        pub fn distinct(
            comptime columns: anytype,
        ) @TypeOf(InitialStatement(Adapter, Schema, Model).distinct(columns)) {
            return InitialStatement(Adapter, Schema, Model).distinct(columns);
        }

        /// Apply a `GROUP BY` clause to the query, e.g.:
        /// ```zig
        /// Query(.postgresql, Schema, .MyTable).groupBy(.{ .foo, .{ .my_relation = .{.bar} })
        /// ```
        pub fn groupBy(
            comptime args: anytype,
        ) @TypeOf(InitialStatement(Adapter, Schema, Model).groupBy(args)) {
            return InitialStatement(Adapter, Schema, Model).groupBy(args);
        }

        /// Apply an `ORDER BY` clause to the query, e.g.:
        /// ```zig
        /// Query(.postgresql, Schema, .MyTable).orderBy(.{.foo});
        /// Query(.postgresql, Schema, .MyTable).orderBy(.{ .foo = .descending });
        /// Query(.postgresql, Schema, .MyTable).orderBy(.{ .foo, .{ .my_relattion = .{.bar} } });
        ///
        pub fn orderBy(
            comptime args: anytype,
        ) @TypeOf(InitialStatement(Adapter, Schema, Model).orderBy(args)) {
            return InitialStatement(Adapter, Schema, Model).orderBy(args);
        }

        /// Select a `COUNT` from the result set.
        pub fn count() @TypeOf(InitialStatement(Adapter, Schema, Model).count()) {
            return InitialStatement(Adapter, Schema, Model).count();
        }
    };
}

const MissingField = struct {
    missing: void,
};

fn InitialStatement(
    Adapter: type,
    Schema: type,
    Model: type,
) Statement(Adapter, .none, Schema, Model, .{
    .result_context = .none,
    .default_select = true,
}) {
    return Statement(Adapter, .none, Schema, Model, .{
        .result_context = .none,
        .default_select = true,
    }){ .values = .{}, .errors = .{} };
}

fn SchemaTable(Schema: type, comptime name: std.meta.DeclEnum(Schema)) type {
    return @field(Schema, @tagName(name));
}

fn StatementOptions(comptime query_context: sql.QueryContext) type {
    return struct {
        relations: []const type = &.{},
        field_infos: []const jetquery.fields.FieldInfo = &.{},
        columns: []const jetquery.columns.Column = &.{},
        order_clauses: []const sql.OrderClause = &.{},
        where_clauses: []const sql.Where.Tree = &.{},
        result_context: ResultContext = defaultResultContext(query_context),
        default_select: bool = false,
        distinct: ?[]const jetquery.columns.Column = null,
        group_by: ?[]const jetquery.columns.Column = null,
        having_clauses: []const sql.Where.Tree = &.{},

        pub fn orderClauses(self: @This(), Model: type) []const sql.OrderClause {
            if (query_context != .select) return self.order_clauses;
            if (self.order_clauses.len > 0) return self.order_clauses;
            // We could force ordering by one of the grouped columns but this seems like
            // overreaching - we should only apply a default order on ungrouped select queries.
            if (self.group_by != null) return self.order_clauses;

            return Model.defaultOrderBy();
        }
    };
}

fn defaultResultContext(query_context: sql.QueryContext) ResultContext {
    return switch (query_context) {
        .select => .many,
        .update, .update_all, .insert, .delete, .delete_all, .none => .none,
        .count, .returning => .one,
    };
}

pub const AuxiliaryQuery = struct {
    query: type,
    relation: type,

    pub fn baseQuery(comptime self: AuxiliaryQuery) self.BaseQuery() {
        const q = self.query.select(.{});
        const q_order = if (self.relation.order_by) |order_by|
            q._orderBy(order_by)
        else
            q;

        const q_limit = if (self.relation.limit) |limit|
            q_order.limit(limit)
        else
            q_order;

        return q_limit;
    }

    fn BaseQuery(comptime self: AuxiliaryQuery) type {
        const q = self.query.select(.{});
        const q_order = if (self.relation.order_by) |order_by|
            q._orderBy(order_by)
        else
            q;

        const q_limit = if (self.relation.limit) |limit|
            q_order.limit(limit)
        else
            q_order;

        return @TypeOf(q_limit);
    }
};

fn Statement(
    Adapter: type,
    comptime query_context: sql.QueryContext,
    Schema: type,
    Model: type,
    comptime options: StatementOptions(query_context),
) type {
    return struct {
        values: jetquery.fields.FieldValues(Model, options.relations, options.field_infos),
        limit_bound: ?u64 = null,
        errors: [options.field_infos.len]?anyerror,

        comptime query_context: sql.QueryContext = query_context,
        comptime field_infos: []const jetquery.fields.FieldInfo = options.field_infos,
        comptime columns: []const jetquery.columns.Column = options.columns,
        comptime order_clauses: []const sql.OrderClause = options.order_clauses,
        comptime auxiliary_queries: []const AuxiliaryQuery = &auxiliaryQueries(),
        comptime sql: []const u8 = render(),

        pub const info = .{
            .Model = Model,
            .Schema = Schema,
        };

        pub const Definition = Model.Definition;
        pub const ResultContext = options.result_context;
        pub const ResultType = QueryResultType();
        pub const ColumnInfos = QueryColumnInfos();
        pub const relations = options.relations;
        pub const where_clauses = options.where_clauses;

        const Self = @This();

        pub fn render() []const u8 {
            comptime {
                return jetquery.sql.render(
                    Adapter,
                    query_context,
                    Model,
                    options.relations,
                    options.field_infos,
                    options.columns,
                    options.orderClauses(Model),
                    options.distinct,
                    options.where_clauses,
                    options.group_by,
                    options.having_clauses,
                );
            }
        }

        pub fn extend(
            self: Self,
            S: type,
            args: anytype,
            comptime context: jetquery.fields.FieldContext,
        ) S {
            validateQueryContext(self.query_context, query_context);

            var statement: S = undefined;

            inline for (0..self.field_infos.len) |index| {
                const value = self.values[index];
                @field(statement.values, std.fmt.comptimePrint("{}", .{index})) = value;
                statement.errors[index] = self.errors[index];
            }

            @setEvalBranchQuota(10000);
            const tree = sql.Where.tree(
                Adapter,
                Model,
                options.relations,
                @TypeOf(args),
                context,
                self.field_infos.len,
            );
            const clause_values = tree.values(Adapter, args);

            const arg_values = clause_values.values;
            const arg_errors = clause_values.errors;

            inline for (options.field_infos.len.., arg_values, arg_errors) |field_index, value, err| {
                @field(statement.values, std.fmt.comptimePrint("{d}", .{field_index})) = value;

                statement.errors[field_index] = err;
            }

            updateTimestamps(S, &statement, statement.query_context);

            return statement;
        }

        pub fn select(
            self: Self,
            comptime select_columns: anytype,
        ) Statement(Adapter, .select, Schema, Model, .{
            .relations = options.relations,
            .field_infos = options.field_infos,
            .columns = &jetquery.columns.translate(Model, options.relations, select_columns, .{}),
            .order_clauses = options.order_clauses,
            .where_clauses = options.where_clauses,
            .group_by = options.group_by,
            .distinct = options.distinct,
            .result_context = if (options.default_select) .many else options.result_context,
        }) {
            const S = Statement(Adapter, .select, Schema, Model, .{
                .relations = options.relations,
                .field_infos = options.field_infos,
                .columns = &jetquery.columns.translate(Model, options.relations, select_columns, .{}),
                .order_clauses = options.order_clauses,
                .where_clauses = options.where_clauses,
                .group_by = options.group_by,
                .distinct = options.distinct,
                .result_context = if (options.default_select) .many else options.result_context,
            });
            return self.extend(S, .{}, .none);
        }

        /// Apply a `WHERE` clause to the current statement.
        pub fn where(self: Self, args: anytype) Statement(
            Adapter,
            switch (query_context) {
                .none => .select,
                else => |tag| tag,
            },
            Schema,
            Model,
            .{
                .relations = options.relations,
                .where_clauses = options.where_clauses ++ .{
                    sql.Where.tree(
                        Adapter,
                        Model,
                        options.relations,
                        @TypeOf(args),
                        .where,
                        options.field_infos.len,
                    ),
                },
                .field_infos = options.field_infos ++ jetquery.fields.fieldInfos(
                    Adapter,
                    Model,
                    options.relations,
                    @TypeOf(args),
                    .where,
                ),
                .columns = if (options.default_select) &Model.columns() else options.columns,
                .order_clauses = options.order_clauses,
                .group_by = options.group_by,
                .distinct = options.distinct,
                .result_context = switch (options.result_context) {
                    .none => switch (query_context) {
                        .none => defaultResultContext(.select),
                        else => |tag| defaultResultContext(tag),
                    },
                    else => |tag| tag,
                },
                .default_select = options.default_select,
            },
        ) {
            const S = Statement(Adapter, switch (query_context) {
                .none => .select,
                else => |tag| tag,
            }, Schema, Model, .{
                .relations = options.relations,
                .field_infos = options.field_infos ++ jetquery.fields.fieldInfos(
                    Adapter,
                    Model,
                    options.relations,
                    @TypeOf(args),
                    .where,
                ),
                .where_clauses = options.where_clauses ++ .{sql.Where.tree(
                    Adapter,
                    Model,
                    options.relations,
                    @TypeOf(args),
                    .where,
                    options.field_infos.len,
                )},
                .columns = if (options.default_select) &Model.columns() else options.columns,
                .order_clauses = options.order_clauses,
                .group_by = options.group_by,
                .distinct = options.distinct,
                .result_context = switch (options.result_context) {
                    .none => switch (query_context) {
                        .none => defaultResultContext(.select),
                        else => |tag| defaultResultContext(tag),
                    },
                    else => |tag| tag,
                },
                .default_select = options.default_select,
            });
            return self.extend(S, args, .where);
        }

        pub fn find(self: Self, id: anytype) @TypeOf(self.findBy(.{ .id = id })) {
            // TODO: Use configured primary key instead of `id`
            // No need to verify `id` presence as `jetquery.fields.fieldInfos` will reject unknown fields.
            return self.findBy(.{ .id = id });
        }

        pub fn findBy(self: Self, args: anytype) Statement(Adapter, .select, Schema, Model, .{
            .relations = options.relations,
            .field_infos = options.field_infos ++
                jetquery.fields.fieldInfos(Adapter, Model, options.relations, @TypeOf(args), .where) ++
                jetquery.fields.fieldInfos(Adapter, Model, options.relations, @TypeOf(.{1}), .limit),
            .columns = if (options.columns.len == 0) &Model.columns() else options.columns,
            .where_clauses = &.{sql.Where.tree(
                Adapter,
                Model,
                &.{},
                @TypeOf(args),
                .where,
                options.field_infos.len,
            )},
            .group_by = options.group_by,
            .result_context = .one,
        }) {
            const S = Statement(Adapter, .select, Schema, Model, .{
                .relations = options.relations,
                .field_infos = options.field_infos ++
                    jetquery.fields.fieldInfos(Adapter, Model, options.relations, @TypeOf(args), .where) ++
                    jetquery.fields.fieldInfos(Adapter, Model, options.relations, @TypeOf(.{1}), .limit),
                .columns = if (options.columns.len == 0) &Model.columns() else options.columns,
                .where_clauses = &.{sql.Where.tree(Adapter, Model, &.{}, @TypeOf(args), .where, options.field_infos.len)},
                .group_by = options.group_by,
                .result_context = .one,
            });
            var statement = self.extend(S, args, .where);
            const arg_fields = std.meta.fields(@TypeOf(args));
            statement.values[options.field_infos.len + arg_fields.len] = 1;
            statement.errors[options.field_infos.len + arg_fields.len] = null;
            return statement;
        }

        pub fn count(self: Self) Statement(Adapter, .count, Schema, Model, .{
            .relations = options.relations,
            .field_infos = options.field_infos,
            .distinct = options.distinct,
            .where_clauses = options.where_clauses,
            .group_by = options.group_by,
        }) {
            const S = Statement(Adapter, .count, Schema, Model, .{
                .relations = options.relations,
                .field_infos = options.field_infos,
                .distinct = options.distinct,
                .where_clauses = options.where_clauses,
                .group_by = options.group_by,
            });
            return self.extend(S, .{}, .none);
        }

        pub fn distinct(self: Self, comptime args: anytype) Statement(Adapter, .select, Schema, Model, .{
            .relations = options.relations,
            .field_infos = options.field_infos,
            .columns = &.{},
            .order_clauses = options.order_clauses,
            .result_context = .many,
            .distinct = &jetquery.columns.translate(Model, options.relations, args, .{}),
            .where_clauses = options.where_clauses,
            .group_by = options.group_by,
        }) {
            const S = Statement(Adapter, .select, Schema, Model, .{
                .relations = options.relations,
                .field_infos = options.field_infos,
                .columns = &.{},
                .order_clauses = options.order_clauses,
                .result_context = .many,
                .distinct = &jetquery.columns.translate(Model, options.relations, args, .{}),
                .where_clauses = options.where_clauses,
                .group_by = options.group_by,
            });
            if (!options.default_select) @compileError(
                std.fmt.comptimePrint(
                    "Failed attempting to set distinct columns when `select` already invoked. " ++
                        "Use `Model.distinct(...)` to issue a distinct query.",
                    .{},
                ),
            );

            return self.extend(S, .{}, .none);
        }

        pub fn update(self: Self, args: anytype) Statement(Adapter, .update, Schema, Model, .{
            .field_infos = &(jetquery.fields.fieldInfos(Adapter, Model, &.{}, @TypeOf(args), .update) ++
                timestampsFields(Adapter, Model, .update)),
        }) {
            const S = Statement(Adapter, .update, Schema, Model, .{
                .field_infos = &(jetquery.fields.fieldInfos(Adapter, Model, &.{}, @TypeOf(args), .update) ++
                    timestampsFields(Adapter, Model, .update)),
            });
            return self.extend(S, args, .update);
        }

        pub fn updateAll(self: Self, args: anytype) Statement(Adapter, .update_all, Schema, Model, .{
            .field_infos = &(jetquery.fields.fieldInfos(Adapter, Model, &.{}, @TypeOf(args), .update) ++
                timestampsFields(Adapter, Model, .update)),
        }) {
            const S = Statement(Adapter, .update_all, Schema, Model, .{
                .field_infos = &(jetquery.fields.fieldInfos(Adapter, Model, &.{}, @TypeOf(args), .update) ++
                    timestampsFields(Adapter, Model, .update)),
            });
            return self.extend(S, args, .update);
        }

        pub fn insert(self: Self, args: anytype) Statement(Adapter, .insert, Schema, Model, .{
            .field_infos = &(jetquery.fields.fieldInfos(Adapter, Model, &.{}, @TypeOf(args), .insert) ++
                timestampsFields(Adapter, Model, .insert)),
        }) {
            const S = Statement(Adapter, .insert, Schema, Model, .{
                .field_infos = &(jetquery.fields.fieldInfos(Adapter, Model, &.{}, @TypeOf(args), .insert) ++
                    timestampsFields(Adapter, Model, .insert)),
            });
            return self.extend(S, args, .insert);
        }

        /// Return a subset of columns from the inserted record. An empty array will return all columns.
        pub fn returning(
            self: Self,
            comptime return_columns: anytype,
        ) Statement(Adapter, .returning, Schema, Model, .{
            .relations = options.relations,
            .field_infos = options.field_infos,
            .columns = &jetquery.columns.translate(Model, options.relations, return_columns, .{}),
            .order_clauses = options.order_clauses,
            .group_by = options.group_by,
            .distinct = options.distinct,
            .result_context = .one,
        }) {
            const S = Statement(Adapter, .returning, Schema, Model, .{
                .relations = options.relations,
                .field_infos = options.field_infos,
                .columns = &jetquery.columns.translate(Model, options.relations, return_columns, .{}),
                .order_clauses = options.order_clauses,
                .group_by = options.group_by,
                .distinct = options.distinct,
                .result_context = .one,
            });
            return self.extend(S, .{}, .returning);
        }

        pub fn delete(self: Self) Statement(Adapter, .delete, Schema, Model, .{
            .field_infos = &jetquery.fields.fieldInfos(Adapter, Model, &.{}, @TypeOf(.{}), .none),
            .where_clauses = options.where_clauses,
        }) {
            // TODO: Add support for `DELETE ... USING ...`
            if (comptime options.relations.len != 0) @compileError(
                "Failed attempting to generate `DELETE` query with relations. " ++
                    "This error occurred to prevent accidential deletion of potentially unexpected behaviour.",
            );
            const S = Statement(Adapter, .delete, Schema, Model, .{
                .field_infos = &jetquery.fields.fieldInfos(Adapter, Model, &.{}, @TypeOf(.{}), .none),
                .where_clauses = options.where_clauses,
            });
            return self.extend(S, .{}, .none);
        }

        pub fn deleteAll(self: Self) Statement(Adapter, .delete_all, Schema, Model, .{}) {
            // TODO: Add support for `DELETE ... USING ...`
            if (comptime options.relations.len != 0) @compileError(
                "Failed attempting to generate `DELETE` query with relations. " ++
                    "This error occurred to prevent accidential deletion or potentially unexpected behaviour.",
            );
            const S = Statement(Adapter, .delete_all, Schema, Model, .{});
            return self.extend(S, .{}, .none);
        }

        pub fn limit(self: Self, bound: u64) Statement(Adapter, query_context, Schema, Model, .{
            .relations = options.relations,
            .field_infos = options.field_infos ++ jetquery.fields.fieldInfos(Adapter, Model, &.{}, @TypeOf(.{bound}), .limit),
            .columns = options.columns,
            .order_clauses = options.order_clauses,
            .result_context = options.result_context,
            .where_clauses = options.where_clauses,
            .group_by = options.group_by,
            .having_clauses = options.having_clauses,
        }) {
            const S = Statement(Adapter, query_context, Schema, Model, .{
                .relations = options.relations,
                .field_infos = options.field_infos ++ jetquery.fields.fieldInfos(Adapter, Model, &.{}, @TypeOf(.{bound}), .limit),
                .columns = options.columns,
                .order_clauses = options.order_clauses,
                .result_context = options.result_context,
                .where_clauses = options.where_clauses,
                .group_by = options.group_by,
                .having_clauses = options.having_clauses,
            });
            return self.extend(S, .{bound}, .limit);
        }

        pub fn offset(self: Self, bound: u64) Statement(Adapter, query_context, Schema, Model, .{
            .relations = options.relations,
            .field_infos = options.field_infos ++ jetquery.fields.fieldInfos(Adapter, Model, &.{}, @TypeOf(.{bound}), .offset),
            .columns = options.columns,
            .order_clauses = options.order_clauses,
            .result_context = options.result_context,
            .where_clauses = options.where_clauses,
            .group_by = options.group_by,
            .having_clauses = options.having_clauses,
        }) {
            const S = Statement(Adapter, query_context, Schema, Model, .{
                .relations = options.relations,
                .field_infos = options.field_infos ++ jetquery.fields.fieldInfos(Adapter, Model, &.{}, @TypeOf(.{bound}), .offset),
                .columns = options.columns,
                .order_clauses = options.order_clauses,
                .result_context = options.result_context,
                .where_clauses = options.where_clauses,
                .group_by = options.group_by,
                .having_clauses = options.having_clauses,
            });
            return self.extend(S, .{bound}, .offset);
        }

        pub fn orderBy(self: Self, comptime args: anytype) Statement(
            Adapter,
            switch (query_context) {
                .none => .select,
                else => query_context,
            },
            Schema,
            Model,
            .{
                .relations = options.relations,
                .field_infos = options.field_infos,
                .columns = switch (query_context) {
                    .none => &Model.columns(),
                    else => options.columns,
                },
                .order_clauses = &sql.translateOrderBy(Model, options.relations, args),
                .result_context = switch (options.result_context) {
                    .none => .many,
                    else => options.result_context,
                },
                .where_clauses = options.where_clauses,
                .group_by = options.group_by,
                .having_clauses = options.having_clauses,
            },
        ) {
            const S = Statement(
                Adapter,
                switch (query_context) {
                    .none => .select,
                    else => query_context,
                },
                Schema,
                Model,
                .{
                    .relations = options.relations,
                    .field_infos = options.field_infos,
                    .columns = switch (query_context) {
                        .none => &Model.columns(),
                        else => options.columns,
                    },
                    .order_clauses = &sql.translateOrderBy(Model, options.relations, args),
                    .result_context = switch (options.result_context) {
                        .none => .many,
                        else => options.result_context,
                    },
                    .where_clauses = options.where_clauses,
                    .group_by = options.group_by,
                    .having_clauses = options.having_clauses,
                },
            );
            return self.extend(S, .{}, .order);
        }

        pub fn groupBy(self: Self, comptime columns: anytype) Statement(Adapter, .select, Schema, Model, .{
            .relations = options.relations,
            .field_infos = options.field_infos,
            .columns = options.columns,
            .order_clauses = options.order_clauses,
            .result_context = .many,
            .where_clauses = options.where_clauses,
            .group_by = &jetquery.columns.translate(Model, options.relations, columns, .{}),
            .having_clauses = options.having_clauses,
        }) {
            const S = Statement(Adapter, .select, Schema, Model, .{
                .relations = options.relations,
                .field_infos = options.field_infos,
                .columns = options.columns,
                .order_clauses = options.order_clauses,
                .group_by = &jetquery.columns.translate(Model, options.relations, columns, .{}),
                .result_context = .many,
                .where_clauses = options.where_clauses,
                .having_clauses = options.having_clauses,
            });
            return self.extend(S, .{}, .none);
        }

        pub fn having(self: Self, args: anytype) Statement(Adapter, .select, Schema, Model, .{
            .relations = options.relations,
            .field_infos = options.field_infos ++ jetquery.fields.fieldInfos(
                Adapter,
                Model,
                options.relations,
                @TypeOf(args),
                .where,
            ),
            .columns = options.columns,
            .order_clauses = options.order_clauses,
            .result_context = .many,
            .where_clauses = options.where_clauses,
            .group_by = options.group_by,
            .having_clauses = options.having_clauses ++
                .{sql.Where.tree(
                    Adapter,
                    Model,
                    options.relations,
                    @TypeOf(args),
                    .where,
                    options.field_infos.len,
                )},
        }) {
            const S = Statement(Adapter, .select, Schema, Model, .{
                .relations = options.relations,
                .field_infos = options.field_infos ++ jetquery.fields.fieldInfos(
                    Adapter,
                    Model,
                    options.relations,
                    @TypeOf(args),
                    .where,
                ),
                .columns = options.columns,
                .order_clauses = options.order_clauses,
                .result_context = .many,
                .where_clauses = options.where_clauses,
                .group_by = options.group_by,
                .having_clauses = options.having_clauses ++
                    .{sql.Where.tree(
                        Adapter,
                        Model,
                        options.relations,
                        @TypeOf(args),
                        .where,
                        options.field_infos.len,
                    )},
            });
            return self.extend(S, args, .none);
        }

        pub fn include(
            self: Self,
            comptime name: jetquery.relation.RelationsEnum(Model),
            comptime include_options: anytype,
        ) Statement(Adapter, switch (query_context) {
            .none => .select,
            else => |tag| tag,
        }, Schema, Model, .{
            .relations = jetquery.relation.concatRelations(
                options.relations,
                Schema,
                Model,
                name,
                jetquery.relation.translateRelationOptions(Schema, Model, name, include_options),
                .include,
            ),
            .field_infos = options.field_infos,
            .columns = switch (query_context) {
                .none => &Model.columns(),
                else => options.columns,
            },
            .order_clauses = options.order_clauses,
            .result_context = switch (options.result_context) {
                .none => .many,
                else => |tag| tag,
            },
            .default_select = options.default_select,
            .where_clauses = options.where_clauses,
            .having_clauses = options.having_clauses,
        }) {
            const S = Statement(Adapter, switch (query_context) {
                .none => .select,
                else => |tag| tag,
            }, Schema, Model, .{
                .relations = jetquery.relation.concatRelations(
                    options.relations,
                    Schema,
                    Model,
                    name,
                    jetquery.relation.translateRelationOptions(
                        Schema,
                        Model,
                        name,
                        include_options,
                    ),
                    .include,
                ),
                .field_infos = options.field_infos,
                .columns = switch (query_context) {
                    .none => &Model.columns(),
                    else => options.columns,
                },
                .order_clauses = options.order_clauses,
                .result_context = switch (options.result_context) {
                    .none => .many,
                    else => |tag| tag,
                },
                .default_select = options.default_select,
                .where_clauses = options.where_clauses,
                .having_clauses = options.having_clauses,
            });
            return self.extend(S, .{}, .none);
        }

        pub fn join(
            self: Self,
            comptime join_context: jetquery.relation.JoinContext,
            comptime name: jetquery.relation.RelationsEnum(Model),
        ) Statement(
            Adapter,
            switch (query_context) {
                .none => .select,
                else => |tag| tag,
            },
            Schema,
            Model,
            .{
                .relations = jetquery.relation.concatRelations(
                    options.relations,
                    Schema,
                    Model,
                    name,
                    jetquery.relation.translateRelationOptions(
                        Schema,
                        Model,
                        name,
                        .{ .select = null },
                    ),
                    join_context,
                ),
                .field_infos = options.field_infos,
                .columns = switch (query_context) {
                    .none => &Model.columns(),
                    else => options.columns,
                },
                .order_clauses = options.order_clauses,
                .result_context = switch (options.result_context) {
                    .none => .many,
                    else => |tag| tag,
                },
                .default_select = options.default_select,
                .where_clauses = options.where_clauses,
                .having_clauses = options.having_clauses,
            },
        ) {
            const S = Statement(
                Adapter,
                switch (query_context) {
                    .none => .select,
                    else => |tag| tag,
                },
                Schema,
                Model,
                .{
                    .relations = jetquery.relation.concatRelations(
                        options.relations,
                        Schema,
                        Model,
                        name,
                        jetquery.relation.translateRelationOptions(
                            Schema,
                            Model,
                            name,
                            .{ .select = null },
                        ),
                        join_context,
                    ),
                    .field_infos = options.field_infos,
                    .columns = switch (query_context) {
                        .none => &Model.columns(),
                        else => options.columns,
                    },
                    .order_clauses = options.order_clauses,
                    .result_context = switch (options.result_context) {
                        .none => .many,
                        else => |tag| tag,
                    },
                    .default_select = options.default_select,
                    .where_clauses = options.where_clauses,
                    .having_clauses = options.having_clauses,
                },
            );
            return self.extend(S, .{}, .none);
        }

        pub fn execute(self: Self, repo: anytype) !switch (options.result_context) {
            .one => ?ResultType,
            .many => jetquery.Result(@TypeOf(repo.*)),
            .none => void,
        } {
            const caller_info = try jetquery.debug.getCallerInfo(repo.debugMutex(), @returnAddress());
            return try repo.executeInternal(self, caller_info);
        }

        pub fn all(self: Self, repo: anytype) ![]ResultType {
            var result = try repo.executeInternal(
                self,
                try jetquery.debug.getCallerInfo(repo.debugMutex(), @returnAddress()),
            );
            return try result.all(self);
        }

        pub fn first(self: Self, repo: anytype) !?ResultType {
            const query = self.limit(1);
            var result = try repo.executeInternal(
                query,
                try jetquery.debug.getCallerInfo(repo.debugMutex(), @returnAddress()),
            );
            const rows = try result.all(query);
            defer repo.allocator.free(rows);
            return if (rows.len == 0) return null else rows[0];
        }

        pub fn validate(self: Self) !void {
            try self.validateDelete();
            try self.validateUpdate();
            try self.validateValues();
        }

        pub fn validateValues(self: Self) !void {
            for (self.errors) |maybe_error| {
                if (maybe_error) |err| return err;
            }
        }

        pub fn isValid(self: Self) bool {
            if (!self.isValidDelete()) return false;
            if (!self.isValidUpdate()) return false;

            return for (self.errors) |maybe_error| {
                if (maybe_error) |_| break false;
            } else true;
        }

        pub fn validateDelete(self: Self) !void {
            if (!self.isValidDelete()) return error.JetQueryUnsafeDelete;
        }

        fn isValidDelete(self: Self) bool {
            return query_context != .delete or self.hasWhereClause();
        }

        pub fn validateUpdate(self: Self) !void {
            if (!self.isValidUpdate()) return error.JetQueryUnsafeUpdate;
        }

        fn isValidUpdate(self: Self) bool {
            return query_context != .update or self.hasWhereClause();
        }

        pub fn _orderBy(
            self: Self,
            comptime order_clauses: []const jetquery.sql.OrderClause,
        ) Statement(
            Adapter,
            switch (query_context) {
                .none => .select,
                else => query_context,
            },
            Schema,
            Model,
            .{
                .relations = options.relations,
                .field_infos = options.field_infos,
                .columns = switch (query_context) {
                    .none => &Model.columns(),
                    else => options.columns,
                },
                .order_clauses = order_clauses,
                .result_context = switch (options.result_context) {
                    .none => .many,
                    else => options.result_context,
                },
                .where_clauses = options.where_clauses,
                .group_by = options.group_by,
                .having_clauses = options.having_clauses,
            },
        ) {
            const S = Statement(
                Adapter,
                switch (query_context) {
                    .none => .select,
                    else => query_context,
                },
                Schema,
                Model,
                .{
                    .relations = options.relations,
                    .field_infos = options.field_infos,
                    .columns = switch (query_context) {
                        .none => &Model.columns(),
                        else => options.columns,
                    },
                    .order_clauses = order_clauses,
                    .result_context = switch (options.result_context) {
                        .none => .many,
                        else => options.result_context,
                    },
                    .where_clauses = options.where_clauses,
                    .group_by = options.group_by,
                    .having_clauses = options.having_clauses,
                },
            );
            return self.extend(S, .{}, .order);
        }

        fn auxiliaryQueries() [auxiliaryQueriesSize()]AuxiliaryQuery {
            comptime {
                var queries: [auxiliaryQueriesSize()]AuxiliaryQuery = undefined;
                var index: usize = 0;

                for (options.relations) |Relation| {
                    if (Relation.relation_type != .has_many) continue;

                    queries[index] = .{
                        .query = Query(Adapter.name, Schema, Relation.Source),
                        .relation = Relation,
                    };
                    index += 1;
                }

                return queries;
            }
        }

        pub fn auxiliaryQueriesSize() usize {
            comptime {
                var size: usize = 0;
                for (options.relations) |Relation| {
                    if (Relation.relation_type != .has_many) continue;

                    size += 1;
                }
                return size;
            }
        }

        fn hasWhereClause(self: Self) bool {
            inline for (self.field_infos) |field| {
                if (field.context == .where) return true;
            }
            return false;
        }

        pub fn QueryColumnInfos() [totalColumnLen()]sql.ColumnInfo {
            comptime {
                var column_infos: [totalColumnLen()]sql.ColumnInfo = undefined;
                for (options.columns, 0..) |column, index| {
                    column_infos[index] = .{
                        .name = column.alias orelse column.name,
                        .type = column.ResultType(Adapter),
                        .index = index,
                        .relation = null,
                    };
                }
                var start: usize = options.columns.len;
                for (options.relations) |Relation| {
                    if (Relation.relation_type != .belongs_to) continue;

                    for (Relation.select_columns, start..) |column, index| {
                        column_infos[index] = .{
                            .name = column.alias orelse column.name,
                            .type = column.ResultType(Adapter),
                            .index = index,
                            .relation = Relation,
                        };
                    }
                    start += Relation.select_columns.len;
                }

                return column_infos;
            }
        }

        pub fn QueryResultType() type {
            comptime {
                switch (query_context) {
                    .count => return Adapter.Aggregate(.count),
                    else => {},
                }

                var base_fields: [options.columns.len]std.builtin.Type.StructField = undefined;

                for (options.columns, 0..) |column, index| {
                    base_fields[index] = jetquery.fields.structField(
                        column.alias orelse column.name,
                        column.ResultType(Adapter),
                    );
                }

                var relations_fields: [options.relations.len]std.builtin.Type.StructField = undefined;
                for (options.relations, 0..) |Relation, relation_index| {
                    var relation_fields: [Relation.select_columns.len]std.builtin.Type.StructField = undefined;
                    for (Relation.select_columns, 0..) |column, index| {
                        relation_fields[index] = jetquery.fields.structField(
                            column.alias orelse column.name,
                            column.ResultType(Adapter),
                        );
                    }

                    const RelationBaseType = @Type(.{ .@"struct" = .{
                        .layout = .auto,
                        .fields = &(relation_fields ++ internalFields(&relation_fields, false)),
                        .decls = &.{},
                        .is_tuple = false,
                    } });

                    const RelationType = switch (Relation.relation_type) {
                        .belongs_to => RelationBaseType,
                        .has_many => []const RelationBaseType,
                    };

                    const relation_field = jetquery.fields.structField(
                        Relation.relation_name,
                        RelationType,
                    );

                    relations_fields[relation_index] = relation_field;
                }

                const all_fields = base_fields ++
                    relations_fields ++
                    internalFields(&base_fields, true);

                return @Type(.{
                    .@"struct" = .{
                        .layout = .auto,
                        .fields = &all_fields,
                        .decls = &.{},
                        .is_tuple = false,
                    },
                });
            }
        }

        fn totalColumnLen() usize {
            comptime {
                var len: usize = options.columns.len;
                for (options.relations) |Relation| {
                    if (Relation.relation_type != .belongs_to) continue;

                    len += Relation.select_columns.len;
                }
                return len;
            }
        }

        fn internalFields(
            comptime base_fields: []const std.builtin.Type.StructField,
            comptime with_relations: bool,
        ) [4]std.builtin.Type.StructField {
            comptime {
                const Originals = @Type(.{ .@"struct" = .{
                    .layout = .auto,
                    .fields = base_fields,
                    .decls = &.{},
                    .is_tuple = false,
                } });

                const jetquery_fields: [1]std.builtin.Type.StructField = .{
                    jetquery.fields.structField("original_values", Originals),
                };

                const JQ = @Type(.{ .@"struct" = .{
                    .layout = .auto,
                    .fields = &jetquery_fields,
                    .decls = &.{},
                    .is_tuple = false,
                } });

                const len = if (with_relations) options.relations.len else 0;
                var relation_names: [len][]const u8 = undefined;
                if (with_relations) {
                    for (options.relations, 0..) |relation, index| {
                        relation_names[index] = relation.relation_name;
                    }
                }

                const relation_field = std.builtin.Type.StructField{
                    .name = "__jetquery_relation_names",
                    .type = [len][]const u8,
                    .default_value_ptr = @ptrCast(&relation_names),
                    .is_comptime = true,
                    .alignment = @alignOf([options.relations.len][]const u8),
                };

                return .{
                    jetquery.fields.structField("__jetquery", JQ),
                    // Sadly we can't store these inside the nested value as Zig doesn't figure
                    // out that the values are available at comptime.
                    jetquery.fields.structFieldComptime("__jetquery_model", Model),
                    jetquery.fields.structFieldComptime("__jetquery_schema", Schema),
                } ++ .{relation_field};
            }
        }
    };
}

fn timestampsFields(
    Adapter: type,
    Model: type,
    comptime field_context: jetquery.fields.FieldContext,
) [timestampsSize(Model, field_context)]jetquery.fields.FieldInfo {
    const timestamps = detectTimestamps(Model);
    const has_created_at = std.mem.containsAtLeast(TimestampType, timestamps, 1, &.{.created_at});
    const has_updated_at = std.mem.containsAtLeast(TimestampType, timestamps, 1, &.{.updated_at});
    const updated_at = jetquery.fields.fieldInfo(
        jetquery.fields.structField(jetquery.default_column_names.updated_at, i64),
        Model,
        jetquery.default_column_names.updated_at,
        field_context,
    );
    const created_at = jetquery.fields.fieldInfo(
        jetquery.fields.structField(jetquery.default_column_names.created_at, Adapter.DateTimePrimitive),
        Model,
        jetquery.default_column_names.created_at,
        field_context,
    );

    return switch (field_context) {
        .update => if (has_updated_at) .{updated_at} else .{},
        .insert => if (has_created_at and has_updated_at)
            .{ created_at, updated_at }
        else if (has_created_at)
            .{created_at}
        else if (has_updated_at)
            .{updated_at}
        else
            .{},
        else => @compileError(
            "Timestamps detection not relevant for `" ++ @tagName(field_context) ++ "` query. (This is a bug).",
        ),
    };
}

const TimestampType = enum { created_at, updated_at };

fn detectTimestamps(Model: type) []const TimestampType {
    const has_created_at = @hasField(Model.Definition, jetquery.default_column_names.created_at);
    const has_updated_at = @hasField(Model.Definition, jetquery.default_column_names.updated_at);

    return if (has_created_at and has_updated_at)
        &.{ .created_at, .updated_at }
    else if (has_created_at)
        &.{.created_at}
    else if (has_updated_at)
        &.{.updated_at}
    else
        &.{};
}

fn timestampsSize(Model: type, comptime field_context: jetquery.fields.FieldContext) u2 {
    const timestamps = detectTimestamps(Model);

    const has_updated_at = std.mem.containsAtLeast(TimestampType, timestamps, 1, &.{.updated_at});

    return switch (field_context) {
        .update => if (has_updated_at) 1 else 0,
        .insert => timestamps.len,
        else => @compileError(
            "Timestamps detection not relevant for `" ++ @tagName(field_context) ++ "` query. (This is a bug).",
        ),
    };
}

fn now() i64 {
    return std.time.microTimestamp();
}

fn validateQueryContext(comptime initial: sql.QueryContext, comptime attempted: sql.QueryContext) void {
    comptime {
        switch (attempted) {
            .count => switch (initial) {
                .none, .select => {},
                else => if (attempted != initial) @compileError(std.fmt.comptimePrint(
                    "Failed attempting to initialize `{s}` query already-initialized on `{s}` query.",
                    .{ @tagName(attempted), @tagName(initial) },
                )),
            },
            else => switch (initial) {
                .none => {},
                else => if (attempted != initial) @compileError(std.fmt.comptimePrint(
                    "Failed attempting to initialize `{s}` query already-initialized on `{s}` query.",
                    .{ @tagName(attempted), @tagName(initial) },
                )),
            },
        }
    }
}

fn updateTimestamps(
    T: type,
    statement: *T,
    comptime context: sql.QueryContext,
) void {
    switch (comptime context) {
        .update, .update_all => {
            const timestamp = now();
            inline for (statement.field_infos, 0..) |field_info, index| {
                if (comptime std.mem.eql(
                    u8,
                    field_info.name,
                    jetquery.default_column_names.updated_at,
                )) {
                    @field(
                        statement.values,
                        std.fmt.comptimePrint("{d}", .{index}),
                    ) = timestamp;
                    statement.errors[index] = null;
                }
            }
        },
        .insert => {
            const timestamp = now();
            inline for (statement.field_infos, 0..) |field_info, index| {
                if (comptime std.mem.eql(
                    u8,
                    field_info.name,
                    jetquery.default_column_names.updated_at,
                )) {
                    @field(
                        statement.values,
                        std.fmt.comptimePrint("{d}", .{index}),
                    ) = timestamp;
                    statement.errors[index] = null;
                } else if (comptime std.mem.eql(
                    u8,
                    field_info.name,
                    jetquery.default_column_names.created_at,
                )) {
                    @field(
                        statement.values,
                        std.fmt.comptimePrint("{d}", .{index}),
                    ) = timestamp;
                    statement.errors[index] = null;
                }
            }
        },
        else => {},
    }
}
