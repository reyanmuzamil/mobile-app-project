import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  MapboxMap? _mapboxMap;
  final TextEditingController _searchController = TextEditingController();
  final Dio _dio = Dio();
  List<dynamic> _searchResults = [];
  bool _isLocating = false;
  bool _isSearching = false;

  
  static const String _mapboxPublicToken = String.fromEnvironment('MAPBOX_PUBLIC_TOKEN');
  
  // Default camera: Lahore (60-degree pitch for 3D buildings)
  static final CameraOptions _initialCamera = CameraOptions(
    center: Point(coordinates: Position(74.3587, 31.5204)),
    zoom: 15.5,
    pitch: 60.0,
    bearing: -17.6,
  );

  void _onMapCreated(MapboxMap mapboxMap) async {
    _mapboxMap = mapboxMap;

    // Enable the native blue location puck on the map
    await mapboxMap.location.updateSettings(
      LocationComponentSettings(
        enabled: true,
        pulsingEnabled: true,
      ),
    );
  }

  Future<void> _flyToUserLocation() async {
    setState(() => _isLocating = true);
    try {
      bool serviceEnabled = await geo.Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _showSnack('Enable GPS / Location services on your device.');
        return;
      }

      geo.LocationPermission permission = await geo.Geolocator.checkPermission();
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
          'proximity': '74.3587,31.5204', // Bias results near Lahore
        },
      );

      final features = response.data['features'] as List<dynamic>? ?? [];
      setState(() {
        _searchResults = features;
      });
    } catch (_) {
      // Silently ignore transient typing errors
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
    setState(() => _searchResults = []);

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

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 1. Full-screen 3D Mapbox Standard Map (includes 3D buildings & landmarks)
          MapWidget(
            key: const ValueKey('she_3d_map'),
            styleUri: MapboxStyles.STANDARD,
            cameraOptions: _initialCamera,
            onMapCreated: _onMapCreated,
          ),

          // 2. Floating Search Bar + Autocomplete Dropdown
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Material(
                    elevation: 6,
                    borderRadius: BorderRadius.circular(16),
                    color: Colors.white,
                    child: TextField(
                      controller: _searchController,
                      onChanged: _searchPlaces,
                      decoration: InputDecoration(
                        hintText: 'Search historic sites, streets, landmarks...',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _isSearching
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              )
                            : (_searchController.text.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear),
                                    onPressed: () {
                                      _searchController.clear();
                                      setState(() => _searchResults = []);
                                    },
                                  )
                                : null),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                    ),
                  ),
                  if (_searchResults.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 6),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black26,
                            blurRadius: 10,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ListView.separated(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: _searchResults.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final place = _searchResults[index];
                          return ListTile(
                            leading: const Icon(Icons.location_on_outlined),
                            title: Text(
                              place['text']?.toString() ?? 'Unknown',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              place['place_name']?.toString() ?? '',
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
        ],
      ),

      // 3. Locate-Me GPS Floating Action Button
      floatingActionButton: FloatingActionButton(
        onPressed: _isLocating ? null : _flyToUserLocation,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        tooltip: 'Center on my GPS location',
        child: _isLocating
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              )
            : const Icon(Icons.my_location),
      ),
    );
  }
}