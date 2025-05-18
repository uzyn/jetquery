# IN Query Implementation for JetQuery

This PR adds support for SQL IN and NOT IN queries in JetQuery, allowing users to check if a value is in a set of values.

## Features

- Added `.in_` and `.not_in` operators in the Where clause triplet system
- Implemented PostgreSQL-specific array parameter handling with ANY/ALL syntax
- Created comprehensive tests for the IN query functionality
- Added documentation for the IN query usage

## Implementation Details

### SQL Operators

Added two new operators to the `Triplet.Operator` enum in `Where.zig`:
- `.in_` - For SQL IN queries, rendered as "= ANY()" in PostgreSQL
- `.not_in` - For SQL NOT IN queries, rendered as "<> ALL()" in PostgreSQL

### SQL Generation

The operators are rendered as PostgreSQL-specific syntax:
- `.in_` becomes "= ANY($1)" where the parameter is a PostgreSQL array
- `.not_in` becomes "<> ALL($1)" where the parameter is a PostgreSQL array

### Usage Examples

```zig
// Find users with IDs 1, 2, or 3
const users = try repo.Query(.User)
    .where(.{ .id, .in_, &[_]i32{ 1, 2, 3 } })
    .all(&repo);

// Find users that are not admins or moderators
const regular_users = try repo.Query(.User)
    .where(.{ .role, .not_in, &[_][]const u8{ "admin", "moderator" } })
    .all(&repo);
```

## Testing

- Created unit tests for IN query functionality in `src/test_in_query.zig`
- Added a dedicated test build target `test-in-query`
- Verified that all tests pass with both the normal test suite and the specific IN query tests

## Documentation

- Added IN query usage examples to the README
- Created a dedicated usage guide in `IN-QUERY-USAGE.md`
- Added detailed comments in the code to explain the implementation

## Future Improvements

- Add support for other database adapters (currently PostgreSQL-specific)
- Implement subquery support for IN queries
- Optimize array parameter handling for different data types