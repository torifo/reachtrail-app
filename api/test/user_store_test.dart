import 'dart:io';

import 'package:reachtrail_api/src/server.dart';
import 'package:test/test.dart';

void main() {
  test('user store upserts by google sub', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'reachtrail-api-test',
    );
    final store = ReachTrailUserStore('${tempDir.path}/users.json');

    final created = await store.upsertGoogleUser(
      googleSub: 'google-sub-1',
      email: 'first@example.com',
      displayName: 'First',
    );
    final updated = await store.upsertGoogleUser(
      googleSub: 'google-sub-1',
      email: 'updated@example.com',
      displayName: 'Updated',
    );

    expect(updated.id, created.id);
    expect(updated.email, 'updated@example.com');
    expect(updated.displayName, 'Updated');

    await tempDir.delete(recursive: true);
  });
}
