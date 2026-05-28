part of '../app.dart';

class ReachTrailSignInScreen extends StatelessWidget {
  const ReachTrailSignInScreen({super.key, required this.authService});

  final GoogleAuthService authService;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFF4EEE0), Color(0xFFE8F2EC), Color(0xFFF8F3EA)],
          ),
        ),
        child: Stack(
          children: [
            const _SignInBackground(),
            SafeArea(child: _SignInBody(authService: authService)),
          ],
        ),
      ),
    );
  }
}

class _SignInBackground extends StatelessWidget {
  const _SignInBackground();

  @override
  Widget build(BuildContext context) {
    return const Stack(
      children: [
        Positioned(
          top: -80,
          left: -60,
          child: _BackdropOrb(
            size: 240,
            colors: [Color(0x33B45309), Color(0x00B45309)],
          ),
        ),
        Positioned(
          right: -40,
          top: 100,
          child: _BackdropOrb(
            size: 220,
            colors: [Color(0x3314B8A6), Color(0x0014B8A6)],
          ),
        ),
        Positioned(
          bottom: -120,
          right: 40,
          child: _BackdropOrb(
            size: 280,
            colors: [Color(0x260F766E), Color(0x000F766E)],
          ),
        ),
      ],
    );
  }
}

class _SignInBody extends StatelessWidget {
  const _SignInBody({required this.authService});

  final GoogleAuthService authService;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, viewportConstraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: viewportConstraints.maxHeight - 48,
            ),
            child: Center(child: _SignInContent(authService: authService)),
          ),
        );
      },
    );
  }
}

class _SignInContent extends StatelessWidget {
  const _SignInContent({required this.authService});

  final GoogleAuthService authService;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 960),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final layout = _SignInLayoutData.fromWidth(constraints.maxWidth);

          return Wrap(
            spacing: layout.spacing,
            runSpacing: 24,
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: layout.heroWidth,
                child: _HeroPanel(theme: theme),
              ),
              SizedBox(
                width: layout.cardWidth,
                child: _SignInCard(authService: authService, theme: theme),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _NoStretchScrollBehavior extends MaterialScrollBehavior {
  const _NoStretchScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

class _SignInLayoutData {
  const _SignInLayoutData({
    required this.heroWidth,
    required this.cardWidth,
    required this.spacing,
  });

  final double heroWidth;
  final double cardWidth;
  final double spacing;

  factory _SignInLayoutData.fromWidth(double width) {
    final compact = width < 760;
    return _SignInLayoutData(
      heroWidth: compact ? width : math.min(width * 0.55, 560.0),
      cardWidth: compact ? width : math.min(width * 0.4, 420.0),
      spacing: compact ? 0 : 28,
    );
  }
}

class _SignInCard extends StatelessWidget {
  const _SignInCard({required this.authService, required this.theme});

  final GoogleAuthService authService;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Sign In',
              style: theme.textTheme.titleMedium?.copyWith(
                letterSpacing: 0.4,
                color: const Color(0xFF0F766E),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Google アカウントでサインインして、基準地点からの距離と階数をまとめて記録します。',
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 24),
            _GoogleSignInAction(authService: authService),
            const SizedBox(height: 18),
            Text(
              'メール認証は後続対応です。先行公開版では Google ログインのみ提供します。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF475569),
              ),
            ),
            if (authService.errorMessage case final message?) ...[
              const SizedBox(height: 16),
              Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _GoogleSignInAction extends StatelessWidget {
  const _GoogleSignInAction({required this.authService});

  final GoogleAuthService authService;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb && !GoogleSignIn.instance.supportsAuthenticate()) {
      return Center(child: buildGoogleWebSignInButton());
    }

    return FilledButton.icon(
      onPressed: authService.isSigningIn ? null : authService.signIn,
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFF0F766E),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      icon: authService.isSigningIn
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.login),
      label: const Text('Google でサインイン'),
    );
  }
}

class _HeroPanel extends StatelessWidget {
  const _HeroPanel({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: const Color(0x1A0F172A)),
          ),
          child: Text(
            'Dine Distance Tracker',
            style: theme.textTheme.labelLarge?.copyWith(
              color: const Color(0xFF0F766E),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 18),
        Text(
          'ReachTrail',
          style: theme.textTheme.displaySmall?.copyWith(
            fontWeight: FontWeight.w800,
            height: 0.94,
            color: const Color(0xFF111827),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          '基準地点から店までの距離＆階数の組み合わせて到達難易度、行ったお店の一覧をまとめて記録できる外食ログアプリ。',
          style: theme.textTheme.titleMedium?.copyWith(
            color: const Color(0xFF334155),
            height: 1.5,
          ),
        ),
        const SizedBox(height: 26),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: const [
            _Tag(label: 'Google Sign-In'),
            _Tag(label: 'Yahoo'),
            _Tag(label: 'Building + Floor Fallback'),
          ],
        ),
        const SizedBox(height: 28),
        const _HeroFeature(
          title: 'Search',
          description: '店名で候補を探し、見つからない時は建物名と住所から補完します。',
        ),
        const SizedBox(height: 14),
        const _HeroFeature(
          title: 'Measure',
          description: '基準地点からの距離と階数を使って、移動の負荷を可視化します。',
        ),
        const SizedBox(height: 14),
        const _HeroFeature(
          title: 'Record',
          description: '候補選択でも手入力でも、後から見返せる形で外食記録を残せます。',
        ),
      ],
    );
  }
}

class _HeroFeature extends StatelessWidget {
  const _HeroFeature({required this.title, required this.description});

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 10,
          height: 10,
          margin: const EdgeInsets.only(top: 7),
          decoration: const BoxDecoration(
            color: Color(0xFFB45309),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF475569),
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BackdropOrb extends StatelessWidget {
  const _BackdropOrb({required this.size, required this.colors});

  final double size;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: colors),
        ),
      ),
    );
  }
}
