// Unit tests for the in-app diagnostic log buffer.

import 'package:flutter_test/flutter_test.dart';

import 'package:media_canvas/services/app_log.dart';

void main() {
  setUp(() => AppLog.instance.clear());

  test('log() appends a timestamped, tagged line', () {
    AppLog.instance.log('proxy', 'hello');
    expect(AppLog.instance.lines, hasLength(1));
    expect(AppLog.instance.lines.single, contains('[proxy] hello'));
    // Starts with HH:mm:ss.mmm
    expect(AppLog.instance.lines.single,
        matches(RegExp(r'^\d\d:\d\d:\d\d\.\d{3} ')));
  });

  test('dump() joins all lines; clear() empties', () {
    AppLog.instance.log('a', '1');
    AppLog.instance.log('b', '2');
    expect(AppLog.instance.dump().split('\n'), hasLength(2));
    AppLog.instance.clear();
    expect(AppLog.instance.lines, isEmpty);
  });

  test('changes stream fires on log and clear', () async {
    final events = <void>[];
    final sub = AppLog.instance.changes.listen(events.add);
    AppLog.instance.log('x', 'y');
    AppLog.instance.clear();
    await Future<void>.delayed(Duration.zero);
    expect(events.length, greaterThanOrEqualTo(2));
    await sub.cancel();
  });

  test('buffer is capped (does not grow unbounded)', () {
    for (var i = 0; i < 1000; i++) {
      AppLog.instance.log('t', 'line $i');
    }
    expect(AppLog.instance.lines.length, lessThanOrEqualTo(800));
    // Newest line is retained.
    expect(AppLog.instance.lines.last, contains('line 999'));
  });
}
