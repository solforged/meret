/// The UI edits one field of a search without rewriting the other clauses.
/// Quotes follow the core query lexer: whitespace inside double quotes stays
/// in the same clause, and a quoted `dr:12` is free text, not a DR filter.
class QueryClause {
  const QueryClause(this.text);

  final String text;

  String? get field => RegExp(r'^-?([a-zA-Z]+):').firstMatch(text)?.group(1)?.toLowerCase();
  bool get negated => text.startsWith('-');
  String get value => text.substring(text.indexOf(':') + 1).replaceAll('"', '');
}

List<QueryClause> queryClauses(String query) {
  final result = <QueryClause>[];
  var quoted = false;
  var start = 0;
  final whitespace = RegExp(r'\s', unicode: true);
  for (var i = 0; i < query.length; i++) {
    if (query[i] == '"') quoted = !quoted;
    if (!quoted && whitespace.hasMatch(query[i])) {
      if (i > start) result.add(QueryClause(query.substring(start, i)));
      start = i + 1;
    }
  }
  if (start < query.length) result.add(QueryClause(query.substring(start)));
  return result;
}

String replaceQueryField(String query, String field, String? replacement) => [
  for (final clause in queryClauses(query)) if (clause.field != field) clause.text,
  ?replacement,
].join(' ');

String removeQueryClause(String query, int index) => [
  for (final (i, clause) in queryClauses(query).indexed) if (i != index) clause.text,
].join(' ');

String clearQueryFilters(String query) => queryClauses(query).where((clause) => clause.field == null).map((clause) => clause.text).join(' ');

/// Numeric selection for painting an existing positive range. Complex or
/// negated constraints remain visible in the filter chips without pretending
/// that a single brush describes them.
(double, double)? queryNumberBounds(String query, String field, double minimum, double maximum) {
  final clauses = queryClauses(query).where((clause) => clause.field == field).toList();
  if (clauses.length != 1 || clauses.single.negated) return null;
  final value = clauses.single.value;
  final parts = value.split('..');
  double? lower, upper;
  if (parts.length == 2) {
    lower = double.tryParse(parts[0]);
    upper = double.tryParse(parts[1]);
  } else if (value.startsWith('>')) {
    lower = double.tryParse(value.substring(1));
    upper = maximum;
  } else if (value.startsWith('<')) {
    lower = minimum;
    upper = double.tryParse(value.substring(1));
  } else if (field == 'year' && value.endsWith('s')) {
    lower = double.tryParse(value.substring(0, value.length - 1));
    upper = lower == null ? null : lower + 9;
  } else {
    lower = upper = double.tryParse(value);
  }
  if (lower == null || upper == null || !lower.isFinite || !upper.isFinite || lower > upper) return null;
  return (lower, upper);
}

(double, double)? queryNumberRange(String query, String field, double minimum, double maximum) {
  final bounds = queryNumberBounds(query, field, minimum, maximum);
  return bounds == null ? null : (((bounds.$1 - minimum) / (maximum - minimum)).clamp(0, 1), ((bounds.$2 - minimum) / (maximum - minimum)).clamp(0, 1));
}

int? queryRecentDays(String query) {
  final clauses = queryClauses(query).where((clause) => clause.field == 'last').toList();
  if (clauses.length != 1 || clauses.single.negated) return null;
  final match = RegExp(r'^(\d+)([dwmy])$').firstMatch(clauses.single.value);
  if (match == null) return null;
  final amount = int.tryParse(match.group(1)!);
  return amount == null ? null : amount * switch (match.group(2)) { 'w' => 7, 'm' => 30, 'y' => 365, _ => 1 };
}

(double, double)? queryRecentRange(String query) {
  final days = queryRecentDays(query);
  return days == null ? null : ((1 - days / 365).clamp(0, 1), 1);
}
