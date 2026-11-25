import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _MapLocation {
  final String id;
  final String name;
  final String subtitle;
  final double lng;
  final double lat;
  final String summary;
  final bool isCustom;
  final int builtYear;
  final int demolitionYear; // 9999 if still standing today
  final double heightMeters;
  final String eraBadge;
  final List<List<double>> footprintPolygon;

  const _MapLocation({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.lng,
    required this.lat,
    required this.summary,
    this.isCustom = false,
    this.builtYear = 1850,
    this.demolitionYear = 9999,
    this.heightMeters = 28.0,
    this.eraBadge = 'Neutral',
    this.footprintPolygon = const [],
  });
}

class _TurnStep {
  final String instruction;
  final double distanceMeters;
  final String maneuverType;
  final String? modifier;
  final double? lng;
  final double? lat;

  const _TurnStep({
    required this.instruction,
    required this.distanceMeters,
    required this.maneuverType,
    this.modifier,
    this.lng,
    this.lat,
  });

  String get formattedDistance {
    if (distanceMeters < 1000) {
      return '${distanceMeters.round()} m';
    }
    return '${(distanceMeters / 1000).toStringAsFixed(1)} km';
  }

  IconData get icon {
    if (maneuverType == 'arrive') return Icons.flag;
    if (maneuverType == 'depart') return Icons.navigation;
    final mod = modifier ?? '';
    if (mod.contains('left')) return Icons.turn_left;
    if (mod.contains('right')) return Icons.turn_right;
    if (mod.contains('uturn')) return Icons.u_turn_left;
    return Icons.straight;
  }
}

class _RouteSummary {
  final _MapLocation destination;
  final String profile;
  final double durationSeconds;
  final double distanceMeters;
  final List<_TurnStep> steps;
  final List<Position> geometryCoordinates;

  const _RouteSummary({
    required this.destination,
    required this.profile,
    required this.durationSeconds,
    required this.distanceMeters,
    required this.steps,
    required this.geometryCoordinates,
  });

  String get formattedDuration {
    final totalMinutes = (durationSeconds / 60).round();
    if (totalMinutes < 1) return '< 1 min';
    if (totalMinutes < 60) return '$totalMinutes min';
    final hours = totalMinutes ~/ 60;
    final mins = totalMinutes % 60;
    return mins == 0 ? '${hours}h' : '${hours}h ${mins}m';
  }

  String get formattedDistance {
    if (distanceMeters < 1000) {
      return '${distanceMeters.round()} m';
    }
    return '${(distanceMeters / 1000).toStringAsFixed(1)} km';
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
 // Dark Mode Palette
  static const Color _bgDark = Color(0xFF161925);
  static const Color _surfaceNavy = Color(0xFF23395B);
  static const Color _accentCyan = Color(0xFF38BDF8);
  static const Color _routeNeonCyan = Color(0xFF00E5FF);
  static const Color _terracottaHeritage = Color(0xFFD97736);
  static const Color _customPinAmber = Color(0xFFF59E0B);

  // Light Mode Palette (#FEFFFE + #E5FCF5)
  static const Color _bgLight = Color(0xFFFEFFFE);
  static const Color _surfaceMint = Color(0xFFE5FCF5);
  static const Color _accentTealLight = Color(0xFF0284C7);
  static const Color _routeTealLight = Color(0xFF0EA5E9);

  // Dynamic Theme Getters (Driven by _nightMapMode)
  Color get _themeBg => _nightMapMode ? _bgDark : _bgLight;
  Color get _themeSurface => _nightMapMode ? _surfaceNavy : _surfaceMint;
  Color get _themeAccent => _nightMapMode ? _accentCyan : _accentTealLight;
  Color get _themeRouteAccent =>
      _nightMapMode ? _routeNeonCyan : _routeTealLight;
  Color get _themeTextPrimary =>
      _nightMapMode ? Colors.white : const Color(0xFF0F172A);
  Color get _themeTextSecondary =>
      _nightMapMode ? Colors.white70 : const Color(0xFF475569);
  Color get _themeTextMuted =>
      _nightMapMode ? Colors.white54 : const Color(0xFF64748B);
  Color get _themeBorder => _nightMapMode
      ? Colors.white.withValues(alpha: 0.14)
      : const Color(0xFF0F172A).withValues(alpha: 0.12);

  static const String _mapboxPublicToken =
      String.fromEnvironment('MAPBOX_PUBLIC_TOKEN');

  static const List<_MapLocation> _lahoreHeritageSites = [
    _MapLocation(
      id: 'badshahi_mosque',
      name: 'Badshahi Mosque',
      subtitle: '1673 • Mughal Era',
      lng: 74.3108,
      lat: 31.5881,
      summary:
          'Commissioned by Emperor Aurangzeb; iconic red sandstone courtyard, three marble domes, and four corner minarets.',
      builtYear: 1800,
      demolitionYear: 9999,
      heightMeters: 54.0,
      eraBadge: 'Archival photos available',
      footprintPolygon: [
        [74.3102, 31.5876],
        [74.3114, 31.5876],
        [74.3114, 31.5886],
        [74.3102, 31.5886],
        [74.3102, 31.5876],
      ],
    ),
    _MapLocation(
      id: 'lahore_fort',
      name: 'Lahore Fort (Shahi Qila)',
      subtitle: '1566 • Mughal Citadel',
      lng: 74.3156,
      lat: 31.5880,
      summary:
          'Historic fortified citadel featuring Sheesh Mahal, Alamgiri Gate, and Naulakha Pavilion overlooking the Ravi.',
      builtYear: 1800,
      demolitionYear: 9999,
      heightMeters: 38.0,
      eraBadge: 'Archival photos available',
      footprintPolygon: [
        [74.3147, 31.5873],
        [74.3165, 31.5873],
        [74.3165, 31.5887],
        [74.3147, 31.5887],
        [74.3147, 31.5873],
      ],
    ),
    _MapLocation(
      id: 'tollinton_exhibition_hall',
      name: 'Old Exhibition Pavilion (1864)',
      subtitle: '1864 – 1920 • Reconstructed Ghost',
      lng: 74.3082,
      lat: 31.5689,
      summary:
          'Originally erected for the 1864 Punjab Exhibition on Mall Road; scrub between 1864 and 1920 to see the solid terracotta pavilion, or past 1920 to view its cyan ghost reconstruction.',
      builtYear: 1864,
      demolitionYear: 1920,
      heightMeters: 32.0,
      eraBadge: 'Reconstructed from archival plans',
      footprintPolygon: [
        [74.3077, 31.5685],
        [74.3087, 31.5685],
        [74.3087, 31.5693],
        [74.3077, 31.5693],
        [74.3077, 31.5685],
      ],
    ),
    _MapLocation(
      id: 'wazir_khan_mosque',
      name: 'Wazir Khan Mosque',
      subtitle: '1641 • Shah Jahan Era',
      lng: 74.3259,
      lat: 31.5831,
      summary:
          'Renowned for intricate kashi-kari faience tile work and Mughal frescoes inside Walled City Lahore.',
      builtYear: 1800,
      demolitionYear: 9999,
      heightMeters: 34.0,
      eraBadge: 'Neutral',
      footprintPolygon: [
        [74.3254, 31.5827],
        [74.3264, 31.5827],
        [74.3264, 31.5835],
        [74.3254, 31.5835],
        [74.3254, 31.5827],
      ],
    ),
  ];

  void _dismissSearchDropdown() {
  if (_searchResults.isNotEmpty || FocusScope.of(context).hasFocus) {
    FocusScope.of(context).unfocus();
    setState(() => _searchResults = []);
  }
}

  static final CameraOptions _initialCamera = CameraOptions(
    center: Point(coordinates: Position(74.3132, 31.5880)),
    zoom: 15.8,
    pitch: 60.0,
    bearing: -17.6,
  );

  MapboxMap? _mapboxMap;
  PointAnnotationManager? _pointAnnotationManager;

  final Map<String, _MapLocation> _annotationLocationMap = {};
  final List<_MapLocation> _customPins = [];
  final Set<String> _bookmarkedIds = {
    'badshahi_mosque',
    'lahore_fort',
    'tollinton_exhibition_hall',
  };

  _MapLocation? _temporarySearchPin;
  final TextEditingController _searchController = TextEditingController();
  final Dio _dio = Dio();

  List<dynamic> _searchResults = [];
  int _searchRequestId = 0;
  Timer? _searchDebounce;
  Position? _cachedUserPos;

  bool _isLocating = false;
  bool _isSearching = false;
  bool _isRouting = false;
  int _selectedNavIndex = 0;
  bool _nightMapMode = true;
  bool _is3DTilt = true;

  // Phase 2: Landmark Inspection Mode & Temporal Time-Travel State
  _MapLocation? _inspectedLocation;
  double _selectedYear = 2026.0;
  bool _ghostLayerEnabled = true;
  bool _isInspectionCardCollapsed = false;

  String _routeProfile = 'driving';
  _RouteSummary? _activeRoute;
  StreamSubscription<geo.Position>? _navPositionSub;
  bool _isNavigating = false;
  int _currentStepIndex = 0;
  double _remainingDistanceMeters = 0;

  List<_MapLocation> get _allLocations => [
        ..._lahoreHeritageSites,
        ..._customPins,
        if (_temporarySearchPin != null) _temporarySearchPin!,
      ];

  void _onMapCreated(MapboxMap mapboxMap) async {
    _mapboxMap = mapboxMap;

    await mapboxMap.gestures.updateSettings(
      GesturesSettings(
        pinchToZoomEnabled: true,
        rotateEnabled: true,
        pitchEnabled: true,
        scrollEnabled: true,
        doubleTapToZoomInEnabled: true,
        doubleTouchToZoomOutEnabled: true,
        quickZoomEnabled: true,
      ),
    );

    await mapboxMap.location.updateSettings(
      LocationComponentSettings(
        enabled: true,
        pulsingEnabled: true,
      ),
    );

    _pointAnnotationManager =
        await mapboxMap.annotations.createPointAnnotationManager();

    _pointAnnotationManager?.addOnPointAnnotationClickListener(
      _PinClickListener((annotation) {
        final location = _annotationLocationMap[annotation.id];
        if (location != null) {
          _enterLandmarkInspection(location);
        }
      }),
    );
  }

  Future<void> _applyMapLightPreset(bool nightMode) async {
    try {
      await _mapboxMap?.style.setStyleImportConfigProperty(
        'basemap',
        'lightPreset',
        nightMode ? 'night' : 'day',
      );
      await _syncAllPinsOnMap();
      await _syncTemporal3DExtrusions();
      if (_activeRoute != null) {
        await _setGlowingRouteGeoJson(_activeRoute!.geometryCoordinates);
      }
    } catch (_) {}
  }

  // Phase 2: 3-State 3D Extrusion Engine (Modern Ghost / Standing Heritage / Pre-Construction)
  Future<void> _syncTemporal3DExtrusions() async {
    final style = _mapboxMap?.style;
    if (style == null) return;

    const heritageSourceId = 'she_heritage_3d_source';
    const heritageLayerId = 'she_heritage_3d_layer';
    const ghostSourceId = 'she_ghost_3d_source';
    const ghostLayerId = 'she_ghost_3d_layer';

    for (final layerId in [ghostLayerId, heritageLayerId]) {
      if (await style.styleLayerExists(layerId)) {
        await style.removeStyleLayer(layerId);
      }
    }
    for (final sourceId in [ghostSourceId, heritageSourceId]) {
      if (await style.styleSourceExists(sourceId)) {
        await style.removeStyleSource(sourceId);
      }
    }

    // Only render 3D extrusion for the currently inspected landmark when Ghost/3D overlay is ON
    final loc = _inspectedLocation;
    if (loc == null || !_ghostLayerEnabled) return;

    final int year = _selectedYear.round();
    if (year < loc.builtYear) {
      // Pre-Construction Era: keep hidden
      return;
    }

    final polygon = loc.footprintPolygon.isNotEmpty
        ? loc.footprintPolygon
        : _buildDefaultFootprint(loc.lng, loc.lat);

    final featureCollection = jsonEncode({
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Polygon',
            'coordinates': [polygon],
          },
          'properties': {
            'height': loc.heightMeters,
            'base': 0.0,
          },
        },
      ],
    });

    if (year <= loc.demolitionYear) {
      // Standing Heritage Era: solid terracotta 3D extrusion
      await style.addSource(
        GeoJsonSource(id: heritageSourceId, data: featureCollection),
      );
      await style.addLayer(
        FillExtrusionLayer(
          id: heritageLayerId,
          sourceId: heritageSourceId,
          fillExtrusionColor: _terracottaHeritage.toARGB32(),
          fillExtrusionHeight: loc.heightMeters,
          fillExtrusionBase: 0.0,
          fillExtrusionOpacity: 0.90,
          fillExtrusionEmissiveStrength: 0.35,
        ),
      );
    } else {
      // Modern Era (year > demolitionYear): translucent cyan ghost wireframe
      await style.addSource(
        GeoJsonSource(id: ghostSourceId, data: featureCollection),
      );
      await style.addLayer(
        FillExtrusionLayer(
          id: ghostLayerId,
          sourceId: ghostSourceId,
          fillExtrusionColor: _routeNeonCyan.toARGB32(),
          fillExtrusionHeight: loc.heightMeters,
          fillExtrusionBase: 0.0,
          fillExtrusionOpacity: 0.38,
          fillExtrusionEmissiveStrength: 0.95,
        ),
      );
    }
  }

  List<List<double>> _buildDefaultFootprint(double lng, double lat) {
    const double d = 0.00035;
    return [
      [lng - d, lat - d],
      [lng + d, lat - d],
      [lng + d, lat + d],
      [lng - d, lat + d],
      [lng - d, lat - d],
    ];
  }

  String _getTemporalEraStateLabel(_MapLocation loc) {
    final int year = _selectedYear.round();
    if (year < loc.builtYear) {
      return 'Pre-Construction ($year • Built ${loc.builtYear})';
    }
    if (year <= loc.demolitionYear) {
      return 'Standing Heritage ($year • Solid 3D)';
    }
    return _ghostLayerEnabled
        ? 'Modern Era ($year • Cyan Ghost Active)'
        : 'Modern Era ($year • Ghost Hidden)';
  }

  Future<void> _enterLandmarkInspection(_MapLocation location) async {
    _searchDebounce?.cancel();
    _searchRequestId++;
    FocusScope.of(context).unfocus();
    _searchController.clear();

    await _setGlowingRouteGeoJson([]);
    setState(() {
      _selectedNavIndex = 0;
      _inspectedLocation = location;
      _isInspectionCardCollapsed = false;
      _activeRoute = null;
      _searchResults = [];
      _isSearching = false;
    });

    await _syncAllPinsOnMap();
    await _syncTemporal3DExtrusions();

    await _mapboxMap?.flyTo(
      CameraOptions(
        center: Point(coordinates: Position(location.lng, location.lat)),
        zoom: 17.2,
        pitch: 62.0,
      ),
      MapAnimationOptions(duration: 1200),
    );
  }

  Future<void> _exitLandmarkInspection() async {
    setState(() {
      _inspectedLocation = null;
    });
    await _syncAllPinsOnMap();
    await _syncTemporal3DExtrusions();
  }

  Future<void> _setGlowingRouteGeoJson(List<Position> coords) async {
    final style = _mapboxMap?.style;
    if (style == null) return;

    const sourceId = 'she_route_source';
    const casingLayerId = 'she_route_casing';
    const lineLayerId = 'she_route_line';

    for (final id in [lineLayerId, casingLayerId]) {
      if (await style.styleLayerExists(id)) {
        await style.removeStyleLayer(id);
      }
    }
    if (await style.styleSourceExists(sourceId)) {
      await style.removeStyleSource(sourceId);
    }

    if (coords.isEmpty) return;

    final geoJson = jsonEncode({
      'type': 'Feature',
      'geometry': {
        'type': 'LineString',
        'coordinates': coords.map((p) => [p.lng, p.lat]).toList(),
      },
    });

    await style.addSource(GeoJsonSource(id: sourceId, data: geoJson));

    await style.addLayer(
      LineLayer(
        id: casingLayerId,
        sourceId: sourceId,
        lineColor: 0xFFFFFFFF,
        lineWidth: 9.0,
        lineCap: LineCap.ROUND,
        lineJoin: LineJoin.ROUND,
        lineEmissiveStrength: 1.0,
      ),
    );

    await style.addLayer(
      LineLayer(
        id: lineLayerId,
        sourceId: sourceId,
        lineColor: 0xFF00E5FF,
        lineWidth: 5.5,
        lineCap: LineCap.ROUND,
        lineJoin: LineJoin.ROUND,
        lineEmissiveStrength: 1.0,
      ),
    );
  }

  Future<void> _syncAllPinsOnMap() async {
    final pointManager = _pointAnnotationManager;
    final style = _mapboxMap?.style;
    if (pointManager == null || style == null) return;

    await pointManager.deleteAll();
    _annotationLocationMap.clear();

    const pinSourceId = 'she_pins_source';
    const pinLayerId = 'she_pins_circles';

    if (await style.styleLayerExists(pinLayerId)) {
      await style.removeStyleLayer(pinLayerId);
    }
    if (await style.styleSourceExists(pinSourceId)) {
      await style.removeStyleSource(pinSourceId);
    }

    final features = [];

    for (final loc in _allLocations) {
      final bool isActiveDest = _activeRoute?.destination.id == loc.id ||
          _inspectedLocation?.id == loc.id ||
          _temporarySearchPin?.id == loc.id;

      features.add({
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [loc.lng, loc.lat],
        },
        'properties': {
          'isDest': isActiveDest,
        },
      });

      final annotation = await pointManager.create(
        PointAnnotationOptions(
          geometry: Point(coordinates: Position(loc.lng, loc.lat)),
          textField: isActiveDest ? '📍 ${loc.name}' : loc.name,
          textOffset: [0.0, -1.5],
          textSize: 12.5,
          textColor: _nightMapMode ? 0xFFFFFFFF : 0xFF0F172A,
          textHaloColor: _nightMapMode ? 0xFF161925 : 0xFFFEFFFE,
          textHaloWidth: 1.8,
        ),
      );
      _annotationLocationMap[annotation.id] = loc;
    }

    await style.addSource(
      GeoJsonSource(
        id: pinSourceId,
        data: jsonEncode({
          'type': 'FeatureCollection',
          'features': features,
        }),
      ),
    );

    await style.addLayer(
      CircleLayer(
        id: pinLayerId,
        sourceId: pinSourceId,
        circleColor: 0xFF00E5FF,
        circleRadius: 8.5,
        circleStrokeWidth: 2.5,
        circleStrokeColor: 0xFFFFFFFF,
        circleEmissiveStrength: 1.0,
      ),
    );
  }

  Future<Position?> _resolveUserCoordinates() async {
    try {
      final serviceEnabled = await geo.Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return null;

      var permission = await geo.Geolocator.checkPermission();
      if (permission == geo.LocationPermission.denied) {
        permission = await geo.Geolocator.requestPermission();
      }
      if (permission == geo.LocationPermission.denied ||
          permission == geo.LocationPermission.deniedForever) {
        return null;
      }

      final pos = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.high,
        ),
      );
      _cachedUserPos = Position(pos.longitude, pos.latitude);
      return _cachedUserPos;
    } catch (_) {
      return null;
    }
  }

  Future<void> _flyToUserLocation() async {
    setState(() => _isLocating = true);
    try {
      final userPos = await _resolveUserCoordinates();
      if (userPos == null) {
        _showSnack('Enable GPS permissions to center on your live location.');
        return;
      }

      await _mapboxMap?.flyTo(
        CameraOptions(
          center: Point(coordinates: userPos),
          zoom: 16.5,
          pitch: _is3DTilt ? 60.0 : 0.0,
        ),
        MapAnimationOptions(duration: 1400),
      );
    } finally {
      if (mounted) setState(() => _isLocating = false);
    }
  }

  Future<void> _buildRouteToLocation(
    _MapLocation destination, {
    String? overrideProfile,
  }) async {
    final profile = overrideProfile ?? _routeProfile;
    _searchDebounce?.cancel();
    _searchRequestId++;
    FocusScope.of(context).unfocus();
    _searchController.clear();

    setState(() {
      _isRouting = true;
      _routeProfile = profile;
      _selectedNavIndex = 0;
      _inspectedLocation = null;
      _searchResults = [];
      _isSearching = false;
    });

    try {
      Position? origin = await _resolveUserCoordinates();
      String? originNotice;

      if (origin == null) {
        origin = Position(74.3185, 31.5680);
        originNotice = 'Using central Lahore as origin (GPS unavailable).';
      } else {
        final double dLng = (origin.lng - destination.lng).abs();
        final double dLat = (origin.lat - destination.lat).abs();
        if (dLng > 1.5 || dLat > 1.5) {
          origin = Position(74.3185, 31.5680);
          originNotice =
              'Emulator GPS is outside Pakistan — routing from central Lahore.';
        }
      }

      final url =
          'https://api.mapbox.com/directions/v5/mapbox/$profile/${origin.lng},${origin.lat};${destination.lng},${destination.lat}';

      final response = await _dio.get(
        url,
        queryParameters: {
          'access_token': _mapboxPublicToken,
          'geometries': 'geojson',
          'overview': 'full',
          'steps': 'true',
          'radiuses': 'unlimited;unlimited',
        },
      );

      final routes = response.data['routes'] as List<dynamic>? ?? [];
      if (routes.isEmpty) {
        final code = response.data['code']?.toString() ?? 'NoRoute';
        _showSnack('No $profile route found ($code).');
        return;
      }

      final primaryRoute = routes.first as Map<String, dynamic>;
      final double durationSec = (primaryRoute['duration'] as num).toDouble();
      final double distanceM = (primaryRoute['distance'] as num).toDouble();
      final geometry = primaryRoute['geometry'] as Map<String, dynamic>;
      final rawCoords = geometry['coordinates'] as List<dynamic>;

      final List<_TurnStep> turnSteps = [];
      final legs = primaryRoute['legs'] as List<dynamic>? ?? [];
      for (final leg in legs) {
        final stepsList =
            (leg as Map<String, dynamic>)['steps'] as List<dynamic>? ?? [];
        for (final stepRaw in stepsList) {
          final stepMap = stepRaw as Map<String, dynamic>;
          final maneuver = stepMap['maneuver'] as Map<String, dynamic>? ?? {};
          final locList = maneuver['location'] as List<dynamic>?;
          turnSteps.add(
            _TurnStep(
              instruction: maneuver['instruction']?.toString() ?? 'Continue',
              distanceMeters: (stepMap['distance'] as num? ?? 0).toDouble(),
              maneuverType: maneuver['type']?.toString() ?? 'turn',
              modifier: maneuver['modifier']?.toString(),
              lng: locList != null && locList.length >= 2
                  ? (locList[0] as num).toDouble()
                  : null,
              lat: locList != null && locList.length >= 2
                  ? (locList[1] as num).toDouble()
                  : null,
            ),
          );
        }
      }

      final List<Position> routePositions = rawCoords
          .map(
            (c) => Position(
              ((c as List<dynamic>)[0] as num).toDouble(),
              (c[1] as num).toDouble(),
            ),
          )
          .toList();

      await _setGlowingRouteGeoJson(routePositions);

      final isKnownPin =
          _lahoreHeritageSites.any((s) => s.id == destination.id) ||
              _customPins.any((s) => s.id == destination.id);
      if (!isKnownPin) {
        _temporarySearchPin = destination;
      }

      if (!mounted) return;
      setState(() {
        _activeRoute = _RouteSummary(
          destination: destination,
          profile: profile,
          durationSeconds: durationSec,
          distanceMeters: distanceM,
          steps: turnSteps,
          geometryCoordinates: routePositions,
        );
      });

      await _syncAllPinsOnMap();

      final double midLng = (origin.lng + destination.lng) / 2;
      final double midLat = (origin.lat + destination.lat) / 2;
      final double span = math.max(
        (origin.lng - destination.lng).abs(),
        (origin.lat - destination.lat).abs(),
      );
      final double fitZoom = span > 0.08
          ? 12.2
          : span > 0.03
              ? 13.5
              : 14.8;

      await _mapboxMap?.flyTo(
        CameraOptions(
          center: Point(coordinates: Position(midLng, midLat)),
          zoom: fitZoom,
          pitch: _is3DTilt ? 50.0 : 0.0,
        ),
        MapAnimationOptions(duration: 1500),
      );

      if (originNotice != null) {
        _showSnack(originNotice);
      }
    } on DioException catch (e) {
      final apiMessage = e.response?.data is Map
          ? (e.response?.data['message']?.toString() ?? e.message)
          : e.message;
      _showSnack('Route error: $apiMessage');
    } catch (e) {
      _showSnack('Could not calculate route: $e');
    } finally {
      if (mounted) setState(() => _isRouting = false);
    }
  }

  Future<void> _clearActiveRoute() async {
    _stopLiveNavigation();
    await _setGlowingRouteGeoJson([]);
    if (mounted) {
      setState(() {
        _activeRoute = null;
        _temporarySearchPin = null;
      });
    }
    await _syncAllPinsOnMap();
  }

  Future<void> _startLiveNavigation(_RouteSummary route) async {
    final pos = await _resolveUserCoordinates();
    if (pos == null) {
      _showSnack('Enable GPS permissions to start live turn-by-turn navigation.');
      return;
    }

    setState(() {
      _isNavigating = true;
      _currentStepIndex = 0;
      _remainingDistanceMeters = route.distanceMeters;
    });

    await _mapboxMap?.flyTo(
      CameraOptions(
        center: Point(coordinates: pos),
        zoom: 17.5,
        pitch: 62.0,
      ),
      MapAnimationOptions(duration: 1000),
    );

    _navPositionSub?.cancel();
    _navPositionSub = geo.Geolocator.getPositionStream(
      locationSettings: const geo.LocationSettings(
        accuracy: geo.LocationAccuracy.bestForNavigation,
        distanceFilter: 8,
      ),
    ).listen((livePos) async {
      if (!mounted || !_isNavigating || _activeRoute == null) return;

      _cachedUserPos = Position(livePos.longitude, livePos.latitude);

      final distToDest = geo.Geolocator.distanceBetween(
        livePos.latitude,
        livePos.longitude,
        route.destination.lat,
        route.destination.lng,
      );

      if (distToDest < 25) {
        _stopLiveNavigation();
        _showSnack('You have arrived at ${route.destination.name}!');
        return;
      }

      setState(() {
        _remainingDistanceMeters = distToDest;
        if (_currentStepIndex + 1 < route.steps.length) {
          final nextStep = route.steps[_currentStepIndex + 1];
          if (nextStep.lat != null && nextStep.lng != null) {
            final distToNextTurn = geo.Geolocator.distanceBetween(
              livePos.latitude,
              livePos.longitude,
              nextStep.lat!,
              nextStep.lng!,
            );
            if (distToNextTurn < 25) {
              _currentStepIndex++;
            }
          }
        }
      });

      await _mapboxMap?.easeTo(
        CameraOptions(
          center: Point(
            coordinates: Position(livePos.longitude, livePos.latitude),
          ),
          zoom: 17.5,
          pitch: 62.0,
          bearing: livePos.heading,
        ),
        MapAnimationOptions(duration: 600),
      );
    });
  }

  void _stopLiveNavigation() {
    _navPositionSub?.cancel();
    _navPositionSub = null;
    if (mounted) {
      setState(() => _isNavigating = false);
    }
  }

  void _showTurnByTurnDirectionsSheet(_RouteSummary route) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _themeBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        minChildSize: 0.35,
        maxChildSize: 0.85,
        builder: (ctx, scrollController) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: _themeBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(
                    route.profile == 'walking'
                        ? Icons.directions_walk
                        : Icons.directions_car,
                    color: _themeRouteAccent,
                    size: 24,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Directions to ${route.destination.name}',
                          style: TextStyle(
                            color: _themeTextPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${route.formattedDuration} • ${route.formattedDistance} (${route.profile.toUpperCase()})',
                          style: TextStyle(
                            color: _themeRouteAccent,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Divider(height: 1, color: _themeBorder),
              const SizedBox(height: 8),
              Expanded(
                child: route.steps.isEmpty
                    ? Center(
                        child: Text(
                          'No turn-by-turn steps available for this route.',
                          style: TextStyle(color: _themeTextSecondary),
                        ),
                      )
                    : ListView.separated(
                        controller: scrollController,
                        itemCount: route.steps.length,
                        separatorBuilder: (_, __) => Divider(
                          height: 1,
                          color: _themeBorder,
                        ),
                        itemBuilder: (context, index) {
                          final step = route.steps[index];
                          return ListTile(
                            contentPadding:
                                const EdgeInsets.symmetric(vertical: 4),
                            leading: CircleAvatar(
                              backgroundColor: _themeSurface,
                              child: Icon(
                                step.icon,
                                color: _themeRouteAccent,
                                size: 20,
                              ),
                            ),
                            title: Text(
                              step.instruction,
                              style: TextStyle(
                                color: _themeTextPrimary,
                                fontSize: 14,
                              ),
                            ),
                            trailing: Text(
                              step.formattedDistance,
                              style: TextStyle(
                                color: _themeTextSecondary,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String> _getSearchProximity() async {
    if (_cachedUserPos != null) {
      return '${_cachedUserPos!.lng},${_cachedUserPos!.lat}';
    }
    try {
      final camera = await _mapboxMap?.getCameraState();
      final coords = camera?.center.coordinates;
      if (coords != null) {
        return '${coords.lng},${coords.lat}';
      }
    } catch (_) {}
    return '74.3132,31.5880';
  }

  void _searchPlaces(String query) {
    _searchDebounce?.cancel();
    final trimmed = query.trim();
    if (trimmed.length < 2) {
      _searchRequestId++;
      setState(() {
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }

    final lowerQuery = trimmed.toLowerCase();
    final localMatches = [
      ..._lahoreHeritageSites,
      ..._customPins,
    ]
        .where(
          (loc) =>
              loc.name.toLowerCase().contains(lowerQuery) ||
              loc.subtitle.toLowerCase().contains(lowerQuery),
        )
        .map(
          (loc) => <String, dynamic>{
            'text': loc.name,
            'place_name': loc.subtitle,
            'center': [loc.lng, loc.lat],
            '_localLocation': loc,
          },
        )
        .toList();

    setState(() {
      _searchResults = localMatches;
    });

    _searchDebounce = Timer(const Duration(milliseconds: 350), () async {
      final int requestId = ++_searchRequestId;
      if (mounted) setState(() => _isSearching = true);

      try {
        final proximity = await _getSearchProximity();
        final response = await _dio.get(
          'https://api.mapbox.com/search/searchbox/v1/forward',
          queryParameters: {
            'q': trimmed,
            'access_token': _mapboxPublicToken,
            'proximity': proximity,
            'limit': 6,
            'language': 'en',
          },
        );

        if (!mounted || requestId != _searchRequestId) return;

        final features = response.data['features'] as List<dynamic>? ?? [];
        final localNames = localMatches
            .map((m) => (m['text'] as String).toLowerCase())
            .toSet();

        final mappedRemote = [];
        for (final f in features) {
          final props = f['properties'] as Map<String, dynamic>? ?? {};
          final geom = f['geometry'] as Map<String, dynamic>? ?? {};
          final coords = geom['coordinates'] as List<dynamic>?;
          final name = props['name']?.toString() ?? '';
          if (coords == null || coords.length < 2 || name.isEmpty) continue;
          if (localNames.contains(name.toLowerCase())) continue;

          final fullAddress = props['full_address']?.toString() ??
              props['place_formatted']?.toString() ??
              '';

          mappedRemote.add({
            'text': name,
            'place_name': fullAddress,
            'center': [coords[0], coords[1]],
          });
        }

        setState(() {
          _searchResults = [...localMatches, ...mappedRemote];
        });
      } catch (_) {
      } finally {
        if (mounted && requestId == _searchRequestId) {
          setState(() => _isSearching = false);
        }
      }
    });
  }

  Future<void> _selectPlace(dynamic feature) async {
    FocusScope.of(context).unfocus();

    if (feature is Map<String, dynamic> && feature['_localLocation'] != null) {
      final localLoc = feature['_localLocation'] as _MapLocation;
      _searchController.text = localLoc.name;
      await _enterLandmarkInspection(localLoc);
      return;
    }

    final coords = feature['center'] as List<dynamic>;
    final double lng = (coords[0] as num).toDouble();
    final double lat = (coords[1] as num).toDouble();
    final String name = feature['text']?.toString() ?? 'Selected Place';
    final String fullPlace = feature['place_name']?.toString() ?? '';

    _searchController.text = name;

    final searchedLocation = _MapLocation(
      id: 'search_${lng}_$lat',
      name: name,
      subtitle: 'Search Destination • Lahore',
      lng: lng,
      lat: lat,
      summary: fullPlace.isEmpty
          ? 'Selected destination on the Spatial Heritage Explorer 3D map.'
          : fullPlace,
      builtYear: 1900,
      demolitionYear: 9999,
      eraBadge: 'Neutral',
    );

    setState(() {
      _temporarySearchPin = searchedLocation;
    });

    await _enterLandmarkInspection(searchedLocation);
  }

  Future<void> _toggle3DTilt() async {
    final nextTilt = !_is3DTilt;
    setState(() => _is3DTilt = nextTilt);
    await _mapboxMap?.flyTo(
      CameraOptions(pitch: nextTilt ? 60.0 : 0.0),
      MapAnimationOptions(duration: 700),
    );
  }

  Future<void> _resetNorthBearing() async {
    await _mapboxMap?.flyTo(
      CameraOptions(bearing: 0.0),
      MapAnimationOptions(duration: 600),
    );
  }

  void _openProfileSheet() {
    User? currentUser;
    try {
      currentUser = Supabase.instance.client.auth.currentUser;
    } catch (_) {
      currentUser = null;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: _themeBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: _themeBorder,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            CircleAvatar(
              radius: 28,
              backgroundColor: _themeSurface,
              child: Icon(Icons.person, color: _themeAccent, size: 30),
            ),
            const SizedBox(height: 12),
            Text(
              currentUser?.email ?? 'Explorer Guest',
              style: TextStyle(
                color: _themeTextPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Spatial Heritage Explorer • Tap any pin for Time-Travel Inspection',
              style: TextStyle(color: _themeTextSecondary, fontSize: 12),
            ),
            const SizedBox(height: 24),
            if (currentUser != null)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _themeSurface,
                    foregroundColor: Colors.redAccent,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await Supabase.instance.client.auth.signOut();
                  },
                  icon: const Icon(Icons.logout),
                  label: const Text('Sign Out'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: _surfaceNavy,
        content: Text(message, style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  @override
  void dispose() {
    _navPositionSub?.cancel();
    _searchDebounce?.cancel();
    _dio.close(force: true);
    _pointAnnotationManager?.deleteAll();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inspected = _inspectedLocation;

    return Scaffold(
      backgroundColor: _themeBg,
      body: Stack(
        children: [
          // 1. Full-screen 3D Mapbox Map
          MapWidget(
            key: const ValueKey('she_3d_map'),
            styleUri: MapboxStyles.STANDARD,
            cameraOptions: _initialCamera,
            onMapCreated: _onMapCreated,
            onTapListener: (_) => _dismissSearchDropdown(),
            onStyleLoadedListener: (_) async {
              await _applyMapLightPreset(_nightMapMode);
            },
          ),

          // 2. Saved or Settings Overlays
          if (_selectedNavIndex == 1 && inspected == null) _buildSavedOverlay(),
          if (_selectedNavIndex == 2 && inspected == null)
            _buildSettingsOverlay(),

          // 3. Top Bar: Live Navigation Banner OR Inspection Header OR Map Search Pill
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: (_isNavigating && _activeRoute != null)
                  ? _buildLiveTurnBanner(_activeRoute!)
                  : inspected != null
                      ? _buildInspectionTopBar(inspected)
                      : (_selectedNavIndex == 0
                          ? _buildSearchTopBar()
                          : const SizedBox.shrink()),
            ),
          ),

          // 4. Right-Side Quick Map Controls (3D/2D Tilt & Reset North)
          if (_selectedNavIndex == 0 && inspected == null)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              right: 16,
              top: (_isNavigating && _activeRoute != null) ? 165 : 125,
              child: Column(
                children: [
                  _buildMapControlButton(
                    tooltip:
                        _is3DTilt ? 'Switch to 2D Top View' : 'Switch to 3D Tilt',
                    onTap: _toggle3DTilt,
                    child: Text(
                      _is3DTilt ? '3D' : '2D',
                      style: TextStyle(
                        color: _themeAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _buildMapControlButton(
                    tooltip: 'Reset Compass North',
                    onTap: _resetNorthBearing,
                    child: Icon(
                      Icons.explore_outlined,
                      color: _themeTextPrimary,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),

          // 5. Bottom Stack: Inspection Card + Temporal Scrubber OR Standard Dock
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: inspected != null
                  ? _buildLandmarkInspectionBottomStack(inspected)
                  : _buildStandardBottomStack(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveTurnBanner(_RouteSummary route) {
    final step = route.steps.isNotEmpty
        ? route.steps[_currentStepIndex.clamp(0, route.steps.length - 1)]
        : null;

    return GestureDetector(
      onTap: () => _showTurnByTurnDirectionsSheet(route),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: _themeSurface.withValues(alpha: 0.97),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: _themeRouteAccent, width: 1.5),
          boxShadow: const [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 14,
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: _themeRouteAccent.withValues(alpha: 0.18),
              child: Icon(
                step?.icon ?? Icons.navigation,
                color: _themeRouteAccent,
                size: 24,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    step?.instruction ?? 'Head toward ${route.destination.name}',
                    style: TextStyle(
                      color: _themeTextPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    step != null
                        ? 'Next step • ${step.formattedDistance} • Tap for all steps'
                        : 'Following live route • Tap for all steps',
                    style: TextStyle(
                      color: _themeRouteAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.keyboard_arrow_down,
              color: _themeTextSecondary,
              size: 22,
            ),
          ],
        ),
      ),
    );
  }

  // Phase 2: Landmark Inspection Top Bar (`← [Site Name, Lahore]` + `Share`)
  Widget _buildInspectionTopBar(_MapLocation location) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: _themeSurface.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: _terracottaHeritage.withValues(alpha: 0.65)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back to Explore Map',
            onPressed: _exitLandmarkInspection,
            icon: Icon(Icons.arrow_back, color: _themeTextPrimary),
          ),
          Expanded(
            child: Text(
              '${location.name}, Lahore',
              style: TextStyle(
                color: _themeTextPrimary,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: 'Share Landmark Snapshot',
            onPressed: () async {
              final shareText =
                  '${location.name}, Lahore (${_selectedYear.round()}) — ${location.summary}';
              await Clipboard.setData(ClipboardData(text: shareText));
              _showSnack('Copied landmark details to clipboard');
            },
            icon: Icon(Icons.share_outlined, color: _themeAccent, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchTopBar() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: _themeSurface.withValues(alpha: 0.94),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(
                    color: _themeAccent.withValues(alpha: 0.35),
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 12,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: TextField(
                  controller: _searchController,
                  onChanged: _searchPlaces,
                  style: TextStyle(color: _themeTextPrimary, fontSize: 15),
                  cursorColor: _themeAccent,
                  decoration: InputDecoration(
                    hintText: 'Search heritage site or landmark...',
                    hintStyle: TextStyle(
                      color: _themeTextMuted,
                      fontSize: 13.5,
                    ),
                    prefixIcon: Icon(Icons.search, color: _themeAccent),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_isSearching)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: _themeAccent,
                              ),
                            ),
                          )
                        else if (_searchController.text.isNotEmpty)
                          IconButton(
                            icon: Icon(
                              Icons.clear,
                              color: _themeTextSecondary,
                              size: 20,
                            ),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchResults = []);
                            },
                          ),
                        IconButton(
                          tooltip: 'Center on my GPS location',
                          onPressed: _isLocating ? null : _flyToUserLocation,
                          icon: _isLocating
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: _themeAccent,
                                  ),
                                )
                              : Icon(
                                  Icons.my_location,
                                  color: _themeAccent,
                                  size: 20,
                                ),
                        ),
                      ],
                    ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: _openProfileSheet,
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: _themeSurface.withValues(alpha: 0.94),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _themeAccent.withValues(alpha: 0.35),
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 10,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: Icon(Icons.person_outline, color: _themeTextPrimary),
              ),
            ),
          ],
        ),
        if (_searchResults.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 8),
            decoration: BoxDecoration(
              color: _themeSurface.withValues(alpha: 0.97),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: _themeBorder),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 14,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: _searchResults.length,
              separatorBuilder: (_, __) => Divider(
                height: 1,
                color: _themeBorder,
              ),
              itemBuilder: (context, index) {
                final place = _searchResults[index];
                return ListTile(
                  leading: Icon(
                    Icons.location_on_outlined,
                    color: _themeAccent,
                  ),
                  title: Text(
                    place['text']?.toString() ?? 'Unknown',
                    style: TextStyle(
                      color: _themeTextPrimary,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    place['place_name']?.toString() ?? '',
                    style: TextStyle(color: _themeTextSecondary, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => _selectPlace(place),
                );
              },
            ),
          ),
      ],
    );
  }

  // Phase 2: Floating #23395B Historical Description & Archival Preview Card + Temporal Scrubber Dock
  Widget _buildLandmarkInspectionBottomStack(_MapLocation location) {
    final isBookmarked = _bookmarkedIds.contains(location.id);
    final int year = _selectedYear.round();
    final Color badgeColor = location.eraBadge.contains('Reconstructed')
        ? _themeRouteAccent
        : location.eraBadge.contains('Archival')
            ? _terracottaHeritage
            : _themeTextSecondary;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_isInspectionCardCollapsed)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: _themeSurface.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: _terracottaHeritage.withValues(alpha: 0.55),
              ),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 10,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: () =>
                      setState(() => _isInspectionCardCollapsed = false),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.expand_less,
                        color: _themeRouteAccent,
                        size: 20,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _getTemporalEraStateLabel(location),
                        style: TextStyle(
                          color: _themeTextPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: () => _buildRouteToLocation(location),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: _themeRouteAccent,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.directions,
                          color: _nightMapMode ? _bgDark : Colors.white,
                          size: 14,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Route',
                          style: TextStyle(
                            color: _nightMapMode ? _bgDark : Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _themeSurface.withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: _terracottaHeritage.withValues(alpha: 0.55),
              ),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 16,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: badgeColor.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Text(
                        location.eraBadge,
                        style: TextStyle(
                          color: badgeColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      constraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
                      padding: EdgeInsets.zero,
                      tooltip:
                          isBookmarked ? 'Remove Bookmark' : 'Save Bookmark',
                      onPressed: () {
                        setState(() {
                          if (isBookmarked) {
                            _bookmarkedIds.remove(location.id);
                          } else {
                            _bookmarkedIds.add(location.id);
                          }
                        });
                      },
                      icon: Icon(
                        isBookmarked ? Icons.bookmark : Icons.bookmark_border,
                        color: _themeAccent,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      constraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
                      padding: EdgeInsets.zero,
                      tooltip: 'Minimize card to view 3D building',
                      onPressed: () =>
                          setState(() => _isInspectionCardCollapsed = true),
                      icon: Icon(
                        Icons.expand_more,
                        color: _themeTextSecondary,
                        size: 22,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: _themeBg.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _themeAccent.withValues(alpha: 0.25),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.architecture_outlined,
                        color: _themeRouteAccent,
                        size: 26,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _getTemporalEraStateLabel(location),
                              style: TextStyle(
                                color: _themeRouteAccent,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Archival photo plate pending • 3D massing active',
                              style: TextStyle(
                                color: _themeTextSecondary,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  location.summary,
                  style: TextStyle(
                    color: _themeTextPrimary,
                    fontSize: 13,
                    height: 1.38,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _themeRouteAccent,
                      foregroundColor: _nightMapMode ? _bgDark : Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: () => _buildRouteToLocation(location),
                    icon: const Icon(Icons.directions, size: 18),
                    label: const Text(
                      'Directions & ETA',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

        // Temporal Scrubber Dock (1800 – 2026) + Ghost Layer Toggle Pill
        Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          decoration: BoxDecoration(
            color: _themeBg.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: _themeAccent.withValues(alpha: 0.4),
            ),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 16,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.history,
                    color: _terracottaHeritage,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Era: $year CE',
                    style: TextStyle(
                      color: _themeTextPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () async {
                      setState(() => _ghostLayerEnabled = !_ghostLayerEnabled);
                      await _syncTemporal3DExtrusions();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: _ghostLayerEnabled
                            ? _themeRouteAccent.withValues(alpha: 0.18)
                            : _themeSurface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: _ghostLayerEnabled
                              ? _themeRouteAccent
                              : _themeBorder,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _ghostLayerEnabled
                                ? Icons.layers
                                : Icons.layers_clear,
                            size: 14,
                            color: _ghostLayerEnabled
                                ? _themeRouteAccent
                                : _themeTextMuted,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            _ghostLayerEnabled
                                ? 'Ghost layer: ON'
                                : 'Ghost layer: OFF',
                            style: TextStyle(
                              color: _ghostLayerEnabled
                                  ? _themeRouteAccent
                                  : _themeTextMuted,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: _terracottaHeritage,
                  inactiveTrackColor: _themeSurface,
                  thumbColor: _themeRouteAccent,
                  overlayColor: _themeRouteAccent.withValues(alpha: 0.2),
                  trackHeight: 4,
                ),
                child: Slider(
                  min: 1800,
                  max: 2026,
                  divisions: 226,
                  value: _selectedYear,
                  onChanged: (val) {
                    setState(() => _selectedYear = val);
                  },
                  onChangeEnd: (_) async {
                    await _syncTemporal3DExtrusions();
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '1800',
                      style: TextStyle(color: _themeTextMuted, fontSize: 11),
                    ),
                    Text(
                      '1900',
                      style: TextStyle(color: _themeTextMuted, fontSize: 11),
                    ),
                    Text(
                      '2026',
                      style: TextStyle(color: _themeTextMuted, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStandardBottomStack() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_isRouting)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: _themeSurface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: _themeRouteAccent.withValues(alpha: 0.4),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: _themeRouteAccent,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'Calculating 3D route & ETA...',
                  style: TextStyle(color: _themeTextPrimary, fontSize: 13),
                ),
              ],
            ),
          ),
        if (_activeRoute != null && _selectedNavIndex == 0)
          _buildActiveRouteCard(_activeRoute!),
        Container(
          margin: const EdgeInsets.fromLTRB(32, 0, 32, 16),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _themeSurface.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(32),
            border: Border.all(color: _themeBorder),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 16,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildDockItem(
                index: 0,
                icon: Icons.map_outlined,
                activeIcon: Icons.map,
                label: 'Map',
              ),
              _buildDockItem(
                index: 1,
                icon: Icons.bookmark_border,
                activeIcon: Icons.bookmark,
                label: 'Saved',
              ),
              _buildDockItem(
                index: 2,
                icon: Icons.settings_outlined,
                activeIcon: Icons.settings,
                label: 'Settings',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMapControlButton({
    required String tooltip,
    required VoidCallback onTap,
    required Widget child,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _themeSurface.withValues(alpha: 0.94),
            shape: BoxShape.circle,
            border: Border.all(
              color: _themeAccent.withValues(alpha: 0.35),
            ),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 8,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _buildActiveRouteCard(_RouteSummary route) {
    final double speedMps = route.profile == 'walking' ? 1.4 : 11.0;
    final int liveMinutes =
        ((_remainingDistanceMeters / speedMps) / 60).ceil().clamp(1, 999);
    final String liveDistance = _remainingDistanceMeters < 1000
        ? '${_remainingDistanceMeters.round()} m'
        : '${(_remainingDistanceMeters / 1000).toStringAsFixed(1)} km';

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 12),
      decoration: BoxDecoration(
        color: _themeBg.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _themeRouteAccent.withValues(alpha: 0.65)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 14,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _enterLandmarkInspection(route.destination),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: _themeSurface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _terracottaHeritage.withValues(alpha: 0.55),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.arrow_back,
                        size: 15,
                        color: _themeTextPrimary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '3D View',
                        style: TextStyle(
                          color: _themeTextPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  route.destination.name,
                  style: TextStyle(
                    color: _themeTextPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: EdgeInsets.zero,
                tooltip: 'Clear Route',
                icon: Icon(Icons.close, color: _themeTextSecondary, size: 19),
                onPressed: _clearActiveRoute,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(
                    children: [
                      Text(
                        _isNavigating
                            ? '$liveMinutes min'
                            : route.formattedDuration,
                        style: TextStyle(
                          color: _themeRouteAccent,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        _isNavigating
                            ? '  •  $liveDistance left'
                            : '  •  ${route.formattedDistance}',
                        style: TextStyle(
                          color: _themeTextSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // Start / End Trip Button
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      _isNavigating ? Colors.redAccent : _themeRouteAccent,
                  foregroundColor: _nightMapMode ? _bgDark : Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () {
                  if (_isNavigating) {
                    _stopLiveNavigation();
                  } else {
                    _startLiveNavigation(route);
                  }
                },
                icon: Icon(
                  _isNavigating ? Icons.stop_circle_outlined : Icons.navigation,
                  size: 16,
                ),
                label: Text(
                  _isNavigating ? 'End' : 'Start',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (!_isNavigating) ...[
                const SizedBox(width: 8),
                Container(
                  decoration: BoxDecoration(
                    color: _themeSurface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        constraints:
                            const BoxConstraints(minWidth: 34, minHeight: 34),
                        padding: EdgeInsets.zero,
                        tooltip: 'Driving ETA',
                        icon: Icon(
                          Icons.directions_car,
                          size: 17,
                          color: route.profile == 'driving'
                              ? _themeRouteAccent
                              : _themeTextMuted,
                        ),
                        onPressed: () => _buildRouteToLocation(
                          route.destination,
                          overrideProfile: 'driving',
                        ),
                      ),
                      IconButton(
                        constraints:
                            const BoxConstraints(minWidth: 34, minHeight: 34),
                        padding: EdgeInsets.zero,
                        tooltip: 'Walking ETA',
                        icon: Icon(
                          Icons.directions_walk,
                          size: 17,
                          color: route.profile == 'walking'
                              ? _themeRouteAccent
                              : _themeTextMuted,
                        ),
                        onPressed: () => _buildRouteToLocation(
                          route.destination,
                          overrideProfile: 'walking',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDockItem({
    required int index,
    required IconData icon,
    required IconData activeIcon,
    required String label,
  }) {
    final bool isSelected = _selectedNavIndex == index;
    return GestureDetector(
      onTap: () {
        _dismissSearchDropdown();
        setState(() => _selectedNavIndex = index);
      },
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? _themeAccent.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isSelected ? activeIcon : icon,
              color: isSelected ? _themeAccent : _themeTextSecondary,
              size: 22,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? _themeAccent : _themeTextSecondary,
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSavedOverlay() {
    final savedLocations = [
      ..._lahoreHeritageSites,
      ..._customPins,
    ].where((loc) => _bookmarkedIds.contains(loc.id) || loc.isCustom).toList();

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _dismissSearchDropdown,
      child: Container(
        color: _themeBg.withValues(alpha: 0.96),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 104),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Saved Landmarks',
                  style: TextStyle(
                    color: _themeTextPrimary,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Tap a landmark to inspect in 3D or route there.',
                  style: TextStyle(
                    color: _themeTextSecondary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 18),
                Expanded(
                  child: savedLocations.isEmpty
                      ? Center(
                          child: Text(
                            'No saved landmarks yet.',
                            style: TextStyle(
                              color: _themeTextSecondary,
                              fontSize: 14,
                            ),
                          ),
                        )
                      : ListView.separated(
                          itemCount: savedLocations.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            final site = savedLocations[index];
                            final accent =
                                site.isCustom ? _customPinAmber : _themeAccent;

                            return Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: () => _enterLandmarkInspection(site),
                                borderRadius: BorderRadius.circular(20),
                                child: Ink(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: _themeSurface,
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: _themeBorder,
                                    ),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      Container(
                                        width: 44,
                                        height: 44,
                                        decoration: BoxDecoration(
                                          color: _themeBg,
                                          borderRadius:
                                              BorderRadius.circular(14),
                                          border: Border.all(
                                            color: accent.withValues(
                                              alpha: 0.3,
                                            ),
                                          ),
                                        ),
                                        child: Icon(
                                          site.isCustom
                                              ? Icons.push_pin
                                              : Icons.account_balance,
                                          color: accent,
                                          size: 21,
                                        ),
                                      ),
                                      const SizedBox(width: 14),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              site.name,
                                              style: TextStyle(
                                                color: _themeTextPrimary,
                                                fontSize: 15.5,
                                                fontWeight: FontWeight.w700,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(height: 5),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 8,
                                                vertical: 2,
                                              ),
                                              decoration: BoxDecoration(
                                                color: accent.withValues(
                                                  alpha: 0.14,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                              ),
                                              child: Text(
                                                site.subtitle,
                                                style: TextStyle(
                                                  color: accent,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              site.summary,
                                              style: TextStyle(
                                                color: _themeTextSecondary,
                                                fontSize: 12,
                                                height: 1.35,
                                              ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      IconButton(
                                        tooltip: 'Get Directions',
                                        style: IconButton.styleFrom(
                                          backgroundColor: _themeRouteAccent
                                              .withValues(alpha: 0.14),
                                        ),
                                        icon: Icon(
                                          Icons.directions,
                                          color: _themeRouteAccent,
                                          size: 20,
                                        ),
                                        onPressed: () =>
                                            _buildRouteToLocation(site),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  Widget _buildSettingsOverlay() {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _dismissSearchDropdown,
      child: Container(
        color: _themeBg.withValues(alpha: 0.96),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 104),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Map & Display Settings',
                  style: TextStyle(
                    color: _themeTextPrimary,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Customize map lighting, 3D tilt, and historical overlays.',
                  style: TextStyle(
                    color: _themeTextSecondary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 18),
                Container(
                  decoration: BoxDecoration(
                    color: _themeSurface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _themeBorder),
                  ),
                  child: Column(
                    children: [
                      SwitchListTile(
                        title: Text(
                          'Night 3D Map Lighting',
                          style: TextStyle(
                            color: _themeTextPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          'Toggle between Dark Slate (#161925) and Light Mint (#FEFFFE)',
                          style: TextStyle(
                            color: _themeTextSecondary,
                            fontSize: 12,
                          ),
                        ),
                        activeThumbColor: _themeAccent,
                        value: _nightMapMode,
                        onChanged: (val) async {
                          setState(() => _nightMapMode = val);
                          await _applyMapLightPreset(val);
                        },
                      ),
                      Divider(height: 1, color: _themeBorder),
                      SwitchListTile(
                        title: Text(
                          '60° 3D Building Perspective',
                          style: TextStyle(
                            color: _themeTextPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          'Toggle between pitched 3D view and 2D overhead map',
                          style: TextStyle(
                            color: _themeTextSecondary,
                            fontSize: 12,
                          ),
                        ),
                        activeThumbColor: _themeAccent,
                        value: _is3DTilt,
                        onChanged: (val) async {
                          setState(() => _is3DTilt = val);
                          await _mapboxMap?.flyTo(
                            CameraOptions(pitch: val ? 60.0 : 0.0),
                            MapAnimationOptions(duration: 700),
                          );
                        },
                      ),
                      Divider(height: 1, color: _themeBorder),
                      SwitchListTile(
                        title: Text(
                          '3D Ghost Wireframe Layer',
                          style: TextStyle(
                            color: _themeTextPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          'Show translucent cyan massing for demolished sites',
                          style: TextStyle(
                            color: _themeTextSecondary,
                            fontSize: 12,
                          ),
                        ),
                        activeThumbColor: _themeRouteAccent,
                        value: _ghostLayerEnabled,
                        onChanged: (val) async {
                          setState(() => _ghostLayerEnabled = val);
                          await _syncTemporal3DExtrusions();
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PinClickListener extends OnPointAnnotationClickListener {
  final void Function(PointAnnotation) onClicked;

  _PinClickListener(this.onClicked);

  @override
  void onPointAnnotationClick(PointAnnotation annotation) {
    onClicked(annotation);
  }
}