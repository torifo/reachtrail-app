import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reachtrail_app/app.dart';

/// Pumps the account menu on its own so the three entries can be exercised
/// without booting the whole app.
Future<void> _pumpMenu(
  WidgetTester tester, {
  required List<String> log,
  bool enabled = true,
  String? displayName,
  String? email,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          actions: [
            AccountMenuButton(
              enabled: enabled,
              displayName: displayName,
              email: email,
              onSignOut: () => log.add('sign-out'),
              onSwitchAccount: () => log.add('switch'),
              onDeleteAccount: () => log.add('delete'),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  group('AccountMenuButton', () {
    testWidgets('offers sign-out, switch and delete in that order', (
      tester,
    ) async {
      final log = <String>[];
      await _pumpMenu(tester, log: log);

      expect(find.byTooltip('アカウント'), findsOneWidget);
      expect(find.byIcon(Icons.account_circle), findsOneWidget);

      await tester.tap(find.byTooltip('アカウント'));
      await tester.pumpAndSettle();

      final signOut = tester.getTopLeft(find.text('サインアウト')).dy;
      final switchAccount = tester.getTopLeft(find.text('アカウントを切り替える')).dy;
      final delete = tester.getTopLeft(find.text('アカウントを削除')).dy;
      expect(signOut, lessThan(switchAccount));
      expect(switchAccount, lessThan(delete));
    });

    testWidgets('runs the callback of the entry that was picked', (
      tester,
    ) async {
      final log = <String>[];

      for (final entry in const [
        ('サインアウト', 'sign-out'),
        ('アカウントを切り替える', 'switch'),
        ('アカウントを削除', 'delete'),
      ]) {
        await _pumpMenu(tester, log: log);
        await tester.tap(find.byTooltip('アカウント'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(entry.$1));
        await tester.pumpAndSettle();

        expect(log.last, entry.$2);
      }

      expect(log, ['sign-out', 'switch', 'delete']);
    });

    testWidgets('opens nothing while an account operation is running', (
      tester,
    ) async {
      final log = <String>[];
      await _pumpMenu(tester, log: log, enabled: false);

      await tester.tap(find.byTooltip('アカウント'));
      await tester.pumpAndSettle();

      expect(find.text('サインアウト'), findsNothing);
      expect(find.text('アカウントを切り替える'), findsNothing);
      expect(find.text('アカウントを削除'), findsNothing);
      expect(log, isEmpty);
    });

    testWidgets('names the signed-in account above the actions', (
      tester,
    ) async {
      final log = <String>[];
      await _pumpMenu(
        tester,
        log: log,
        displayName: '芝二郎',
        email: 'jiro@example.com',
      );

      await tester.tap(find.byTooltip('アカウント'));
      await tester.pumpAndSettle();

      expect(find.text('芝二郎'), findsOneWidget);
      expect(find.text('jiro@example.com'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('芝二郎')).dy,
        lessThan(tester.getTopLeft(find.text('サインアウト')).dy),
      );

      // The header names the account; it is not a fourth thing to pick.
      await tester.tap(find.text('芝二郎'));
      await tester.pumpAndSettle();
      expect(log, isEmpty);
      expect(find.text('サインアウト'), findsOneWidget);
    });

    testWidgets('shows no header when nobody is named', (tester) async {
      final log = <String>[];
      await _pumpMenu(tester, log: log);

      await tester.tap(find.byTooltip('アカウント'));
      await tester.pumpAndSettle();

      expect(find.byType(PopupMenuDivider), findsOneWidget);
    });
  });

  group('switch account confirmation', () {
    testWidgets('warns that local data is wiped for a different account', (
      tester,
    ) async {
      bool? answer;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  answer = await showSwitchAccountConfirmation(context);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('アカウントを切り替えますか？'), findsOneWidget);
      expect(
        find.text(
          '別の Google アカウントでサインインします。'
          '別のアカウントに切り替えた場合、この端末に保存されている基準地点・店舗・記録は'
          '消去されます（同じアカウントを選び直した場合は残ります）。',
        ),
        findsOneWidget,
      );
      expect(find.text('キャンセル'), findsOneWidget);
      expect(find.text('切り替える'), findsOneWidget);

      await tester.tap(find.text('キャンセル'));
      await tester.pumpAndSettle();
      expect(answer, isFalse);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('切り替える'));
      await tester.pumpAndSettle();
      expect(answer, isTrue);
    });
  });
}
