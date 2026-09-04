class BaseLocation {
  const BaseLocation({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    this.floorLabel = '',
    this.floorNumber,
    this.entryFloorLabel = '',
    this.entryFloorNumber,
    this.hasElevator = true,
    this.elevatorRideCount,
    this.memo = '',
  });

  final String id;
  final String name;
  final double lat;
  final double lng;
  final String floorLabel;
  final int? floorNumber;
  final String entryFloorLabel;
  final int? entryFloorNumber;
  final bool hasElevator;
  final int? elevatorRideCount;
  final String memo;

  BaseLocation copyWith({
    String? id,
    String? name,
    double? lat,
    double? lng,
    String? floorLabel,
    int? floorNumber,
    bool clearFloorNumber = false,
    String? entryFloorLabel,
    int? entryFloorNumber,
    bool clearEntryFloorNumber = false,
    bool? hasElevator,
    int? elevatorRideCount,
    bool clearElevatorRideCount = false,
    String? memo,
  }) {
    return BaseLocation(
      id: id ?? this.id,
      name: name ?? this.name,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      floorLabel: floorLabel ?? this.floorLabel,
      floorNumber: clearFloorNumber ? null : floorNumber ?? this.floorNumber,
      entryFloorLabel: entryFloorLabel ?? this.entryFloorLabel,
      entryFloorNumber: clearEntryFloorNumber
          ? null
          : entryFloorNumber ?? this.entryFloorNumber,
      hasElevator: hasElevator ?? this.hasElevator,
      elevatorRideCount: clearElevatorRideCount
          ? null
          : elevatorRideCount ?? this.elevatorRideCount,
      memo: memo ?? this.memo,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'lat': lat,
      'lng': lng,
      'floorLabel': floorLabel,
      'floorNumber': floorNumber,
      'entryFloorLabel': entryFloorLabel,
      'entryFloorNumber': entryFloorNumber,
      'hasElevator': hasElevator,
      'elevatorRideCount': elevatorRideCount,
      'memo': memo,
    };
  }

  /// Tolerant decoder: never hard-casts, so a partially written or older base
  /// location cannot crash the app at startup.
  ///
  /// Coordinates are the exception. A missing or non-numeric `lat`/`lng` used
  /// to decode to (0, 0) off the coast of Africa, which every distance and
  /// score then silently computed against. Such an entry is corrupt, so this
  /// throws [FormatException] and the persistence layer drops it.
  factory BaseLocation.fromJson(Map<String, dynamic> json) {
    final lat = _asOptionalDouble(json['lat']);
    final lng = _asOptionalDouble(json['lng']);
    if (lat == null || lng == null) {
      throw const FormatException(
        'BaseLocation requires numeric lat and lng values.',
      );
    }
    return BaseLocation(
      id: _asString(json['id']),
      name: _asString(json['name']),
      lat: lat,
      lng: lng,
      floorLabel: _asString(json['floorLabel']),
      floorNumber: _asInt(json['floorNumber']),
      entryFloorLabel: _asString(json['entryFloorLabel']),
      entryFloorNumber: _asInt(json['entryFloorNumber']),
      hasElevator: _asBool(json['hasElevator'], true),
      elevatorRideCount: _asInt(json['elevatorRideCount']),
      memo: _asString(json['memo']),
    );
  }
}

String _asString(Object? value) => _asOptionalString(value) ?? '';

String? _asOptionalString(Object? value) {
  if (value == null) {
    return null;
  }
  return value is String ? value : '$value';
}

int? _asInt(Object? value) {
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? double.tryParse(value)?.toInt();
  }
  return null;
}

double? _asOptionalDouble(Object? value) {
  if (value is num) {
    final result = value.toDouble();
    return result.isFinite ? result : null;
  }
  if (value is String) {
    final parsed = double.tryParse(value.trim());
    return (parsed != null && parsed.isFinite) ? parsed : null;
  }
  return null;
}

bool _asBool(Object? value, bool fallback) {
  if (value is bool) {
    return value;
  }
  if (value is String) {
    if (value == 'true') return true;
    if (value == 'false') return false;
  }
  return fallback;
}
