import 'dart:mirrors';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
void main() {
  final m = reflectClass(FlutterLocalNotificationsPlugin).declarations[#zonedSchedule] as MethodMirror;
  for (final p in m.parameters) {
    print('${p.isNamed ? "named" : "positional"}: ${MirrorSystem.getName(p.simpleName)}');
  }
}
