import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'features/map/map_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const mapboxToken = String.fromEnvironment('MAPBOX_PUBLIC_TOKEN');
  MapboxOptions.setAccessToken(mapboxToken);
  runApp(const SheApp());
}

class SheApp extends StatelessWidget {
  const SheApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SHE — Spatial Heritage Explorer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF6B4F3B),
        useMaterial3: true,
      ),
      home: const MapScreen(),
    );
  }
}