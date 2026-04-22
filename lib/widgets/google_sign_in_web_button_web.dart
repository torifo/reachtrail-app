import 'package:flutter/material.dart';
import 'package:google_sign_in_web/google_sign_in_web.dart';
import 'package:google_sign_in_web/web_only.dart' as google_web;

Widget buildGoogleWebSignInButton() {
  return google_web.renderButton(
    configuration: GSIButtonConfiguration(
      theme: GSIButtonTheme.outline,
      size: GSIButtonSize.large,
      text: GSIButtonText.continueWith,
      shape: GSIButtonShape.pill,
      minimumWidth: 280,
    ),
  );
}
