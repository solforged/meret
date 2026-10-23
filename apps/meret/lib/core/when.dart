/// How Meret says when something happened. One voice for the Front, Now
/// and the strip: "Tuesday", "yesterday", "23:14", "2y".
library;

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

DateTime _local(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

DateTime _midnight(DateTime t) => DateTime(t.year, t.month, t.day);

/// The day as a word: "today", "yesterday", a weekday within the last six
/// days, "12 Oct" this year, "12 Oct 2024" before that.
String dayWord(int ms, {DateTime? now}) {
  now ??= DateTime.now();
  final then = _local(ms);
  final days = _midnight(now).difference(_midnight(then)).inDays;
  if (days <= 0) return 'today';
  if (days == 1) return 'yesterday';
  if (days < 7) return _weekdays[then.weekday - 1];
  final date = '${then.day} ${_months[then.month - 1]}';
  return then.year == now.year ? date : '$date ${then.year}';
}

/// "Tuesday's", "today's", "12 Oct's": the day as an owner, for "[ to resume Tuesday's".
String dayPossessive(int ms, {DateTime? now}) => "${dayWord(ms, now: now)}'s";

/// Wall-clock time, "23:14".
String clockTime(int ms) {
  final t = _local(ms);
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// Calendar day, "Tue 13 Oct".
String dayDate(int ms) {
  final t = _local(ms);
  return '${_weekdays[t.weekday - 1].substring(0, 3)} ${t.day} ${_months[t.month - 1]}';
}

/// "Tue 23:14" today or this week, otherwise "12 Oct 23:14".
String dayAndTime(int ms, {DateTime? now}) {
  now ??= DateTime.now();
  final then = _local(ms);
  final days = _midnight(now).difference(_midnight(then)).inDays;
  final day = days < 7 ? _weekdays[then.weekday - 1].substring(0, 3) : '${then.day} ${_months[then.month - 1]}';
  return '$day ${clockTime(ms)}';
}

/// How long ago, tersely: "2y", "18mo", "3d", "5h", "now".
String agoShort(int ms, {DateTime? now}) {
  final elapsed = (now ?? DateTime.now()).difference(_local(ms));
  if (elapsed.inDays >= 365) return '${elapsed.inDays ~/ 365}y';
  if (elapsed.inDays >= 30) return '${elapsed.inDays ~/ 30}mo';
  if (elapsed.inDays >= 1) return '${elapsed.inDays}d';
  if (elapsed.inHours >= 1) return '${elapsed.inHours}h';
  if (elapsed.inMinutes >= 1) return '${elapsed.inMinutes}m';
  return 'now';
}

/// A position or length, "3:46" or "1:12:05".
String clockLength(int ms) {
  final seconds = ms ~/ 1000;
  final mmss = '${seconds ~/ 60 % 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  return seconds >= 3600 ? '${seconds ~/ 3600}:${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}' : mmss;
}

/// Listening time as people say it: "31 h", "48 min", "under a minute".
String listeningTime(int ms) {
  final minutes = ms ~/ 60000;
  if (minutes >= 60) return '${minutes ~/ 60} h${minutes % 60 == 0 ? '' : ' ${minutes % 60} min'}';
  if (minutes >= 1) return '$minutes min';
  return 'under a minute';
}
