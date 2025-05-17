# JetQuery IN Query Support

This document provides examples of using SQL `IN` and `NOT IN` queries in JetQuery.

## Table of Contents
- [Using IN Queries](#using-in-queries)
  - [Helper Function Syntax](#helper-function-syntax)
  - [Explicit Operator Syntax](#explicit-operator-syntax)
- [Implementation Details](#implementation-details)
- [Examples](#examples)

## Using IN Queries

JetQuery offers two ways to use `IN` and `NOT IN` queries:

### Helper Function Syntax

The helper function syntax is more ergonomic and recommended for most use cases:

```zig
const ids = &[_]i32{ 1, 2, 3 };

// Using the in helper
const users = try repo.Query(.User)
    .where(.{ .id = jetquery.sql.in(i32, ids) })
    .all(&repo);

// Using the notIn helper
const users = try repo.Query(.User)
    .where(.{ .id = jetquery.sql.notIn(i32, ids) })
    .all(&repo);
```

### Explicit Operator Syntax

The explicit operator syntax uses `.in_` and `.not_in` fields:

```zig
const ids = &[_]i32{ 1, 2, 3 };

// Using explicit .in_ operator
const users = try repo.Query(.User)
    .where(.{ .id = .{ .in_ = ids } })
    .all(&repo);

// Using explicit .not_in operator
const users = try repo.Query(.User)
    .where(.{ .id = .{ .not_in = ids } })
    .all(&repo);
```

## Implementation Details

The implementation translates these queries to PostgreSQL's `ANY` and `ALL` operators:
- `IN` is translated to `= ANY(parameters)`
- `NOT IN` is translated to `<> ALL(parameters)`

For array parameters, JetQuery encodes them in PostgreSQL's array format, e.g., `{1,2,3}`.

## Examples

### Finding records with IDs in a list

```zig
const post_ids = &[_]i32{ 1, 2, 3 };

const posts = try repo.Query(.Post)
    .where(.{ .id = jetquery.sql.in(i32, post_ids) })
    .all(&repo);
```

### Finding records related to multiple entities

```zig
const category_ids = &[_]i32{ 1, 2, 3 };

const products = try repo.Query(.Product)
    .where(.{ .category_id = jetquery.sql.in(i32, category_ids) })
    .all(&repo);
```

### Complex queries with IN and other conditions

```zig
const valid_statuses = &[_][]const u8{ "active", "pending" };
const item_ids = &[_]i32{ 42, 43, 44 };

const orders = try repo.Query(.Order)
    .where(.{
        .status = jetquery.sql.in([]const u8, valid_statuses),
        .item_id = jetquery.sql.in(i32, item_ids),
        .created_at = .{ .gt = some_date },
    })
    .all(&repo);
```

### Using OR with IN queries

```zig
const user_ids = &[_]i32{ 1, 2, 3 };
const department_ids = &[_]i32{ 4, 5, 6 };

const employees = try repo.Query(.Employee)
    .where(.{
        .{
            .user_id = jetquery.sql.in(i32, user_ids),
        },
        .OR,
        .{
            .department_id = jetquery.sql.in(i32, department_ids),
        },
    })
    .all(&repo);
```

### Using IN with related entities

```zig
// Find orders with at least one item from specified categories
const category_ids = &[_]i32{ 1, 2, 3 };

const orders = try repo.Query(.Order)
    .join(.inner, .items)
    .where(.{
        .items = .{
            .category_id = jetquery.sql.in(i32, category_ids),
        },
    })
    .all(&repo);
```