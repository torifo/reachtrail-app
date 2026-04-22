import 'dart:io';

import 'package:reachtrail_api/reachtrail_api.dart';

Future<void> main() async {
  final config = ReachTrailApiConfig.fromEnvironment();
  final server = await runServer(config);
  stdout.writeln('ReachTrail API listening on port ${server.port}');
}
