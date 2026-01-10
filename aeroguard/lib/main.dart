import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'secrets.dart';
import 'services/waqi_service.dart';

void main() {
  runApp(const AeroGuardApp());
}

class AeroGuardApp extends StatelessWidget {
  const AeroGuardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AeroGuard Agent',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const MapScreen(),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final Completer<GoogleMapController> _controller = Completer();

  // Default location (New Delhi) until we find the user
  static const LatLng _initialPosition = LatLng(28.6139, 77.2090);

  LatLng? _currentPosition;
  int? _startAqi;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _checkPermissionsAndLocate();
  }

  Future<void> _checkPermissionsAndLocate() async {
    // 1. Ask for permission
    var status = await Permission.location.request();

    if (status.isGranted) {
      // 2. Get accurate GPS location
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      // 3. Fetch AQI for this exact spot
      int? fetchedAqi;
      try {
        final aqiData = await WaqiService().getAirQuality(
          position.latitude,
          position.longitude,
        );
        fetchedAqi = aqiData['aqi'] is int ? aqiData['aqi'] : null;
      } catch (e) {
        print("Startup AQI Error: $e");
      }

      // 4. Update UI
      setState(() {
        _currentPosition = LatLng(position.latitude, position.longitude);
        _startAqi = fetchedAqi;
        _isLoading = false;
      });

      // 5. Move Camera
      final GoogleMapController controller = await _controller.future;
      controller.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: _currentPosition!, zoom: 14),
        ),
      );
    } else {
      // Handle permission denied
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // THE MAP
          GoogleMap(
            mapType: MapType.normal,
            initialCameraPosition: const CameraPosition(
              target: _initialPosition,
              zoom: 12,
            ),
            myLocationEnabled: true,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            onMapCreated: (GoogleMapController controller) {
              _controller.complete(controller);
            },
          ),

          // THE HEADER (Shows AQI)
          Positioned(top: 0, left: 0, right: 0, child: _buildFloatingHeader()),

          // LOADING SCREEN
          if (_isLoading)
            Container(
              color: Colors.white,
              child: const Center(
                child: CircularProgressIndicator(color: Colors.teal),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFloatingHeader() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Card(
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(30),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_outlined, color: Colors.teal),
                const SizedBox(width: 8),
                const Text(
                  "AeroGuard",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                if (_startAqi != null) ...[
                  const SizedBox(width: 10),
                  Container(width: 1, height: 20, color: Colors.grey.shade300),
                  const SizedBox(width: 10),
                  Text(
                    "AQI $_startAqi",
                    style: TextStyle(
                      color: _getColorForAqi(_startAqi!),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _getColorForAqi(int aqi) {
    if (aqi <= 50) return Colors.green;
    if (aqi <= 100) return Colors.amber;
    if (aqi <= 150) return Colors.orange;
    return Colors.red;
  }
}
