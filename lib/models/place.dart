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

  factory Place.fromJson(Map<String, dynamic> json) {
    return Place(
      id: json['id'] as String,
      provider: json['provider'] as String,
      providerPlaceId: json['providerPlaceId'] as String,
      name: json['name'] as String,
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      address: (json['address'] as String?) ?? '',
      buildingName: (json['buildingName'] as String?) ?? '',
      floorLabel: (json['floorLabel'] as String?) ?? '',
      floorNumber: (json['floorNumber'] as num?)?.toInt(),
      entranceFloorLabel: (json['entranceFloorLabel'] as String?) ?? '',
      entranceFloorNumber: (json['entranceFloorNumber'] as num?)?.toInt(),
      hasElevator: (json['hasElevator'] as bool?) ?? true,
      elevatorRideCount: (json['elevatorRideCount'] as num?)?.toInt(),
      category: (json['category'] as String?) ?? '',
      rawPayload: (json['rawPayload'] as String?) ?? '',
    );
  }
}
