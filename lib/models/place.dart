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
  factory Place.fromJson(Map<String, dynamic> json) {
    return Place(
      id: _asString(json['id']),
      provider: _asString(json['provider']),
      providerPlaceId: _asString(json['providerPlaceId']),
      name: _asString(json['name']),
      lat: _asDouble(json['lat'], 0),
      lng: _asDouble(json['lng'], 0),
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

double _asDouble(Object? value, double fallback) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value) ?? fallback;
  }
  return fallback;
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
