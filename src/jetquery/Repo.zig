const std = @import("std");

const jetquery = @import("../jetquery.zig");

pub fn Repo(adapter_name: jetquery.adapters.Name, Schema: type) type {
    return struct {
        const AdaptedRepo = @This();
        const Adapter = jetquery.adapters.Type(adapter_name);
        const Result = jetquery.Result(AdaptedRepo);

        pub const RepoAdapter = jetquery.adapters.Adapter(adapter_name, @This());
        pub const AdapterOptions = switch (Adapter.name) {
            .postgresql => jetquery.adapters.PostgresqlAdapter.Options,
            .null => jetquery.adapters.NullAdapter.Options,
        };

        pub const GlobalOptions = struct {
            eventCallback: jetquery.CallbackFn = jetquery.events.defaultCallback,
            lazy_connect: bool = false,
            admin: bool = false,
            context: jetquery.Context = .query,
            env: ?AdapterOptions = null,
        };

        comptime adapter_name: jetquery.adapters.Name = adapter_name,
        allocator: std.mem.Allocator,
        adapter: *RepoAdapter,
        eventCallback: jetquery.CallbackFn = jetquery.events.defaultCallback,
        result: ?jetquery.Result(AdaptedRepo) = null,
        context: jetquery.Context = .query,
        connection: ?jetquery.Connection = null,
        debug_mutex: std.Thread.Mutex = .{},
        child_debug_mutex: ?*std.Thread.Mutex = null,

        // For convenience, allow users to call `repo.Query(...)` instead of
        // `@TypeOf(repo).Query(...)`
        comptime Query: fn (anytype) type = _Query,

        pub const InitOptions = switch (adapter_name) {
            // All adapter options must be a superset of `GlobalOptions`
            .postgresql => struct {
                adapter: jetquery.adapters.PostgresqlAdapter.Options,
                eventCallback: jetquery.CallbackFn = jetquery.events.defaultCallback,
                lazy_connect: bool = false,
                admin: bool = false,
                context: jetquery.Context = .query,
                env: ?AdapterOptions = null,
            },
            .null => struct {
                eventCallback: jetquery.CallbackFn = jetquery.events.defaultCallback,
                admin: bool = false,
                lazy_connect: bool = false,
                context: jetquery.Context = .query,
                env: ?AdapterOptions = null,
            },
        };

        pub fn _Query(table: anytype) type {
            comptime {
                return jetquery.Query(adapter_name, Schema, table);
            }
        }

        pub fn format(_: AdaptedRepo, _: []const u8, _: anytype, writer: anytype) !void {
            try writer.print("Repo({s})", .{@tagName(adapter_name)});
        }

        /// Initialize a new Repo for executing queries.
        pub fn init(allocator: std.mem.Allocator, options: InitOptions) !AdaptedRepo {
            var env = try std.process.getEnvMap(allocator);
            defer env.deinit();

            const adapter: RepoAdapter = switch (comptime adapter_name) {
                .postgresql => .{
                    .postgresql = try jetquery.adapters.PostgresqlAdapter.init(
                        allocator,
                        try applyDefaultOptions(@TypeOf(options.adapter), options.adapter, env),
                        options.lazy_connect,
                    ),
                },
                .null => .{ .null = jetquery.adapters.NullAdapter{} },
            };

            const adapter_ptr = try allocator.create(RepoAdapter);
            adapter_ptr.* = adapter;

            return .{
                .allocator = allocator,
                .adapter = adapter_ptr,
                .eventCallback = options.eventCallback,
                .context = options.context,
            };
        }

        pub fn applyDefaultOptions(T: type, initial: T, env: std.process.EnvMap) !T {
            var options: T = undefined;
            const prefix = "JETQUERY_";
            inline for (std.meta.fields(T)) |field| {
                const env_name = comptime blk: {
                    var buf: [prefix.len + field.name.len]u8 = undefined;
                    @memcpy(buf[0..prefix.len], prefix);
                    for (field.name, prefix.len..) |char, index| buf[index] = std.ascii.toUpper(char);
                    break :blk buf;
                };
                @field(options, field.name) = @field(initial, field.name) orelse switch (field.type) {
                    ?u16, ?u32 => if (env.get(&env_name)) |value|
                        try std.fmt.parseInt(@typeInfo(field.type).optional.child, value, 10)
                    else
                        comptime T.defaultValue(field.type, field.name),
                    inline else => env.get(&env_name) orelse comptime T.defaultValue(field.type, field.name),
                };
            }
            return options;
        }

        /// Initialize a new repo using a config file. Config file build path is configured by build
        /// option `jetquery_config_path`.
        pub fn loadConfig(
            allocator: std.mem.Allocator,
            comptime environment: jetquery.Environment,
            global_options: GlobalOptions,
        ) !AdaptedRepo {
            const config = switch (environment) {
                inline else => |tag| @field(jetquery.config.database, @tagName(tag)),
            };

            var options: AdapterOptions = undefined;
            inline for (std.meta.fields(AdapterOptions)) |field| {
                if (@hasField(@TypeOf(config), field.name)) {
                    @field(options, field.name) = @field(config, field.name);
                } else if (field.defaultValue()) |default| {
                    @field(options, field.name) = default;
                } else {
                    var buf: [field.name.len]u8 = undefined;
                    @compileError(std.fmt.comptimePrint(
                        "Missing database configuration value for: `{s}`. " ++
                            "Configure in JetQuery config file or `JETQUERY_{s}`.",
                        .{ field.name, std.ascii.upperString(&buf, field.name) },
                    ));
                }
            }

            var init_options: InitOptions = switch (Adapter.name) {
                .postgresql => .{
                    .adapter = mergeOptions(global_options.admin, global_options.env, options),
                },
                .null => .{},
            };

            inline for (std.meta.fields(GlobalOptions)) |field| {
                @field(init_options, field.name) = @field(global_options, field.name);
            }
            return AdaptedRepo.init(allocator, init_options);
        }

        // Allow an application to pass an `env` option containing database options. Any values
        // passed here override anything defined in the config file. Jetzig uses this to read
        // environment variables from an `.env` file and the process environment.
        fn mergeOptions(admin: bool, maybe_env: ?AdapterOptions, options: AdapterOptions) AdapterOptions {
            const env = maybe_env orelse return options;

            var merged = AdapterOptions{};
            inline for (std.meta.fields(AdapterOptions)) |field| {
                const value = if (comptime std.mem.eql(u8, field.name, "database"))
                    // If we are running in "admin" mode (i.e. creating or dropping a database),
                    // assume the database we are connecting to is the same as the admin schema, e.g.
                    // if username is `postgres`, connect to database `postgres`.
                    // If this option does not work then users must manually create/drop a database
                    // through their database's CLI/admin tooling - we take our best guess here.
                    if (admin) env.username orelse options.username else env.database orelse options.database
                else
                    @field(env, field.name) orelse @field(options, field.name);
                @field(merged, field.name) = value;
            }

            return merged;
        }

        /// Close connections and free resources.
        pub fn deinit(self: *AdaptedRepo) void {
            self.release();
            switch (self.adapter.*) {
                inline else => |*adapter| adapter.deinit(),
            }
            self.allocator.destroy(self.adapter);
        }

        /// Execute the given query and return results.
        pub fn execute(
            self: *AdaptedRepo,
            query: anytype,
        ) !switch (@TypeOf(query).ResultContext) {
            .one => ?@TypeOf(query).ResultType,
            .many => Result,
            .none => void,
        } {
            const caller_info = try jetquery.debug.getCallerInfo(self.debugMutex(), @returnAddress());
            defer if (caller_info) |info| info.deinit();

            return try self.executeInternal(query, caller_info);
        }

        /// Execute SQL with the active adapter and return a result (same as `execute` but accepts an SQL
        /// string and values instead of a generated query).
        pub fn executeSql(
            self: *AdaptedRepo,
            sql: []const u8,
            values: anytype,
        ) !Result {
            const connection = try self.connectManaged();
            const caller_info = try jetquery.debug.getCallerInfo(self.debugMutex(), @returnAddress());
            return try connection.executeSql(sql, values, caller_info, self);
        }

        pub const BindConnectOptions = struct {
            allocator: ?std.mem.Allocator = null,
        };

        /// Return a new Repo bound to a connection. e.g. when a database connection is needed
        /// per request in a web server, use this function to create a new Repo and deinit after
        /// the request has processed to free the connection back to the pool.
        pub fn bindConnect(self: *AdaptedRepo, options: BindConnectOptions) !AdaptedRepo {
            if (self.adapter.* == .null) return self.*;

            return .{
                .allocator = options.allocator orelse self.allocator,
                .adapter = self.adapter,
                .eventCallback = self.eventCallback,
                .context = self.context,
                .connection = try self.connect(),
                .child_debug_mutex = &self.debug_mutex,
            };
        }

        /// Establish a new connection. Caller is responsible for calling `connection.release()` when
        /// connection can be returned to the pool. Only use this function if a new connection is
        /// specifically required, otherwise use `repo.execute()` which will automatically assign a
        /// connection and release it on `repo.deinit()`.
        ///
        /// The returned `Connection` implements `execute`, `executeSql`, and `executeVoid` to provide
        /// parity with the same member functions in `Repo`. Use `execute` to execute a generated query,
        /// use `executeSql` and `executeVoid` to execute SQL and a values tuple (e.g. when using
        /// handwritten SQL statements).
        pub fn connect(self: *AdaptedRepo) !jetquery.Connection {
            return try self.adapter.connect(.{ .context = self.context });
        }

        /// Used internally to create a managed connection which is released on `repo.deinit()`.
        pub fn connectManaged(self: *AdaptedRepo) !jetquery.Connection {
            return if (self.connection) |connection|
                connection
            else blk: {
                const connection = try self.connect();
                self.connection = connection;
                break :blk connection;
            };
        }

        /// Release the repo's connection to the pool. If no connection is currently acquired then this
        /// is a no-op.
        pub fn release(self: *AdaptedRepo) void {
            if (self.connection) |connection| {
                defer self.connection = null;
                connection.release();
            }
        }

        pub fn executeInternal(
            self: *AdaptedRepo,
            query: anytype,
            caller_info: ?jetquery.debug.CallerInfo,
        ) !switch (@TypeOf(query).ResultContext) {
            .one => ?@TypeOf(query).ResultType,
            .many => Result,
            .none => void,
        } {
            try query.validate();

            const connection = try self.connectManaged();

            return try connection.execute(query, caller_info, self);
        }

        pub fn begin(self: *AdaptedRepo) !void {
            const connection = try self.connectManaged();
            try connection.executeVoid(
                "BEGIN",
                .{},
                try jetquery.debug.getCallerInfo(self.debugMutex(), @returnAddress()),
                self,
            );
        }

        pub fn commit(self: *AdaptedRepo) !void {
            const connection = try self.connectManaged();
            try connection.executeVoid(
                "COMMIT",
                .{},
                try jetquery.debug.getCallerInfo(self.debugMutex(), @returnAddress()),
                self,
            );
        }

        pub fn rollback(self: *AdaptedRepo) !void {
            const connection = try self.connectManaged();
            try connection.executeVoid(
                "ROLLBACK",
                .{},
                try jetquery.debug.getCallerInfo(self.debugMutex(), @returnAddress()),
                self,
            );
        }

        /// Execute a query and return all of its results. Call `repo.free(result)` to free
        /// allocated memory.
        pub fn all(self: *AdaptedRepo, query: anytype) ![]@TypeOf(query).ResultType {
            var result = try self.executeInternal(
                query,
                try jetquery.debug.getCallerInfo(self.debugMutex(), @returnAddress()),
            );
            return try result.all(query);
        }

        pub fn save(self: *AdaptedRepo, record: anytype) !void {
            const value = switch (@typeInfo(@TypeOf(record))) {
                .pointer => record.*,
                else => record,
            };

            // Unfortunately we need to make an exception to comptime SQL generation here as we
            // only want to update columns where the value has been modified, so the SQL cannot
            // be known at comptime. We use `Connection.executeVoidRuntimeBind` to achieve this,
            // which pretty much exists solely for this use case.
            if (!isModified(value)) return;

            const primary_key = value.__jetquery_model.primary_key;

            comptime var size: usize = 0;
            comptime {
                for (std.meta.fields(@TypeOf(value))) |field| {
                    const is_primary_key = std.mem.eql(u8, field.name, primary_key);
                    if (!std.mem.startsWith(u8, field.name, "__") and !is_primary_key) {
                        size += 1;
                    }
                }
            }
            comptime var fields: [size]std.builtin.Type.StructField = undefined;
            comptime {
                var index: usize = 0;
                for (std.meta.fields(@TypeOf(value))) |field| {
                    const is_internal_field = std.mem.startsWith(u8, field.name, "__");
                    if (!is_internal_field and !std.mem.eql(u8, field.name, primary_key)) {
                        fields[index] = field;
                        index += 1;
                    }
                }
            }

            // We include ALL fields here, but `Connection.executeVoidRuntimeBind` receives a
            // slice of `jetquery.sql.FieldState` (provided by `Repo.fieldStates`) and only binds
            // values that have been modified.
            const Update = @Type(.{
                .@"struct" = .{
                    .layout = .auto,
                    .fields = &fields,
                    .decls = &.{},
                    .is_tuple = false,
                },
            });

            var update: Update = undefined;

            inline for (std.meta.fields(Update)) |field| {
                @field(update, field.name) = @field(value, field.name);
            }

            if (@hasField(Update, "updated_at")) {
                update.updated_at = jetquery.DateTime.now();
            }

            const primary_key_field = jetquery.fields.structField(
                primary_key,
                @TypeOf(@field(value, primary_key)),
            );

            const PrimaryKeyArgs = jetquery.fields.structType(&.{primary_key_field});
            var primary_key_args: PrimaryKeyArgs = undefined;
            @field(primary_key_args, primary_key) = @field(value, primary_key);

            // We generate the where clause at comptime. Note that, since we generate this first,
            // the first bind param is the primary key arg, i.e. `WHERE "id" = $1`.
            // `Connection.executeRuntimeBind` expects a tuple of values (in our case, the tuple
            // has only one value) and an args struct, which contains the values to update, using
            // the update statement we render at runtime. We iterate over the args in the struct
            // and bind only the modified values. The values tuple is bound first, since its bind
            // param is indexed first.
            const query = jetquery.Query(
                adapter_name,
                value.__jetquery_schema,
                value.__jetquery_model,
            ).where(primary_key_args);

            const field_states = fieldStates(value);

            const sql = try jetquery.sql.renderUpdateRuntime(
                self.allocator,
                Adapter,
                value.__jetquery_model,
                @TypeOf(query).where_clauses,
                Update,
                &field_states,
                query.field_infos.len,
            );
            defer self.allocator.free(sql);

            const connection = try self.connectManaged();
            try connection.executeVoidRuntimeBind(
                sql,
                .{@field(value, primary_key)},
                Update,
                update,
                &field_states,
                try jetquery.debug.getCallerInfo(self.debugMutex(), @returnAddress()),
                self,
            );
        }

        /// Insert a record into the database.
        /// ```zig
        /// try repo.insert(.Cat, .{ .name = "Hercules", .paws = 4 });
        /// ```
        pub fn insert(
            self: *AdaptedRepo,
            comptime model_name: std.meta.DeclEnum(Schema),
            args: anytype,
        ) !void {
            const query = jetquery.Query(
                adapter_name,
                Schema,
                @field(Schema, @tagName(model_name)),
            ).insert(args);

            try self.executeInternal(query, try jetquery.debug.getCallerInfo(self.debugMutex(), @returnAddress()));
        }

        /// Delete a fetched record from the database. Record must have a primary key.
        /// ```zig
        /// const maybe_cat = try Repo.Query(.Cat)
        ///     .findBy(.{ .name = "Heracles" })
        ///     .execute(repo);
        /// if (maybe_cat) |cat| try repo.delete(cat);
        /// ```
        pub fn delete(self: *AdaptedRepo, value: anytype) !void {
            const primary_key_field_name = value.__jetquery_model.primary_key;
            const Args = jetquery.fields.structType(
                &.{jetquery.fields.structField(
                    primary_key_field_name,
                    jetquery.fields.fieldType(@TypeOf(value), primary_key_field_name),
                )},
            );
            var args: Args = undefined;
            @field(args, primary_key_field_name) = @field(value, primary_key_field_name);

            const query = jetquery.Query(
                adapter_name,
                value.__jetquery_schema,
                value.__jetquery_model,
            ).delete().where(args);
            try self.executeInternal(query, try jetquery.debug.getCallerInfo(self.debugMutex(), @returnAddress()));
        }

        pub fn isModified(value: anytype) bool {
            const field_states = fieldStates(value);
            for (field_states) |field_state| {
                if (field_state.modified) return true;
            }
            return false;
        }

        pub fn fieldStates(
            value: anytype,
        ) [fieldStatesSize(@TypeOf(value))]jetquery.sql.FieldState {
            var field_state: [fieldStatesSize(@TypeOf(value))]jetquery.sql.FieldState = undefined;
            var index: usize = 0;

            const originals = value.__jetquery.original_values;
            inline for (std.meta.fields(@TypeOf(originals))) |field| {
                const modified = if (field.type == jetquery.DateTime)
                    @field(originals, field.name).eql(@field(value, field.name))
                else switch (@typeInfo(field.type)) {
                    .pointer => |info| std.mem.eql(
                        info.child,
                        @field(originals, field.name),
                        @field(value, field.name),
                    ),
                    else => @field(originals, field.name) == @field(value, field.name),
                };

                field_state[index] = .{ .name = field.name, .modified = modified };
                index += 1;
            }
            return field_state;
        }

        fn fieldStatesSize(T: type) usize {
            comptime {
                const t: T = undefined;
                return std.meta.fields(@TypeOf(t.__jetquery.original_values)).len;
            }
        }

        /// Free a result's allocated memory. Supports flexible inputs and can be used in conjunction
        /// with `all()` and `findBy()` etc.:
        /// ```zig
        ///
        pub fn free(self: *AdaptedRepo, value: anytype) void {
            switch (@typeInfo(@TypeOf(value))) {
                .pointer => |info| switch (info.size) {
                    .slice => {
                        for (value) |item| self.free(item);
                        self.allocator.free(value);
                    },
                    else => {},
                },
                .optional => {
                    if (value) |capture| return self.free(capture) else return;
                },
                else => {},
            }

            if (!comptime @hasField(@TypeOf(value), "__jetquery")) return;

            self._freeRow(value);

            inline for (value.__jetquery_relation_names) |relation_name| {
                switch (@typeInfo(@TypeOf(@field(value, relation_name)))) {
                    // belongs_to
                    .@"struct" => self.free(@field(value, relation_name)),
                    // has_many
                    .pointer => {
                        for (@field(value, relation_name)) |item| self.free(item);
                        self.allocator.free(@field(value, relation_name));
                    },
                    else => {},
                }
            }
        }

        /// Create a database table named `nme`. Pass `.{ .if_not_exists = true }` to use
        /// `CREATE TABLE IF NOT EXISTS` syntax.
        pub fn createTable(
            self: *AdaptedRepo,
            comptime name: []const u8,
            comptime columns: []const jetquery.schema.Column,
            comptime options: jetquery.CreateTableOptions,
        ) !void {
            var buf = std.ArrayList(u8).init(self.allocator);
            defer buf.deinit();

            const writer = buf.writer();

            try writer.print(
                \\CREATE TABLE{s} {s} (
            , .{ if (options.if_not_exists) " IF NOT EXISTS" else "", self.adapter.identifier(name) });

            inline for (columns, 0..) |column, index| {
                try self.adapter.writeAddColumnSql(column, writer);
                if (index < columns.len - 1) try writer.print(", ", .{});
            }

            try writer.print(")", .{});
            const connection = try self.connectManaged();
            try connection.executeVoid(
                buf.items,
                &.{},
                try jetquery.debug.getCallerInfo(self.debugMutex(), @returnAddress()),
                self,
            );

            try self.createIndexes(
                name,
                columns,
                .{ .if_not_exists = options.if_not_exists },
            );
        }

        /// Drop a database table named `name`. Pass `.{ .if_exists = true }` to use
        /// `DROP TABLE IF EXISTS` syntax.
        pub fn dropTable(
            self: *AdaptedRepo,
            comptime name: []const u8,
            comptime options: jetquery.DropTableOptions,
        ) !void {
            var buf = std.ArrayList(u8).init(self.allocator);
            defer buf.deinit();

            const writer = buf.writer();

            try writer.print(
                \\DROP TABLE{s} {s}
            , .{ if (options.if_exists) " IF EXISTS" else "", self.adapter.identifier(name) });

            const connection = try self.connectManaged();
            try connection.executeVoid(
                buf.items,
                &.{},
                try jetquery.debug.getCallerInfo(self.debugMutex(), @returnAddress()),
                self,
            );
        }

        /// Alter a database table. Rename table or add, drop, modify, or rename columns.
        pub fn alterTable(
            self: *AdaptedRepo,
            comptime name: []const u8,
            comptime options: jetquery.AlterTableOptions,
        ) !void {
            var buf = std.ArrayList(u8).init(self.allocator);
            defer buf.deinit();
            const writer = buf.writer();

            // XXX: We don't prevent a user from generating an incoherent `ALTER TABLE`
            // statement, e.g. with multiple column renames or adding columns and renaming the
            // table. This allows the database to produce an informative error in such cases,
            // instead of us needing to have knowledge of all database backends' semantics (which
            // may change over time).

            try writer.print(
                \\ALTER TABLE {s}
            , .{self.adapter.identifier(name)});

            inline for (options.columns.add, 0..) |column, index| {
                try writer.print(" ADD COLUMN ", .{});
                try self.adapter.writeAddColumnSql(column, writer);
                if (index < options.columns.add.len - 1) try writer.print(",", .{});
            }

            if (options.columns.rename) |rename_column| {
                try writer.print(" RENAME {s} TO {s}", .{
                    self.adapter.identifier(rename_column.from),
                    self.adapter.identifier(rename_column.to),
                });
            }

            inline for (options.columns.drop, 0..) |column_name, index| {
                try writer.print(" DROP COLUMN {s}{s}", .{
                    self.adapter.identifier(column_name),
                    if (index + 1 < options.columns.drop.len) "," else "",
                });
            }

            if (options.rename) |rename_table| {
                try writer.print(" RENAME TO {s}", .{self.adapter.identifier(rename_table)});
            }

            const connection = try self.connectManaged();
            try connection.executeVoid(
                buf.items,
                &.{},
                try jetquery.debug.getCallerInfo(self.debugMutex(), @returnAddress()),
                self,
            );

            try self.createIndexes(options.rename orelse name, options.columns.add, .{});
        }

        /// Create a new database in the current repo. Repo must be initialized with the appropriate user
        /// credentials for creating new databases.
        pub fn createDatabase(
            self: *AdaptedRepo,
            name: []const u8,
            options: struct {},
        ) !void {
            _ = options;
            var buf = std.ArrayList(u8).init(self.allocator);
            defer buf.deinit();
            const database = try self.adapter.identifierAlloc(self.allocator, name);
            defer self.allocator.free(database);

            const writer = buf.writer();

            try writer.print(
                \\CREATE DATABASE {s}
            , .{database});

            const connection = try self.connectManaged();
            try connection.executeVoid(
                buf.items,
                &.{},
                try jetquery.debug.getCallerInfo(self.debugMutex(), @returnAddress()),
                self,
            );
        }

        /// Create a new database in the current repo. Repo must be initialized with the appropriate user
        /// credentials for creating new databases.
        pub fn dropDatabase(
            self: *AdaptedRepo,
            name: []const u8,
            options: jetquery.DropDatabaseOptions,
        ) !void {
            var buf = std.ArrayList(u8).init(self.allocator);
            defer buf.deinit();
            const database = try self.adapter.identifierAlloc(self.allocator, name);
            defer self.allocator.free(database);

            const writer = buf.writer();

            try writer.print(
                \\DROP DATABASE{s} {s}
            , .{
                if (options.if_exists) " IF EXISTS" else "",
                database,
            });

            const connection = try self.connectManaged();
            try connection.executeVoid(
                buf.items,
                &.{},
                try jetquery.debug.getCallerInfo(self.debugMutex(), @returnAddress()),
                self,
            );
        }

        /// Create an index on the specified table name and column names. Optionally pass]
        /// `.{ .unique = true }` to create a unique constraint on the index.
        pub fn createIndex(
            self: *AdaptedRepo,
            comptime table_name: []const u8,
            comptime column_names: []const []const u8,
            comptime options: jetquery.CreateIndexOptions,
        ) !void {
            const index_name = comptime options.name orelse Adapter.indexName(
                table_name,
                column_names,
            );
            const sql = comptime Adapter.createIndexSql(
                index_name,
                table_name,
                column_names,
                options,
            );
            const connection = try self.connectManaged();
            try connection.executeVoid(
                sql,
                .{},
                try jetquery.debug.getCallerInfo(self.debugMutex(), @returnAddress()),
                self,
            );
        }

        /// Execute raw SQL directly. Use this for database operations that are not yet
        /// supported by JetQuery's schema manipulation functions.
        /// Note: Use with caution as this bypasses JetQuery's type safety and validation.
        pub fn executeSqlRaw(
            self: *AdaptedRepo,
            sql: []const u8,
        ) !void {
            const connection = try self.connectManaged();
            try connection.executeVoid(
                sql,
                .{},
                try jetquery.debug.getCallerInfo(self.debugMutex(), @returnAddress()),
                self,
            );
        }

        // Internally used by `createTable` - use `createIndex` to create a single index.
        fn createIndexes(
            self: *AdaptedRepo,
            comptime name: []const u8,
            comptime columns: []const jetquery.schema.Column,
            comptime options: jetquery.CreateIndexOptions,
        ) !void {
            inline for (columns) |column| {
                if (comptime !column.options.index) continue;
                try self.createIndex(
                    name,
                    &.{column.name},
                    .{ .name = column.options.index_name, .if_not_exists = options.if_not_exists },
                );
            }

            inline for (columns) |column| {
                if (comptime column.timestamps) |timestamps| {
                    if (timestamps.created_at) {
                        try self.createIndex(
                            name,
                            &.{jetquery.default_column_names.created_at},
                            .{ .if_not_exists = options.if_not_exists },
                        );
                    }
                    if (timestamps.updated_at) {
                        try self.createIndex(
                            name,
                            &.{jetquery.default_column_names.updated_at},
                            .{ .if_not_exists = options.if_not_exists },
                        );
                    }
                }
            }
        }

        pub fn debugMutex(self: *AdaptedRepo) *std.Thread.Mutex {
            return self.child_debug_mutex orelse &self.debug_mutex;
        }

        /// Use `Repo.free()` to free a row. This function is for internal use only.
        pub fn _freeRow(self: *AdaptedRepo, value: anytype) void {
            // Value may be modified after fetching so we only free the original value. If user
            // messes with internals and modifies original values then they will run into
            // trouble.
            inline for (std.meta.fields(@TypeOf(value.__jetquery.original_values))) |field| {
                self._freeValue(field.name, field.type, value);
            }
        }

        fn _freeValue(
            self: *AdaptedRepo,
            comptime field_name: []const u8,
            T: type,
            value: anytype,
        ) void {
            switch (@typeInfo(T)) {
                .pointer => |info| {
                    switch (info.child) {
                        // TODO: Couple this with `maybeDupe` logic to make sure we stay
                        // consistent in which types need to be freed.
                        u8 => {
                            self.allocator.free(@field(
                                value.__jetquery.original_values,
                                field_name,
                            ));
                        },
                        else => {},
                    }
                },
                .optional => |info| {
                    if (@field(value.__jetquery.original_values, field_name)) |capture| {
                        switch (@typeInfo(info.child)) {
                            .pointer => |pointer| switch (pointer.child) {
                                u8 => {
                                    self.allocator.free(capture);
                                },
                                else => {},
                            },
                            else => {},
                        }
                    }
                },
                .@"struct" => self.free(@field(value, field_name)),
                else => {},
            }
        }
    };
}

test "Repo" {
    try resetDatabase();

    const Schema = struct {
        pub const Cat = jetquery.Model(
            @This(),
            "cats",
            struct { name: []const u8, paws: i32 },
            .{},
        );
    };

    var repo = try Repo(.postgresql, Schema).init(
        std.testing.allocator,
        .{
            .adapter = .{
                .database = "repo_test",
                .username = "postgres",
                .hostname = "127.0.0.1",
                .password = "password",
                .port = 5432,
            },
        },
    );
    defer repo.deinit();

    try repo.createTable(
        "cats",
        &.{
            jetquery.schema.table.column("name", .string, .{}),
            jetquery.schema.table.column("paws", .integer, .{}),
        },
        .{ .if_not_exists = true },
    );

    try repo.Query(.Cat).insert(.{ .name = "Hercules", .paws = 4 }).execute(&repo);
    try repo.Query(.Cat).insert(.{ .name = "Princes", .paws = 4 }).execute(&repo);

    const coalesced_paws = jetquery.sql.column(i32, "coalesce(cats.paws, 3)").as(.coalesced_paws);

    const query = repo.Query(.Cat)
        .select(.{ .name, .paws, coalesced_paws })
        .where(.{ .paws = 4 });

    const cats = try repo.all(query);
    defer repo.free(cats);

    for (cats) |cat| {
        try std.testing.expectEqualStrings("Hercules", cat.name);
        try std.testing.expectEqual(4, cat.paws);
        try std.testing.expectEqual(4, cat.coalesced_paws);
        break;
    } else {
        try std.testing.expect(false);
    }

    const count_all = try query.count().execute(&repo);
    try std.testing.expectEqual(2, count_all);

    const count_distinct = try repo.Query(.Cat)
        .distinct(.{.paws})
        .count()
        .execute(&repo);
    try std.testing.expectEqual(1, count_distinct);
}

test "Repo.loadConfig" {
    try resetDatabase();

    // Loads default config file: `jetquery.config.zig`
    var repo = try Repo(.postgresql, void).loadConfig(std.testing.allocator, .testing, .{});
    defer repo.deinit();
    try std.testing.expect(repo.adapter.* == .postgresql);
}

test "Repo.loadConfig with env" {
    try resetDatabase();

    var repo = try Repo(.postgresql, void).loadConfig(
        std.testing.allocator,
        .testing,
        .{
            .lazy_connect = true,
            .env = .{
                .database = "database_from_env",
                .password = "password_from_env",
            },
        },
    );
    defer repo.deinit();
    try std.testing.expect(repo.adapter.* == .postgresql);
    try std.testing.expectEqualStrings(
        repo.adapter.postgresql.options.database.?,
        "database_from_env",
    );
    try std.testing.expectEqualStrings(
        repo.adapter.postgresql.options.password.?,
        "password_from_env",
    );
    // Testing fallback to config file:
    try std.testing.expectEqualStrings(
        repo.adapter.postgresql.options.hostname.?,
        "127.0.0.1",
    );
    try std.testing.expectEqual(
        repo.adapter.postgresql.options.port.?,
        5432,
    );
    try std.testing.expectEqualStrings(
        repo.adapter.postgresql.options.username.?,
        "postgres",
    );
}

test "relations" {
    try resetDatabase();

    const Schema = struct {
        pub const Cat = jetquery.Model(
            @This(),
            "cats",
            struct { id: i32, human_id: i32, name: []const u8, paws: i32 },
            .{ .relations = .{ .human = jetquery.relation.belongsTo(.Human, .{}) } },
        );

        pub const Human = jetquery.Model(
            @This(),
            "humans",
            struct { id: i32, name: []const u8 },
            .{ .relations = .{ .cats = jetquery.relation.hasMany(.Cat, .{}) } },
        );
    };

    var repo = try Repo(.postgresql, Schema).init(
        std.testing.allocator,
        .{
            .adapter = .{
                .database = "repo_test",
                .username = "postgres",
                .hostname = "127.0.0.1",
                .password = "password",
                .port = 5432,
            },
        },
    );
    defer repo.deinit();

    try repo.createTable(
        "cats",
        &.{
            jetquery.schema.table.column("id", .integer, .{}),
            jetquery.schema.table.column("human_id", .integer, .{}),
            jetquery.schema.table.column("name", .string, .{}),
            jetquery.schema.table.column("paws", .integer, .{}),
        },
        .{ .if_not_exists = true },
    );

    try repo.createTable(
        "humans",
        &.{
            jetquery.schema.table.column("id", .integer, .{}),
            jetquery.schema.table.column("name", .string, .{}),
        },
        .{ .if_not_exists = true },
    );

    try repo.Query(.Human)
        .insert(.{ .id = 1, .name = "Bob" })
        .execute(&repo);
    try repo.Query(.Cat)
        .insert(.{ .id = 1, .name = "Hercules", .paws = 4, .human_id = 1 })
        .execute(&repo);

    const query = repo.Query(.Cat)
        .include(.human, .{})
        .findBy(.{ .name = "Hercules" });

    const cat = try query.execute(&repo) orelse return try std.testing.expect(false);
    defer repo.free(cat);

    try std.testing.expectEqualStrings("Hercules", cat.name);
    try std.testing.expectEqual(4, cat.paws);
    try std.testing.expectEqualStrings("Bob", cat.human.name);

    const bob = try repo.Query(.Human)
        .include(.cats, .{})
        .findBy(.{ .name = "Bob" })
        .execute(&repo) orelse return try std.testing.expect(false);
    defer repo.free(bob);

    try std.testing.expectEqualStrings("Hercules", bob.cats[0].name);

    try repo.insert(.Cat, .{
        .id = 2,
        .name = "Princes",
        .paws = std.crypto.random.int(u3),
        .human_id = bob.id,
    });
    try repo.insert(.Cat, .{
        .id = 3,
        .name = "Heracles",
        .paws = std.crypto.random.int(u3),
        .human_id = 1000,
    });

    const bob_with_more_cats = try repo.Query(.Human)
        .include(.cats, .{})
        .findBy(.{ .name = "Bob" })
        .execute(&repo) orelse return try std.testing.expect(false);
    defer repo.free(bob_with_more_cats);

    try std.testing.expect(bob_with_more_cats.cats.len == 2);
    try std.testing.expectEqualStrings("Hercules", bob_with_more_cats.cats[0].name);
    try std.testing.expectEqualStrings("Princes", bob_with_more_cats.cats[1].name);

    try repo.insert(.Human, .{
        .id = 2,
        .name = "Jane",
    });

    const jane = try repo.Query(.Human)
        .include(.cats, .{})
        .findBy(.{ .name = "Jane" })
        .execute(&repo) orelse return try std.testing.expect(false);
    defer repo.free(jane);

    try std.testing.expect(jane.cats.len == 0);

    try repo.insert(.Cat, .{
        .id = 4,
        .human_id = jane.id,
        .name = "Cindy",
        .paws = std.crypto.random.int(u3),
    });

    try repo.insert(.Cat, .{
        .id = 5,
        .human_id = jane.id,
        .name = "Garfield",
        .paws = std.crypto.random.int(u3),
    });

    try repo.insert(.Cat, .{
        .id = 6,
        .human_id = jane.id,
        .name = "Felix",
        .paws = std.crypto.random.int(u3),
    });

    const humans = try repo.Query(.Human).include(.cats, .{}).orderBy(.name).all(&repo);
    defer repo.free(humans);

    try std.testing.expect(humans.len == 2);
    try std.testing.expect(humans[0].cats.len == 2);
    try std.testing.expect(humans[1].cats.len == 3);
    try std.testing.expectEqualStrings("Bob", humans[0].name);
    try std.testing.expectEqualStrings("Jane", humans[1].name);
    try std.testing.expectEqualStrings("Hercules", humans[0].cats[0].name);
    try std.testing.expectEqualStrings("Princes", humans[0].cats[1].name);
    try std.testing.expectEqualStrings("Jane", humans[1].name);
    try std.testing.expectEqualStrings("Cindy", humans[1].cats[0].name);
    try std.testing.expectEqualStrings("Garfield", humans[1].cats[1].name);
    try std.testing.expectEqualStrings("Felix", humans[1].cats[2].name);

    const jane_two_cats = try repo.Query(.Human).findBy(.{ .name = "Jane" })
        .include(.cats, .{ .limit = 2, .order_by = .name })
        .execute(&repo);
    defer repo.free(jane_two_cats);
    try std.testing.expect(jane_two_cats.?.cats.len == 2);
    try std.testing.expectEqualStrings("Cindy", jane_two_cats.?.cats[0].name);
    try std.testing.expectEqualStrings("Felix", jane_two_cats.?.cats[1].name);

    const iterating_query = repo.Query(.Human)
        .include(.cats, .{ .order_by = .name })
        .orderBy(.name);
    var humans_iterated = try iterating_query.execute(&repo);
    defer humans_iterated.deinit();
    var index: usize = 0;
    while (try humans_iterated.next(iterating_query)) |human| : (index += 1) {
        defer repo.free(human);
        switch (index) {
            0 => {
                try std.testing.expectEqualStrings("Bob", human.name);
                try std.testing.expectEqualStrings("Hercules", human.cats[0].name);
                try std.testing.expectEqualStrings("Princes", human.cats[1].name);
            },
            1 => {
                try std.testing.expectEqualStrings("Jane", human.name);
                try std.testing.expectEqualStrings("Cindy", human.cats[0].name);
                try std.testing.expectEqualStrings("Felix", human.cats[1].name);
                try std.testing.expectEqualStrings("Garfield", human.cats[2].name);
            },
            else => try std.testing.expect(false),
        }
    }

    const lila = try repo.Query(.Human)
        .insert(.{ .id = 20, .name = "Lila" })
        .returning(.{.id})
        .execute(&repo) orelse return try std.testing.expect(false);
    defer repo.free(lila);
    try std.testing.expectEqual(20, lila.id);
    const fluffy = try repo.Query(.Cat)
        .insert(.{ .id = lila.id, .name = "Fluffy", .paws = 4, .human_id = 1 })
        .returning(.{})
        .execute(&repo) orelse return try std.testing.expect(false);
    defer repo.free(fluffy);
    try std.testing.expectEqual(20, fluffy.id);
    try std.testing.expectEqual(4, fluffy.paws);
}

test "timestamps" {
    try resetDatabase();

    const Schema = struct {
        pub const Cat = jetquery.Model(
            @This(),
            "cats",
            struct {
                id: i32,
                name: []const u8,
                paws: i32,
                created_at: jetquery.DateTime,
                updated_at: jetquery.DateTime,
            },
            .{},
        );
    };

    var repo = try Repo(.postgresql, Schema).init(
        std.testing.allocator,
        .{
            .adapter = .{
                .database = "repo_test",
                .username = "postgres",
                .hostname = "127.0.0.1",
                .password = "password",
                .port = 5432,
            },
        },
    );
    defer repo.deinit();

    try repo.createTable(
        "cats",
        &.{
            jetquery.schema.table.primaryKey("id", .{}),
            jetquery.schema.table.column("name", .string, .{}),
            jetquery.schema.table.column("paws", .integer, .{}),
            jetquery.schema.table.column("created_at", .datetime, .{}),
            jetquery.schema.table.column("updated_at", .datetime, .{}),
        },
        .{},
    );

    const now = std.time.microTimestamp();
    std.time.sleep(std.time.ns_per_ms);

    try repo.Query(.Cat).insert(.{ .name = "Hercules", .paws = 4 }).execute(&repo);

    const maybe_cat = try repo.Query(.Cat)
        .findBy(.{ .name = "Hercules" })
        .execute(&repo);

    if (maybe_cat) |cat| {
        defer repo.free(cat);
        try std.testing.expect(cat.created_at.microseconds() > now);
    }
}

test "save" {
    try resetDatabase();

    const Schema = struct {
        pub const Cat = jetquery.Model(
            @This(),
            "cats",
            struct { id: i32, name: []const u8, paws: i32 },
            .{},
        );
    };

    var repo = try Repo(.postgresql, Schema).init(
        std.testing.allocator,
        .{
            .adapter = .{
                .database = "repo_test",
                .username = "postgres",
                .hostname = "127.0.0.1",
                .password = "password",
                .port = 5432,
            },
        },
    );
    defer repo.deinit();

    try repo.createTable("cats", &.{
        jetquery.schema.table.column("id", .integer, .{}),
        jetquery.schema.table.column("name", .string, .{}),
        jetquery.schema.table.column("paws", .integer, .{}),
    }, .{ .if_not_exists = true });

    try repo.Query(.Cat)
        .insert(.{ .id = 1000, .name = "Hercules", .paws = 4 })
        .execute(&repo);

    var maybe_cat = try repo.Query(.Cat)
        .findBy(.{ .name = "Hercules" })
        .execute(&repo);
    defer repo.free(maybe_cat);
    if (maybe_cat) |*cat| {
        cat.name = "Princes";
        try repo.save(cat);
    }

    const updated_cat = try repo.Query(.Cat)
        .find(1000)
        .execute(&repo) orelse return std.testing.expect(false);
    defer repo.free(updated_cat);
    try std.testing.expectEqualStrings("Princes", updated_cat.name);
}

test "aggregate max()" {
    try resetDatabase();

    const Schema = struct {
        pub const Cat = jetquery.Model(
            @This(),
            "cats",
            struct { name: []const u8, paws: usize },
            .{},
        );
    };

    var repo = try Repo(.postgresql, Schema).init(
        std.testing.allocator,
        .{
            .adapter = .{
                .database = "repo_test",
                .username = "postgres",
                .hostname = "127.0.0.1",
                .password = "password",
                .port = 5432,
            },
        },
    );
    defer repo.deinit();

    try repo.createTable("cats", &.{
        jetquery.schema.table.column("name", .string, .{}),
        jetquery.schema.table.column("paws", .integer, .{}),
    }, .{ .if_not_exists = true });

    const sql = jetquery.sql;

    try repo.insert(.Cat, .{ .name = "Hercules", .paws = 2 });
    try repo.insert(.Cat, .{ .name = "Hercules", .paws = 8 });
    try repo.insert(.Cat, .{ .name = "Hercules", .paws = 4 });
    try repo.insert(.Cat, .{ .name = "Princes", .paws = 100 });
    try repo.insert(.Cat, .{ .name = "Princes", .paws = 5 });
    try repo.insert(.Cat, .{ .name = "Princes", .paws = 2 });

    const cats = try repo.Query(.Cat)
        .select(.{ .name, sql.max(.paws) })
        .groupBy(.{.name})
        .orderBy(.{.name})
        .all(&repo);
    defer repo.free(cats);

    try std.testing.expectEqualStrings(cats[0].name, "Hercules");
    try std.testing.expect(cats[0].max__paws == 8);
    try std.testing.expectEqualStrings(cats[1].name, "Princes");
    try std.testing.expect(cats[1].max__paws == 100);
}

test "aggregate count() with HAVING" {
    try resetDatabase();

    const Schema = struct {
        pub const Cat = jetquery.Model(
            @This(),
            "cats",
            struct { name: []const u8, paws: usize },
            .{},
        );
    };

    var repo = try Repo(.postgresql, Schema).init(
        std.testing.allocator,
        .{
            .adapter = .{
                .database = "repo_test",
                .username = "postgres",
                .hostname = "127.0.0.1",
                .password = "password",
                .port = 5432,
            },
        },
    );
    defer repo.deinit();

    try repo.createTable("cats", &.{
        jetquery.schema.table.column("name", .string, .{}),
        jetquery.schema.table.column("paws", .integer, .{}),
    }, .{ .if_not_exists = true });

    try repo.insert(.Cat, .{ .name = "Hercules", .paws = 2 });
    try repo.insert(.Cat, .{ .name = "Hercules", .paws = 8 });
    try repo.insert(.Cat, .{ .name = "Hercules", .paws = 4 });
    try repo.insert(.Cat, .{ .name = "Princes", .paws = 100 });
    try repo.insert(.Cat, .{ .name = "Princes", .paws = 5 });
    try repo.insert(.Cat, .{ .name = "Princes", .paws = 2 });

    const sql = jetquery.sql;

    const cats = try repo.Query(.Cat)
        .select(.{ .name, sql.max(.paws).as("maximum_paws") })
        .where(.{ .{ .name = "Hercules" }, .OR, .{ .name, .like, "Pri%" } })
        .groupBy(.{.name})
        .having(.{ .{ sql.count(.name), .gt_eql, "3" }, .OR, .{ sql.count(.name), .lt_eql, 3 } })
        .orderBy(.{.name})
        .all(&repo);
    defer repo.free(cats);

    try std.testing.expectEqualStrings(cats[0].name, "Hercules");
    try std.testing.expect(cats[0].maximum_paws == 8);
    try std.testing.expectEqualStrings(cats[1].name, "Princes");
    try std.testing.expect(cats[1].maximum_paws == 100);
}

test "missing config options" {
    try resetDatabase();

    const repo = Repo(.postgresql, struct {}).init(std.testing.allocator, .{ .adapter = .{} });
    try std.testing.expectError(error.JetQueryConfigError, repo);
}

test "raw SQL" {
    try resetDatabase();

    const Schema = struct {
        pub const Cat = jetquery.Model(
            @This(),
            "cats",
            struct { name: []const u8, paws: i32 },
            .{},
        );
    };

    {
        var repo = try Repo(.postgresql, Schema).init(
            std.testing.allocator,
            .{
                .adapter = .{
                    .database = "repo_test",
                    .username = "postgres",
                    .hostname = "127.0.0.1",
                    .password = "password",
                    .port = 5432,
                },
            },
        );
        defer repo.deinit();

        // Create table
        try repo.createTable("cats", &.{
            jetquery.schema.table.column("name", .string, .{}),
            jetquery.schema.table.column("paws", .integer, .{}),
        }, .{});

        // Add a unique constraint using raw SQL
        try repo.executeSqlRaw(
            "ALTER TABLE cats ADD CONSTRAINT unique_name_paws UNIQUE (name, paws)",
        );

        // Insert first 3 records - should succeed
        try repo.insert(.Cat, .{ .name = "Hercules", .paws = 4 });
        try repo.insert(.Cat, .{ .name = "Leo", .paws = 4 });
        try repo.insert(.Cat, .{ .name = "Hercules", .paws = 3 });

        // Insert record that violates the unique constraint - should fail
        const violation = repo.insert(.Cat, .{ .name = "Hercules", .paws = 4 });
        try std.testing.expectError(error.PG, violation);

        // Verify we only have 3 records
        const count = try repo.Query(.Cat).count().execute(&repo);
        try std.testing.expectEqual(@as(i64, 3), count);
    }
}

test "transactions" {
    try resetDatabase();

    const Schema = struct {
        pub const Cat = jetquery.Model(
            @This(),
            "cats",
            struct { name: []const u8, paws: i32 },
            .{},
        );
    };

    var repo = try Repo(.postgresql, Schema).init(
        std.testing.allocator,
        .{
            .adapter = .{
                .database = "repo_test",
                .username = "postgres",
                .hostname = "127.0.0.1",
                .password = "password",
                .port = 5432,
            },
        },
    );
    defer repo.deinit();

    try repo.createTable("cats", &.{
        jetquery.schema.table.column("name", .string, .{}),
        jetquery.schema.table.column("paws", .integer, .{}),
    }, .{ .if_not_exists = true });

    try repo.begin();
    try repo.insert(.Cat, .{ .name = "Hercules", .paws = 4 });
    try repo.rollback();

    const no_cat = try repo.Query(.Cat)
        .findBy(.{ .name = "Hercules" })
        .execute(&repo);
    defer repo.free(no_cat);
    try std.testing.expect(no_cat == null);

    try repo.begin();
    const waited = try repo.Query(.Cat)
        .insert(.{ .name = "Waiting", .paws = 3 })
        .returning(.{.name})
        .execute(&repo) orelse return try std.testing.expect(false);
    defer repo.free(waited);
    try repo.rollback();
    try std.testing.expect(std.mem.eql(u8, waited.name, "Waiting"));

    try repo.begin();
    try repo.insert(.Cat, .{ .name = "Hercules", .paws = 4 });
    try repo.commit();

    const yes_cat = try repo.Query(.Cat)
        .findBy(.{ .name = "Hercules" })
        .execute(&repo);
    defer repo.free(yes_cat);
    try std.testing.expect(yes_cat != null);
}

test "alterTable" {
    try resetDatabase();
    const Schema = struct {
        pub const Cat = jetquery.Model(
            @This(),
            "cats",
            struct { name: []const u8, paws: i32 },
            .{},
        );
        pub const Dog = jetquery.Model(
            @This(),
            "dogs",
            struct { name: []const u8, identifier: []const u8, paws: i32 },
            .{},
        );
    };

    var repo = try Repo(.postgresql, Schema).init(std.testing.allocator, .{
        .adapter = .{
            .database = "repo_test",
            .username = "postgres",
            .hostname = "127.0.0.1",
            .password = "password",
            .port = 5432,
        },
    });
    defer repo.deinit();

    try repo.createTable("cats", &.{}, .{});

    try std.testing.expectError(
        error.PG,
        repo.Query(.Cat).select(.{ .name, .paws }).all(&repo),
    );

    try repo.alterTable("cats", .{
        .columns = .{
            .add = &.{
                jetquery.schema.table.column("name", .string, .{}),
                jetquery.schema.table.column("paws", .integer, .{ .index = true }),
            },
        },
    });

    const cats = try repo.Query(.Cat).select(.{ .name, .paws }).all(&repo);
    try std.testing.expect(cats.len == 0); // Empty table but valid select columns.

    try std.testing.expectError(
        error.PG,
        repo.Query(.Dog).select(.{ .name, .paws }).all(&repo),
    );

    try repo.alterTable("cats", .{ .rename = "dogs" });

    try std.testing.expectError(
        error.PG,
        repo.Query(.Cat).select(.{ .name, .paws }).all(&repo),
    );

    const dogs = try repo.Query(.Dog).select(.{ .name, .paws }).all(&repo);
    try std.testing.expect(dogs.len == 0); // Empty table but valid select columns.

    try repo.alterTable("dogs", .{ .columns = .{ .drop = &.{"paws"} } });
    try std.testing.expectError(
        error.PG,
        repo.Query(.Dog).select(.{ .name, .paws }).all(&repo),
    );

    try repo.alterTable(
        "dogs",
        .{ .columns = .{ .rename = .{ .from = "name", .to = "identifier" } } },
    );
    const dogs2 = try repo.Query(.Dog).select(.{.identifier}).all(&repo);
    try std.testing.expect(dogs2.len == 0); // Empty table but valid select columns.
}

test "optional DateTime" {
    try resetDatabase();

    const Schema = struct {
        pub const Thing = jetquery.Model(
            @This(),
            "things",
            struct {
                a: ?jetquery.DateTime,
                b: ?jetquery.DateTime,
            },
            .{},
        );
    };
    var repo = try Repo(.postgresql, Schema).init(std.testing.allocator, .{
        .adapter = .{
            .database = "repo_test",
            .username = "postgres",
            .hostname = "127.0.0.1",
            .password = "password",
            .port = 5432,
        },
    });
    defer repo.deinit();

    try repo.createTable("things", &.{
        jetquery.schema.table.column("a", .datetime, .{ .optional = true }),
        jetquery.schema.table.column("b", .datetime, .{ .optional = true }),
    }, .{});

    const now = jetquery.DateTime.now();

    try repo.insert(.Thing, .{
        .a = now,
        .b = null,
    });

    if (try repo.Query(.Thing).findBy(.{ .a = now }).execute(&repo)) |thing| {
        defer repo.free(thing);
        try std.testing.expect(thing.a != null);
        try std.testing.expect(thing.a.?.eql(now));
        try std.testing.expect(thing.b == null);
    } else try std.testing.expect(false);
}

test "optionals" {
    try resetDatabase();

    const Schema = struct {
        pub const Thing = jetquery.Model(
            @This(),
            "things",
            struct {
                a: ?bool,
                b: ?[]const u8,
                c: ?i32,
                d: ?i64,
                e: ?f32,
                f: ?f64,
                g: ?jetquery.DateTime,
            },
            .{},
        );
    };
    var repo = try Repo(.postgresql, Schema).init(std.testing.allocator, .{
        .adapter = .{
            .database = "repo_test",
            .username = "postgres",
            .hostname = "127.0.0.1",
            .password = "password",
            .port = 5432,
        },
    });
    defer repo.deinit();

    try repo.createTable("things", &.{
        jetquery.schema.table.column("a", .boolean, .{ .optional = true }),
        jetquery.schema.table.column("b", .string, .{ .optional = true }),
        jetquery.schema.table.column("c", .integer, .{ .optional = true }),
        jetquery.schema.table.column("d", .bigint, .{ .optional = true }),
        jetquery.schema.table.column("e", .float, .{ .optional = true }),
        jetquery.schema.table.column("f", .double_precision, .{ .optional = true }),
        jetquery.schema.table.column("g", .datetime, .{ .optional = true }),
    }, .{});

    const now = jetquery.DateTime.now();

    const insert1 = repo.Query(.Thing).insert(.{
        .a = @as(?bool, null),
        .b = @as(?[]const u8, null),
        .c = @as(?i32, null),
        .d = @as(?i64, null),
        .e = @as(?f32, null),
        .f = @as(?f64, null),
        .g = @as(?jetquery.DateTime, null),
    });
    const select1 = repo.Query(.Thing).where(.{
        .a = @as(?bool, null),
        .b = @as(?[]const u8, null),
        .c = @as(?i32, null),
        .d = @as(?i64, null),
        .e = @as(?f32, null),
        .f = @as(?f64, null),
        .g = @as(?jetquery.DateTime, null),
    });

    const insert2 = repo.Query(.Thing).insert(.{
        .a = @as(?bool, true),
        .b = @as(?[]const u8, "foo"),
        .c = @as(?i32, 123),
        .d = @as(?i64, 456),
        .e = @as(?f32, 123.4),
        .f = @as(?f64, 567.8),
        .g = @as(?jetquery.DateTime, now),
    });
    const select2 = repo.Query(.Thing).where(.{
        .a = @as(?bool, true),
        .b = @as(?[]const u8, "foo"),
        .c = @as(?i32, 123),
        .d = @as(?i64, 456),
        .e = @as(?f32, 123.4),
        .f = @as(?f64, 567.8),
        .g = @as(?jetquery.DateTime, now),
    });

    try repo.execute(insert1);
    try repo.execute(insert2);

    const things1 = try repo.all(select1);
    defer repo.free(things1);

    try std.testing.expect(things1[0].a == null);
    try std.testing.expect(things1[0].b == null);
    try std.testing.expect(things1[0].c == null);
    try std.testing.expect(things1[0].d == null);
    try std.testing.expect(things1[0].e == null);
    try std.testing.expect(things1[0].f == null);
    try std.testing.expect(things1[0].g == null);

    const things2 = try repo.all(select2);
    defer repo.free(things2);

    try std.testing.expect(things2[0].a.? == true);
    try std.testing.expectEqualStrings(things2[0].b.?, "foo");
    try std.testing.expect(things2[0].c.? == 123);
    try std.testing.expect(things2[0].d.? == 456);
    try std.testing.expect(things2[0].e.? == 123.4);
    try std.testing.expect(things2[0].f.? == 567.8);
    try std.testing.expect(things2[0].g.?.eql(now));
}

fn resetDatabase() !void {
    var repo = try Repo(.postgresql, void).init(
        std.testing.allocator,
        .{
            .adapter = .{
                .database = "postgres",
                .username = "postgres",
                .hostname = "127.0.0.1",
                .password = "password",
                .port = 5432,
            },
        },
    );
    defer repo.deinit();
    try repo.dropDatabase("repo_test", .{ .if_exists = true });
    try repo.createDatabase("repo_test", .{});
}
