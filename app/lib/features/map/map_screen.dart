import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _HeritageSite {
  final String name;
  final String era;
  final double lng;
  final double lat;
  final String summary;

  const _HeritageSite({
    required this.name,
    required this.era,
    required this.lng,
    required this.lat,
    required this.summary,
  });
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  // Phase 1 Color Palette (#161925 Deep Background & #23395B Elevated Surface)
  static const Color _bgDark = Color(0xFF161925);
  static const Color _surfaceNavy = Color(0xFF23395B);
  static const Color _accentCyan = Color(0xFF38BDF8);

  static const String _mapboxPublicToken =
      String.fromEnvironment('MAPBOX_PUBLIC_TOKEN');

  static const List<_HeritageSite> _lahoreSites = [
    _HeritageSite(
      name: 'Badshahi Mosque',
      era: '1673 • Mughal Era',
      lng: 74.3108,
      lat: 31.5881,
      summary: 'Commissioned by Emperor Aurangzeb; iconic red sandstone courtyard and marble domes.',
    ),
    _HeritageSite(
      name: 'Lahore Fort (Shahi Qila)',
      era: '1566 • Mughal Citadel',
      lng: 74.3156,
      lat: 31.5880,
      summary: 'Historic fortified citadel featuring Sheesh Mahal, Alamgiri Gate, and Naulakha Pavilion.',
    ),
    _HeritageSite(
      name: 'Wazir Khan Mosque',
      era: '1641 • Shah Jahan Era',
      lng: 74.3259,
      lat: 31.5831,
      summary: 'Renowned for intricate kashi-kari tile work and frescoes inside Walled City Lahore.',
    ),
    _HeritageSite(
      name: 'Shalimar Gardens',
      era: '1641 • UNESCO Heritage',
      lng: 74.3818,
      lat: 31.5859,
      summary: 'Three-tiered Persian-style Mughal garden complex with marble pavilions and fountains.',
    ),
  ];

  // Default camera: Badshahi Mosque & Lahore Fort (60-degree pitch for 3D buildings)
  static final CameraOptions _initialCamera = CameraOptions(
    center: Point(coordinates: Position(74.3132, 31.5880)),
    zoom: 15.8,
    pitch: 60.0,
    bearing: -17.6,
  );

  MapboxMap? _mapboxMap;
  PointAnnotationManager? _pointAnnotationManager;
  final Map<String, _HeritageSite> _annotationSiteMap = {};
  final TextEditingController _searchController = TextEditingController();
  final Dio _dio = Dio();

  List<dynamic> _searchResults = [];
  bool _isLocating = false;
  bool _isSearching = false;
  int _selectedNavIndex = 0; // 0 = Map, 1 = Saved, 2 = Settings
  bool _nightMapMode = true;

  void _onMapCreated(MapboxMap mapboxMap) async {
    _mapboxMap = mapboxMap;

    // Enable dark 3D building lighting preset on Mapbox Standard
    await _applyMapLightPreset(_nightMapMode);

    // Enable native pulsing location puck
    await mapboxMap.location.updateSettings(
      LocationComponentSettings(
        enabled: true,
        pulsingEnabled: true,
      ),
    );

    // Add glowing heritage pins for Lahore landmarks
    await _setupHeritagePins(mapboxMap);
  }

  Future<void> _applyMapLightPreset(bool nightMode) async {
    try {
      await _mapboxMap?.style.setStyleImportConfigProperty(
        'basemap',
        'lightPreset',
        nightMode ? 'night' : 'day',
      );
    } catch (_) {
      // Fallback if style import is still initializing
    }
  }

  Future<void> _setupHeritagePins(MapboxMap mapboxMap) async {
    final manager = await mapboxMap.annotations.createPointAnnotationManager();
    _pointAnnotationManager = manager;
    _annotationSiteMap.clear();

    for (final site in _lahoreSites) {
      final annotation = await manager.create(
        PointAnnotationOptions(
          geometry: Point(coordinates: Position(site.lng, site.lat)),
          textField: site.name,
          textOffset: [0.0, 1.4],
          textSize: 12.0,
          textColor: _accentCyan.toARGB32(),
          textHaloColor: _bgDark.toARGB32(),
          textHaloWidth: 1.5,
          iconColor: _accentCyan.toARGB32(),
        ),
      );
      _annotationSiteMap[annotation.id] = site;
    }

    manager.addOnPointAnnotationClickListener(
      _HeritagePinClickListener((annotation) {
        final site = _annotationSiteMap[annotation.id];
        if (site != null) {
          _flyToHeritageSite(site);
        }
      }),
    );
  }

  Future<void> _flyToHeritageSite(_HeritageSite site) async {
    setState(() => _selectedNavIndex = 0);
    await _mapboxMap?.flyTo(
      CameraOptions(
        center: Point(coordinates: Position(site.lng, site.lat)),
        zoom: 17.0,
        pitch: 62.0,
        bearing: 15.0,
      ),
      MapAnimationOptions(duration: 1400),
    );
    _showSnack('${site.name} (${site.era})');
  }

  Future<void> _flyToUserLocation() async {
    setState(() => _isLocating = true);
    try {
      bool serviceEnabled = await geo.Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _showSnack('Enable GPS / Location services on your device.');
        return;
      }

      geo.LocationPermission permission =
          await geo.Geolocator.checkPermission();
      if (permission == geo.LocationPermission.denied) {
        permission = await geo.Geolocator.requestPermission();
        if (permission == geo.LocationPermission.denied) {
          _showSnack('Location permission denied.');
          return;
        }
      }

      if (permission == geo.LocationPermission.deniedForever) {
        _showSnack('Location permissions are permanently denied in Settings.');
        return;
      }

      final pos = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.high,
        ),
      );

      await _mapboxMap?.flyTo(
        CameraOptions(
          center: Point(coordinates: Position(pos.longitude, pos.latitude)),
          zoom: 16.5,
          pitch: 60.0,
        ),
        MapAnimationOptions(duration: 1400),
      );
    } catch (e) {
      _showSnack('Could not fetch GPS location: $e');
    } finally {
      if (mounted) setState(() => _isLocating = false);
    }
  }

  Future<void> _searchPlaces(String query) async {
    if (query.trim().length < 2) {
      setState(() => _searchResults = []);
      return;
    }

    setState(() => _isSearching = true);
    try {
      final response = await _dio.get(
        'https://api.mapbox.com/geocoding/v5/mapbox.places/${Uri.encodeComponent(query)}.json',
        queryParameters: {
          'access_token': _mapboxPublicToken,
          'limit': 5,
          'proximity': '74.3132,31.5880',
        },
      );

      final features = response.data['features'] as List<dynamic>? ?? [];
      setState(() {
        _searchResults = features;
      });
    } catch (_) {
      // Ignore transient typing errors
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  Future<void> _selectPlace(dynamic feature) async {
    final coords = feature['center'] as List<dynamic>;
    final double lng = (coords[0] as num).toDouble();
    final double lat = (coords[1] as num).toDouble();

    _searchController.text = feature['text']?.toString() ?? '';
    FocusScope.of(context).unfocus();
    setState(() {
      _searchResults = [];
      _selectedNavIndex = 0;
    });

    await _mapboxMap?.flyTo(
      CameraOptions(
        center: Point(coordinates: Position(lng, lat)),
        zoom: 16.5,
        pitch: 60.0,
        bearing: 20.0,
      ),
      MapAnimationOptions(duration: 1600),
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
      backgroundColor: _bgDark,
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
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            const CircleAvatar(
              radius: 28,
              backgroundColor: _surfaceNavy,
              child: Icon(Icons.person, color: _accentCyan, size: 30),
            ),
            const SizedBox(height: 12),
            Text(
              currentUser?.email ?? 'Explorer Guest',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Spatial Heritage Explorer • Lahore',
              style: TextStyle(color: Colors.white60, fontSize: 13),
            ),
            const SizedBox(height: 24),
            if (currentUser != null)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _surfaceNavy,
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
    _pointAnnotationManager?.deleteAll();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgDark,
      body: Stack(
        children: [
          // 1. Full-screen 3D Dark Mapbox Map
          MapWidget(
            key: const ValueKey('she_3d_map'),
            styleUri: MapboxStyles.STANDARD,
            cameraOptions: _initialCamera,
            onMapCreated: _onMapCreated,
          ),

          // 2. Saved or Settings Overlay Sheet when those bottom tabs are active
          if (_selectedNavIndex == 1) _buildSavedOverlay(),
          if (_selectedNavIndex == 2) _buildSettingsOverlay(),

          // 3. Top Floating Pill Search Bar (with integrated GPS icon) + Profile Avatar
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: _surfaceNavy.withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(30),
                            border: Border.all(
                              color: _accentCyan.withValues(alpha: 0.35),
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black45,
                                blurRadius: 12,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                          child: TextField(
                            controller: _searchController,
                            onChanged: _searchPlaces,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                            ),
                            cursorColor: _accentCyan,
                            decoration: InputDecoration(
                              hintText: 'Search landmark, city...',
                              hintStyle: TextStyle(
                                color: Colors.white.withValues(alpha: 0.55),
                                fontSize: 14,
                              ),
                              prefixIcon: const Icon(
                                Icons.search,
                                color: _accentCyan,
                              ),
                              suffixIcon: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (_isSearching)
                                    const Padding(
                                      padding: EdgeInsets.only(right: 8),
                                      child: SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: _accentCyan,
                                        ),
                                      ),
                                    )
                                  else if (_searchController.text.isNotEmpty)
                                    IconButton(
                                      icon: const Icon(
                                        Icons.clear,
                                        color: Colors.white70,
                                        size: 20,
                                      ),
                                      onPressed: () {
                                        _searchController.clear();
                                        setState(() => _searchResults = []);
                                      },
                                    ),
                                  // Integrated GPS Locate-Me icon button inside right edge
                                  IconButton(
                                    tooltip: 'Center on my GPS location',
                                    onPressed: _isLocating
                                        ? null
                                        : _flyToUserLocation,
                                    icon: _isLocating
                                        ? const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: _accentCyan,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.my_location,
                                            color: _accentCyan,
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
                      // Circular Profile Avatar Button beside Search Pill
                      GestureDetector(
                        onTap: _openProfileSheet,
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: _surfaceNavy.withValues(alpha: 0.92),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _accentCyan.withValues(alpha: 0.35),
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black45,
                                blurRadius: 10,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.person_outline,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),

                  // Dark Autocomplete Results Dropdown
                  if (_searchResults.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      decoration: BoxDecoration(
                        color: _surfaceNavy.withValues(alpha: 0.96),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.12),
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black54,
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
                          color: Colors.white.withValues(alpha: 0.1),
                        ),
                        itemBuilder: (context, index) {
                          final place = _searchResults[index];
                          return ListTile(
                            leading: const Icon(
                              Icons.location_on_outlined,
                              color: _accentCyan,
                            ),
                            title: Text(
                              place['text']?.toString() ?? 'Unknown',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w500,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              place['place_name']?.toString() ?? '',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => _selectPlace(place),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),

          // 4. Floating Rounded Bottom Navigation Dock (Map | Saved | Settings)
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Container(
                margin: const EdgeInsets.fromLTRB(32, 0, 32, 16),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: _surfaceNavy.withValues(alpha: 0.94),
                  borderRadius: BorderRadius.circular(32),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.14),
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black54,
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
            ),
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
      onTap: () => setState(() => _selectedNavIndex = index),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? _accentCyan.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isSelected ? activeIcon : icon,
              color: isSelected ? _accentCyan : Colors.white70,
              size: 22,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? _accentCyan : Colors.white70,
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
    return Container(
      color: _bgDark.withValues(alpha: 0.92),
      padding: const EdgeInsets.fromLTRB(20, 110, 20, 100),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Lahore Heritage Sites',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Tap a landmark to fly the 3D camera directly to it.',
            style: TextStyle(color: Colors.white60, fontSize: 13),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView.separated(
              itemCount: _lahoreSites.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final site = _lahoreSites[index];
                return InkWell(
                  onTap: () => _flyToHeritageSite(site),
                  borderRadius: BorderRadius.circular(18),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _surfaceNavy,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: _accentCyan.withValues(alpha: 0.25),
                      ),
                    ),
                    child: Row(
                      children: [
                        const CircleAvatar(
                          backgroundColor: _bgDark,
                          child: Icon(Icons.account_balance, color: _accentCyan),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                site.name,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                site.era,
                                style: const TextStyle(
                                  color: _accentCyan,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                site.summary,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right, color: Colors.white54),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsOverlay() {
    return Container(
      color: _bgDark.withValues(alpha: 0.92),
      padding: const EdgeInsets.fromLTRB(20, 110, 20, 100),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Map & Display Settings',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              color: _surfaceNavy,
              borderRadius: BorderRadius.circular(18),
            ),
            child: SwitchListTile(
              title: const Text(
                'Night 3D Map Lighting',
                style: TextStyle(color: Colors.white),
              ),
              subtitle: const Text(
                'Dark slate 3D buildings matching #161925 theme',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
              activeThumbColor: _accentCyan,
              value: _nightMapMode,
              onChanged: (val) async {
                setState(() => _nightMapMode = val);
                await _applyMapLightPreset(val);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _HeritagePinClickListener extends OnPointAnnotationClickListener {
  final void Function(PointAnnotation) onClicked;

  _HeritagePinClickListener(this.onClicked);

  @override
  void onPointAnnotationClick(PointAnnotation annotation) {
    onClicked(annotation);
  }
}