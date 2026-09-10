import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Where the full policy lives; the in-app text only summarises it.
const String privacyPolicyUrl = 'https://reachtrail.riumu.net/privacy.html';

/// A plain-language walkthrough of the app, reachable from the app bar.
///
/// The tabs each explain their own controls, but nothing tied them together,
/// so a first-time user had to guess the order of 基準 → 登録 → 記録 → 地図.
class UsageGuidePage extends StatelessWidget {
  const UsageGuidePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('使い方ガイド')),
      body: ListView(
        // Edge-to-edge: keep the last card clear of the system navigation bar.
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          20 + MediaQuery.paddingOf(context).bottom,
        ),
        children: const [
          _GuideCard(
            title: 'ReachTrail でできること',
            paragraphs: [
              '職場や自宅などの「基準地点」から、徒歩で行けるお店を探すためのアプリです。',
              '実際に行ったお店は記録として貯まり、あとから地図とランキングで振り返れます。',
            ],
            bullets: ['基準地点から片道徒歩45分圏内のお店を探す', '訪問した記録を難易度つきで残す', '記録を地図で見返す'],
          ),
          SizedBox(height: 16),
          _GuideCard(
            title: '1. 基準地点を登録する',
            paragraphs: [
              'まず「基準」タブで、徒歩の出発点になる場所を登録します。',
              '登録の方法は 4 つあり、どれを使っても構いません。',
              '階数やエレベーターの有無も入力できます。これは記録の難易度の計算に使われます。',
            ],
            bullets: [
              '建物名や住所で検索して候補から選ぶ',
              '住所を手入力する',
              '地図をタップして位置を指定する',
              '「現在地を使う」で今いる場所を取り込む（初回に位置情報の許可を求めます。バックグラウンドでは使いません）',
            ],
          ),
          SizedBox(height: 16),
          _GuideCard(
            title: '2. お店を探す',
            paragraphs: [
              '「登録」タブで、店名・カテゴリ・住所からお店を検索します。',
              '検索の起点は「基準地点」と「現在地」を切り替えられます。',
              '見つかった候補は、リストのほかにレーダーと地図でも確認できます。',
            ],
            bullets: [
              '起点から片道徒歩45分圏内だけに絞り込める',
              'レーダーは起点から見た方向と距離を表示する',
              '地図では起点と候補の位置関係を比べられる',
            ],
          ),
          SizedBox(height: 16),
          _GuideCard(
            title: '3. 記録する',
            paragraphs: [
              '候補の「この候補で記録」から、訪問日や難易度などを入力して保存します。',
              '徒歩の距離は基準地点から計算されるため、記録には基準地点の登録が必要です。',
              '候補が見つからないときは「手入力登録」からも記録できます。',
            ],
            bullets: [],
          ),
          SizedBox(height: 16),
          _GuideCard(
            title: '4. 地図アプリでナビ',
            paragraphs: [
              '候補や記録済みのお店にある「地図アプリで開く」を押すと、端末の地図アプリに目的地を渡せます。',
              'Google マップなど、普段お使いのアプリでそのまま経路を確認できます。',
              'Android では、どの地図アプリで開くかの選択画面が出ます。',
            ],
            bullets: [],
          ),
          SizedBox(height: 16),
          _GuideCard(
            title: '5. 地図で振り返る',
            paragraphs: [
              '「地図」タブでは、記録したお店を地図とランキングで見返せます。',
              'どのあたりまで足を伸ばしたかが一目で分かります。',
              '周辺の人と記録を共有する機能は今後の予定です。',
            ],
            bullets: [],
          ),
          SizedBox(height: 16),
          _GuideCard(
            title: '位置情報とプライバシー',
            paragraphs: [
              '位置情報は「現在地を使う」または検索の起点に「現在地」を選んだときだけ、1 回だけ取得します。',
              '現在地を起点にした検索では、店舗検索のために座標が Yahoo! JAPAN に送信されます。',
              '位置情報の許可は、端末の設定からいつでも取り消せます。',
            ],
            bullets: [],
            showPrivacyLink: true,
          ),
          SizedBox(height: 16),
          _GuideCard(
            title: 'アカウント',
            paragraphs: [
              '画面右上のアカウントメニューから、サインアウト・アカウント切り替え・アカウント削除ができます。',
              'アカウントを切り替えると、前のアカウントの端末内データは消えます。',
              'アカウントを削除すると、サーバー上の情報も端末内のデータもすべて消えます。',
            ],
            bullets: [],
          ),
        ],
      ),
    );
  }
}

/// The same shape as the cards on the tabs, kept local so the guide does not
/// force a private widget in `app.dart` to become public.
class _GuideCard extends StatelessWidget {
  const _GuideCard({
    required this.title,
    required this.paragraphs,
    required this.bullets,
    this.showPrivacyLink = false,
  });

  final String title;
  final List<String> paragraphs;
  final List<String> bullets;

  /// Adds the link out to the full policy; only the privacy card uses it.
  final bool showPrivacyLink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE4DDD1)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Text(title, style: theme.textTheme.titleLarge),
            for (final paragraph in paragraphs) Text(paragraph),
            for (final bullet in bullets)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('・'),
                  Expanded(child: Text(bullet)),
                ],
              ),
            if (showPrivacyLink)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => unawaited(
                    launchUrl(
                      Uri.parse(privacyPolicyUrl),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('プライバシーポリシーを開く'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
