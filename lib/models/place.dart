class Place {
  const Place({
    required this.id,
    required this.provider,
    required this.providerPlaceId,
    required this.name,
    required this.lat,
    required this.lng,
    required this.address,
    this.buildingName = '',
    this.floorLabel = '',
    this.floorNumber,
    this.entranceFloorLabel = '',
    this.entranceFloorNumber,
    this.hasElevator = true,
    this.elevatorRideCount,
    this.category = '',
    this.rawPayload = '',
    this.isPlaceholder = false,
  });

  final String id;
  final String provider;
  final String providerPlaceId;
  final String name;
  final double lat;
  final double lng;
  final String address;
  final String buildingName;
  final String floorLabel;
  final int? floorNumber;
  final String entranceFloorLabel;
  final int? entranceFloorNumber;
  final bool hasElevator;
  final int? elevatorRideCount;
  final String category;
  final String rawPayload;

  /// True for a stand-in built from a snapshot that has no usable coordinates.
  ///
  /// Never serialised: such a place exists only so the record list stays
  /// readable, and it must never be written back as if it were real data.
  final bool isPlaceholder;

  Place copyWith({
    String? id,
    String? provider,
    String? providerPlaceId,
    String? name,
    double? lat,
    double? lng,
    String? address,
    String? buildingName,
    String? floorLabel,
    int? floorNumber,
    bool clearFloorNumber = false,
    String? entranceFloorLabel,
    int? entranceFloorNumber,
    bool clearEntranceFloorNumber = false,
    bool? hasElevator,
    int? elevatorRideCount,
    bool clearElevatorRideCount = false,
    String? category,
    String? rawPayload,
  }) {
    return Place(
      id: id ?? this.id,
      provider: provider ?? this.provider,
      providerPlaceId: providerPlaceId ?? this.providerPlaceId,
      name: name ?? this.name,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      address: address ?? this.address,
      buildingName: buildingName ?? this.buildingName,
      floorLabel: floorLabel ?? this.floorLabel,
      floorNumber: clearFloorNumber ? null : floorNumber ?? this.floorNumber,
      entranceFloorLabel: entranceFloorLabel ?? this.entranceFloorLabel,
      entranceFloorNumber: clearEntranceFloorNumber
          ? null
          : entranceFloorNumber ?? this.entranceFloorNumber,
      hasElevator: hasElevator ?? this.hasElevator,
      elevatorRideCount: clearElevatorRideCount
          ? null
          : elevatorRideCount ?? this.elevatorRideCount,
      category: category ?? this.category,
      rawPayload: rawPayload ?? this.rawPayload,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'provider': provider,
      'providerPlaceId': providerPlaceId,
      'name': name,
      'lat': lat,
      'lng': lng,
      'address': address,
      'buildingName': buildingName,
      'floorLabel': floorLabel,
      'floorNumber': floorNumber,
      'entranceFloorLabel': entranceFloorLabel,
      'entranceFloorNumber': entranceFloorNumber,
      'hasElevator': hasElevator,
      'elevatorRideCount': elevatorRideCount,
      'category': category,
      'rawPayload': rawPayload,
    };
  }

  /// Tolerant decoder: never hard-casts, so data written by an older build
  /// cannot crash the app while loading saved places.
  ///
  /// Coordinates are the one exception. A place without them cannot be placed
  /// on a map or measured against the base location, and silently substituting
  /// `0, 0` puts every such record in the Gulf of Guinea, thousands of
  /// kilometres away, which corrupts distances and scores. Such an entry is
  /// rejected so the caller can skip it.
  factory Place.fromJson(Map<String, dynamic> json) {
    final lat = _asOptionalDouble(json['lat']);
    final lng = _asOptionalDouble(json['lng']);
    if (lat == null || lng == null) {
      throw const FormatException('Place requires numeric lat and lng values.');
    }
    return Place(
      id: _asString(json['id']),
      provider: _asString(json['provider']),
      providerPlaceId: _asString(json['providerPlaceId']),
      name: _asString(json['name']),
      lat: lat,
      lng: lng,
      address: _asString(json['address']),
      buildingName: _asString(json['buildingName']),
      floorLabel: _asString(json['floorLabel']),
      floorNumber: _asInt(json['floorNumber']),
      entranceFloorLabel: _asString(json['entranceFloorLabel']),
      entranceFloorNumber: _asInt(json['entranceFloorNumber']),
      hasElevator: _asBool(json['hasElevator'], true),
      elevatorRideCount: _asInt(json['elevatorRideCount']),
      category: _asString(json['category']),
      rawPayload: _asString(json['rawPayload']),
    );
  }

  /// [fromJson] without the throw, for the display paths that would rather skip
  /// an unreadable snapshot than take down the whole list.
  static Place? tryFromJson(Map<String, dynamic> json) {
    try {
      return Place.fromJson(json);
    } on FormatException {
      return null;
    }
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
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value);
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
