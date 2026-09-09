import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reachtrail_app/pages/usage_guide_page.dart';

/// Every heading the guide promises, in the order a new user reads them.
const _headings = [
  'ReachTrail でできること',
  '1. 基準地点を登録する',
  '2. お店を探す',
  '3. 記録する',
  '4. 地図アプリでナビ',
  '5. 地図で振り返る',
  '位置情報とプライバシー',
  'アカウント',
];

void main() {
  testWidgets('the guide lists every section', (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: UsageGuidePage()));
    await tester.pumpAndSettle();

    expect(find.text('使い方ガイド'), findsOneWidget);
    for (final heading in _headings) {
      await tester.scrollUntilVisible(
        find.text(heading),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(heading), findsOneWidget, reason: heading);
    }
  });

  testWidgets('the privacy card links out to the full policy', (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: UsageGuidePage()));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('プライバシーポリシーを開く'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('プライバシーポリシーを開く'), findsOneWidget);
    expect(privacyPolicyUrl, 'https://reachtrail.riumu.net/privacy.html');
  });
}
