import 'dart:math';

double calculateDistanceMeters({
  required double startLat,
  required double startLng,
  required double endLat,
  required double endLng,
}) {
  const earthRadiusMeters = 6371000.0;
  final dLat = _degToRad(endLat - startLat);
  final dLng = _degToRad(endLng - startLng);
  final lat1 = _degToRad(startLat);
  final lat2 = _degToRad(endLat);
  final a =
      sin(dLat / 2) * sin(dLat / 2) +
      cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2);
  final c = 2 * atan2(sqrt(a), sqrt(1 - a));
  return earthRadiusMeters * c;
}

double _degToRad(double degrees) => degrees * pi / 180;
