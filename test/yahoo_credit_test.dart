import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reachtrail_app/app.dart';
import 'package:reachtrail_app/models/place.dart';

Place _place(String provider) => Place(
  id: '$provider-1',
  provider: provider,
  providerPlaceId: '1',
  name: 'テスト店',
  lat: 35.0,
  lng: 135.0,
  address: '',
);

void main() {
  testWidgets('shows the Yahoo credit only when Yahoo results are on screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: YahooCreditFor(places: [_place('yahoo')])),
      ),
    );
    expect(find.text('Web Services by Yahoo! JAPAN'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: YahooCreditFor(places: [_place('manual')])),
      ),
    );
    expect(find.text('Web Services by Yahoo! JAPAN'), findsNothing);
  });
}
