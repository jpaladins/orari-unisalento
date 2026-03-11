import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
void test() {
  final _plugin = FlutterLocalNotificationsPlugin();
  _plugin.zonedSchedule(
    '1',
    'title',
    'body',
    tz.TZDateTime.now(tz.local),
    const NotificationDetails(),
    androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
  );
}
