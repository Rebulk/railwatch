# Query diagnostics

The Railwatch query detail page shows advice from captured SQL, the source
connection and adapter, a stored query plan when available, and captured N+1
samples. The same analyzer powers the local dashboard and Railwatch Cloud.
Opening the page reads telemetry only. It does not run the captured statement,
request a new plan from the application database, or execute schema changes.

Each finding identifies its evidence:

- **SQL heuristic**: a possible index shape derived from equality filters,
  explicit join keys, range predicates and plain `ORDER BY` columns. Review
  existing indexes, selectivity, query frequency and write costs before testing
  a candidate. Railwatch does not infer that an index is missing, and does not
  generate executable DDL.
- **Captured plan**: an operation observed in one stored EXPLAIN sample. A scan
  may be appropriate for a small table or a broad filter. A sort does not prove
  an index can eliminate it. Estimates and parameter values can change the
  chosen plan. The plan's timestamp, connection and adapter identify its sample.
- **Captured repetition**: a recorded N+1 occurrence. Existing Rails loading
  suggestions are shown as examples; verify inferred association names and
  application semantics before applying them.

The index analyzer accepts a conservative subset of SELECT statements for
PostgreSQL and compatible adapters, SQLite, and MySQL/Trilogy. It handles quoted
identifiers, schema-qualified table names, explicit table aliases, bound values,
AND predicates, `IS NULL` filters and plain ordering columns. Selected columns
must be plain references or wildcards; output aliases and selected expressions
are not treated as source columns. Unqualified PostgreSQL names matching a table
or its alias are also ambiguous because they can refer to the whole row.
Expressions, subqueries, CTEs, disjunctions, self-joins, ambiguous columns,
executable MySQL comments and unsupported adapters are left for manual review.
A normalized `IN` list does not establish single-valued equality, so it is not used to claim
that a following index column satisfies ordering. A range on one column is not
assumed to support sorting on another. No findings does not establish that a
query is optimal.

For example, `WHERE tenant_id = ? AND status = ? ORDER BY created_at DESC`
produces a candidate containing `tenant_id`, `status` and `created_at` with the
original filter and ordering clauses as evidence. Their order still needs
validation against existing indexes and the workload. With
`WHERE tenant_id = ? AND created_at >= ? ORDER BY score DESC`, the candidate
contains `tenant_id` and `created_at`; it makes no claim that appending `score`
would satisfy the ordering.

Plan observations support the text formats emitted by Rails for PostgreSQL,
SQLite and MySQL, including MySQL's table format. Raw plan text remains visible
when its format is not recognized. Railwatch does not treat unrecognized plan
text as evidence that the query has no performance problems.

Analysis is bounded to 16,384 input SQL bytes, 2,000 tokens, six tables and 24
levels of predicate grouping. Longer statements are not analyzed as partial
SQL. Stored plans are limited to 32,768 input bytes and 200 displayed lines;
the page marks excerpts. At most twelve findings and six plan observations are
returned. Evidence excerpts are capped at 1,000 input bytes. The detail page
uses its existing 100 recent samples, one stored plan, and one recent N+1
sample from the same query group and selected time window.

Schema snapshots elsewhere in Railwatch do not establish which indexes existed
for a historical query sample. Query diagnostics therefore retain the
qualification that source schema and index coverage need verification.
