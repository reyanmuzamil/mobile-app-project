import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'features/map/map_screen.dart';
import 'screens/auth_gate.dart';

const String _mapboxToken = String.fromEnvironment('MAPBOX_PUBLIC_TOKEN');
const String _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const String _supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  MapboxOptions.setAccessToken(_mapboxToken);

  if (_supabaseUrl.isNotEmpty && _supabaseAnonKey.isNotEmpty) {
    await Supabase.initialize(
      url: _supabaseUrl,
      anonKey: _supabaseAnonKey,
    );
  }

  runApp(const SheApp());
}

class SheApp extends StatelessWidget {
  const SheApp({super.key});

  @override
  Widget build(BuildContext context) {
    final bool hasSupabaseConfig =
        _supabaseUrl.isNotEmpty && _supabaseAnonKey.isNotEmpty;

    return MaterialApp(
      title: 'SHE – Spatial Heritage Explorer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF161925),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8),
          secondary: Color(0xFF23395B),
          surface: Color(0xFF23395B),
        ),
        useMaterial3: true,
      ),
      home: hasSupabaseConfig ? const AuthGate() : const MapScreen(),
    );
  }
}