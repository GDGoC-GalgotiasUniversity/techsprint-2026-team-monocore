// ignore_for_file: unused_import, unused_field, unused_local_variable

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'secrets.dart';
import 'services/waqi_service.dart';
import 'services/gemini_service.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:http/http.dart' as http;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

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
  static const bool enableHeatmap = true;
  static const bool enableRouting = true;
  List<Map<String, dynamic>> _hazardData = [];

  final Completer<GoogleMapController> _controller = Completer();
  final GeminiService _geminiService = GeminiService();
  final TextEditingController _textController = TextEditingController();
  final ImagePicker _picker = ImagePicker();
  final Set<Marker> _reportMarkers = {};

  static const LatLng _initialPosition = LatLng(28.3639, 77.5360);
  LatLng? _currentPosition;

  final Set<Polyline> _polylines = {};
  final Set<Marker> _markers = {};
  final Set<TileOverlay> _tileOverlays = {};
  bool _isCardExpanded = true;
  bool _showHeatmap = true;
  bool _isVerifyingReport = false;

  bool _isLoading = true;
  bool _isAgentThinking = false;
  String _agentResponse =
      "I am monitoring the air quality around you. Planning to go somewhere?";

  int? _startAqi;
  int? _destAqi;

  @override
  void initState() {
    super.initState();
    if (enableHeatmap) {
      _initializeHeatmap();
      _loadSavedReports();
    }
    _initializeSystem();
  }

  void _createMarkerFromData(Map<String, dynamic> report) {
    final String id = report['id'];
    final LatLng position = LatLng(report['lat'], report['lng']);
    final String type = report['type'];

    final marker = Marker(
      markerId: MarkerId(id),
      position: position,
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
      // Instead of just an info window, we verify on tap
      onTap: () {
        _showVerifyDialog(id, type);
      },
    );

    _reportMarkers.add(marker);
  }

  void _showVerifyDialog(String id, String type) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Verify $type"),
        content: const Text("Is this hazard still present at this location?"),
        actions: [
          // "NO" BUTTON -> REMOVES THE REPORT
          TextButton(
            onPressed: () {
              setState(() {
                // 1. Remove from local memory
                _hazardData.removeWhere((item) => item['id'] == id);
                _reportMarkers.removeWhere((m) => m.markerId.value == id);
              });
              // 2. Save changes to disk
              _saveReports();
              Navigator.pop(ctx);

              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text("Thanks! Report marked as resolved."),
                ),
              );
            },
            child: const Text(
              "No (Clear It)",
              style: TextStyle(color: Colors.red),
            ),
          ),

          // "YES" BUTTON -> KEEPS IT
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
            child: const Text(
              "Yes (Still Here)",
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  // LOAD reports from disk on startup
  Future<void> _loadSavedReports() async {
    final prefs = await SharedPreferences.getInstance();
    final String? storedString = prefs.getString('hazard_reports');

    if (storedString != null) {
      final List<dynamic> decoded = json.decode(storedString);
      setState(() {
        _hazardData = decoded.cast<Map<String, dynamic>>();
        // Rebuild markers from data
        _reportMarkers.clear();
        for (var report in _hazardData) {
          _createMarkerFromData(report);
        }
      });
    }
  }

  // SAVE current list to disk
  Future<void> _saveReports() async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = json.encode(_hazardData);
    await prefs.setString('hazard_reports', encoded);
  }

  // CITIZEN SENTINEL: New Flow
  Future<void> _handleReport() async {
    // 1. Pick Image
    final XFile? photo = await _picker.pickImage(source: ImageSource.camera);
    if (photo == null) return;

    // 2. Open the Input Dialog immediately (No full screen loading!)
    if (mounted) {
      _showReportDialog(File(photo.path));
    }
  }

  void _showReportDialog(File imageFile) {
    final TextEditingController reportController = TextEditingController();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: Row(
                children: const [
                  Icon(Icons.warning_amber_rounded, color: Colors.orange),
                  SizedBox(width: 10),
                  Text("Report Hazard"),
                ],
              ),
              // FIX A: Wrap content in SingleChildScrollView to prevent overflow
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        imageFile,
                        height: 150,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(height: 15),

                    TextField(
                      controller: reportController,
                      enabled: !_isVerifyingReport,
                      decoration: InputDecoration(
                        hintText: "What do you see? (e.g. Smoke)",
                        filled: true,
                        fillColor: Colors.grey.shade100,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),

                    if (_isVerifyingReport) ...[
                      const SizedBox(height: 20),
                      const LinearProgressIndicator(
                        color: Colors.teal,
                        backgroundColor: Colors.black12,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        "Agent is verifying evidence...",
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                if (!_isVerifyingReport)
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text(
                      "Cancel",
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),

                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isVerifyingReport
                        ? Colors.grey
                        : Colors.teal,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                  onPressed: _isVerifyingReport
                      ? null
                      : () async {
                          if (reportController.text.isEmpty) return;

                          // FIX B: Dismiss Keyboard INSTANTLY to free up screen space
                          FocusScope.of(context).unfocus();

                          setDialogState(() {
                            _isVerifyingReport = true;
                          });

                          // Artificial delay for demo
                          await Future.delayed(const Duration(seconds: 2));

                          final result = await _geminiService
                              .analyzePollutionImage(
                                imageFile,
                                reportController.text,
                              );

                          if (mounted) {
                            Navigator.pop(context);
                            setState(() {
                              _isVerifyingReport = false;
                            });

                            if (result['verified'] == true) {
                              _addHazardMarker(result['type']);
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    "❌ Agent could not verify the hazard.",
                                  ),
                                ),
                              );
                            }
                          }
                        },
                  child: const Text("Verify & Report"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _addHazardMarker(String type) {
    if (_currentPosition == null) return;

    final String reportId = DateTime.now().millisecondsSinceEpoch.toString();

    // 1. Create Data Object
    final newReport = {
      'id': reportId,
      'type': type,
      'lat': _currentPosition!.latitude,
      'lng': _currentPosition!.longitude,
      'timestamp': DateTime.now().toIso8601String(),
    };

    setState(() {
      // 2. Add to Data List
      _hazardData.add(newReport);

      // 3. Create Visual Marker
      _createMarkerFromData(newReport);
    });

    // 4. Persist to Disk
    _saveReports();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white),
            const SizedBox(width: 10),
            Text("Verified: $type added to map."),
          ],
        ),
        backgroundColor: Colors.teal,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _initializeHeatmap() {
    final String overlayId = DateTime.now().millisecondsSinceEpoch.toString();

    final TileOverlay tileOverlay = TileOverlay(
      tileOverlayId: TileOverlayId(overlayId),
      tileProvider: WaqiTileProvider(Secrets.waqiApiKey),
      transparency: 0.2,
      zIndex: 999,
    );

    setState(() {
      _tileOverlays.add(tileOverlay);
    });
  }

  Future<void> _initializeSystem() async {
    await _geminiService.init();

    _geminiService.onRouteFound =
        (
          List<List<LatLng>> allRoutes,
          double? destLat,
          double? destLng,
          int? destAqi,
        ) async {
          if (!enableRouting) return;

          int? currentAqi;
          if (_currentPosition != null) {
            try {
              final currentData = await WaqiService().getAirQuality(
                _currentPosition!.latitude,
                _currentPosition!.longitude,
              );
              currentAqi = currentData['aqi'] is int
                  ? currentData['aqi'] as int
                  : null;
            } catch (e) {
              print("WAQI fetch error (current): $e");
            }
          }

          setState(() {
            _polylines.clear();
            _markers.clear();

            // Auto-hide heatmap when routing
            if (enableHeatmap) {
              _showHeatmap = false;
            }

            _startAqi = currentAqi;
            _destAqi = destAqi;

            for (int i = 0; i < allRoutes.length; i++) {
              final isGreenRoute = (i == 1);

              _polylines.add(
                Polyline(
                  polylineId: PolylineId('route_$i'),
                  points: allRoutes[i],
                  color: isGreenRoute ? Colors.green : Colors.blueAccent,
                  width: isGreenRoute ? 7 : 5,
                  zIndex: isGreenRoute ? 2 : 1,
                ),
              );
            }

            if (destLat != null && destLng != null) {
              _markers.add(
                Marker(
                  markerId: const MarkerId('destination'),
                  position: LatLng(destLat, destLng),
                  icon: BitmapDescriptor.defaultMarkerWithHue(
                    BitmapDescriptor.hueRed,
                  ),
                  infoWindow: InfoWindow(
                    title: "Destination",
                    snippet: "AQI: ${destAqi ?? '--'}",
                  ),
                ),
              );
            }
          });

          if (allRoutes.isNotEmpty) {
            final controller = await _controller.future;
            try {
              await controller.animateCamera(
                CameraUpdate.newLatLngBounds(
                  _boundsFromLatLngList(allRoutes[0]),
                  50,
                ),
              );
            } catch (_) {}
          }
        };

    await _checkPermissionsAndLocate();
  }

  Future<void> _checkPermissionsAndLocate() async {
    var status = await Permission.location.request();

    if (status.isGranted) {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

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

      setState(() {
        _currentPosition = LatLng(position.latitude, position.longitude);
        _startAqi = fetchedAqi;
        _isLoading = false;
      });

      _geminiService.updateLocation(position.latitude, position.longitude);

      final GoogleMapController controller = await _controller.future;
      controller.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: _currentPosition!, zoom: 14),
        ),
      );
    } else {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _resetApp() async {
    setState(() {
      _polylines.clear();
      _markers.clear();
      _startAqi = null;
      _destAqi = null;
      _showHeatmap = true;
      _agentResponse =
          "I am monitoring the air quality around you. Had a change of mind on going out?";
      _isCardExpanded = true;
    });

    if (_currentPosition != null) {
      final controller = await _controller.future;
      controller.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: _currentPosition!, zoom: 14),
        ),
      );
    }
  }

  Future<void> _handleUserQuery() async {
    if (_textController.text.isEmpty) return;
    FocusScope.of(context).unfocus();

    final query = _textController.text;
    setState(() {
      _isCardExpanded = true;
      _isAgentThinking = true;
      _textController.clear();
    });

    final response = await _geminiService.sendMessage(query);

    setState(() {
      _agentResponse = response;
      _isAgentThinking = false;
    });
  }

  LatLngBounds _boundsFromLatLngList(List<LatLng> list) {
    double? x0, x1, y0, y1;
    for (LatLng latLng in list) {
      if (x0 == null) {
        x0 = x1 = latLng.latitude;
        y0 = y1 = latLng.longitude;
      } else {
        if (latLng.latitude > x1!) x1 = latLng.latitude;
        if (latLng.latitude < x0!) x0 = latLng.latitude;
        if (latLng.longitude > y1!) y1 = latLng.longitude;
        if (latLng.longitude < y0!) y0 = latLng.longitude;
      }
    }
    return LatLngBounds(
      northeast: LatLng(x1!, y1!),
      southwest: LatLng(x0!, y0!),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          GoogleMap(
            mapType: MapType.normal,
            minMaxZoomPreference: const MinMaxZoomPreference(0, 15),
            initialCameraPosition: const CameraPosition(
              target: _initialPosition,
              zoom: 12,
            ),
            polylines: _polylines,
            markers: _markers.union(_reportMarkers),
            // MODULE CHECK: Only show tiles if feature enabled
            tileOverlays: (enableHeatmap && _showHeatmap) ? _tileOverlays : {},
            myLocationEnabled: true,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            onMapCreated: (GoogleMapController controller) {
              _controller.complete(controller);
            },
          ),

          Positioned(top: 0, left: 0, right: 0, child: _buildFloatingHeader()),
          Positioned(bottom: 30, left: 16, right: 16, child: _buildAgentCard()),

          if (_isLoading)
            Container(
              color: Colors.white,
              width: double.infinity,
              height: double.infinity,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.eco, size: 80, color: Colors.teal),
                  const SizedBox(height: 20),
                  const Text(
                    "AeroGuard",
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: Colors.teal,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    "Breathe Smarter",
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.teal.shade700,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 50),
                  const CircularProgressIndicator(color: Colors.teal),
                ],
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
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // LEFT SIDE: Compact Status Card
            Flexible(
              child: Card(
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ), // Slightly tighter padding
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_outlined, color: Colors.teal),

                      // REMOVED: The "AeroGuard" text widget is gone.
                      if (_startAqi != null) ...[
                        const SizedBox(width: 10),
                        // Divider
                        Container(
                          width: 1,
                          height: 20,
                          color: Colors.grey.shade300,
                        ),
                        const SizedBox(width: 10),
                        // AQI Text
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

            const SizedBox(width: 8),

            // RIGHT SIDE: Buttons (Same as before)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (enableHeatmap) ...[
                  FloatingActionButton.small(
                    heroTag: "heatmap_toggle",
                    backgroundColor: _showHeatmap ? Colors.teal : Colors.white,
                    child: Icon(
                      Icons.layers,
                      color: _showHeatmap ? Colors.white : Colors.black54,
                    ),
                    onPressed: () =>
                        setState(() => _showHeatmap = !_showHeatmap),
                  ),
                  const SizedBox(width: 8),
                ],

                FloatingActionButton.small(
                  heroTag: "report_btn",
                  backgroundColor: Colors.orange,
                  child: const Icon(Icons.camera_alt, color: Colors.white),
                  onPressed: _handleReport,
                ),

                if (enableRouting) ...[
                  const SizedBox(width: 8),
                  FloatingActionButton.small(
                    heroTag: "reset_btn",
                    backgroundColor: Colors.white,
                    child: const Icon(Icons.refresh, color: Colors.black54),
                    onPressed: _resetApp,
                  ),
                ],
              ],
            ),
          ],
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

  Widget _buildAqiColumn(String label, int? aqi) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 4),
        Text(
          "${aqi ?? '--'}",
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: _getColorForAqi(aqi ?? 0),
          ),
        ),
      ],
    );
  }

  Widget _buildAgentCard() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      constraints: BoxConstraints(
        minHeight: 85,
        maxHeight: _isCardExpanded ? 500 : 85,
      ),
      child: Card(
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.shield, color: Colors.teal, size: 28),
                    const SizedBox(width: 10),
                    const Text(
                      "AeroGuard",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(
                        _isCardExpanded
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_up,
                      ),
                      onPressed: () {
                        setState(() {
                          _isCardExpanded = !_isCardExpanded;
                        });
                      },
                    ),
                  ],
                ),

                if (_isCardExpanded) ...[
                  const SizedBox(height: 5),
                  if (_isAgentThinking)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 15),
                      child: LinearProgressIndicator(
                        backgroundColor: Colors.teal.shade50,
                        color: Colors.teal,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),

                  // MODULE CHECK: Only show trip stats if Routing is enabled
                  if (enableRouting &&
                      _destAqi != null &&
                      !_isAgentThinking) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.teal.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.teal.shade100),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _buildAqiColumn("Start", _startAqi),
                          const Icon(Icons.arrow_forward, color: Colors.grey),
                          _buildAqiColumn("Destination", _destAqi),
                        ],
                      ),
                    ),
                  ],

                  FadeInText(
                    key: ValueKey(_agentResponse),
                    child: MarkdownBody(
                      data: _agentResponse,
                      styleSheet: MarkdownStyleSheet(
                        p: const TextStyle(color: Colors.black87, fontSize: 15),
                        strong: const TextStyle(
                          color: Colors.teal,
                          fontWeight: FontWeight.bold,
                        ),
                        listBullet: const TextStyle(color: Colors.teal),
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),
                  TextField(
                    controller: _textController,
                    onSubmitted: (_) => _handleUserQuery(),
                    decoration: InputDecoration(
                      hintText: "Ask me...",
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                      ),
                      filled: true,
                      fillColor: Colors.grey.shade200,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(30),
                        borderSide: BorderSide.none,
                      ),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.send, color: Colors.teal),
                        onPressed: _handleUserQuery,
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ⚡ High-Performance Cached Provider
class WaqiTileProvider implements TileProvider {
  final String apiKey;
  // Use the default cache manager to store/retrieve files
  final BaseCacheManager _cacheManager = DefaultCacheManager();

  WaqiTileProvider(this.apiKey);

  @override
  Future<Tile> getTile(int x, int y, int? zoom) async {
    // 1. Zoom Clamp (Safety): WAQI only has tiles up to zoom ~15-16
    // If we request a tile deeper than that, return transparent immediately to stop loading spinners
    if (zoom == null || zoom > 16) return TileProvider.noTile;

    final url =
        "https://tiles.waqi.info/tiles/usepa-aqi/$zoom/$x/$y.png?token=$apiKey";

    try {
      // 2. The Magic: 'getSingleFile' checks cache first, then network
      final File file = await _cacheManager.getSingleFile(
        url,
        headers: {'User-Agent': 'AeroGuard/1.0 (Flutter)'}, // Anti-blocking
      );

      // 3. Return the bytes from the cached file
      final Uint8List bytes = await file.readAsBytes();
      return Tile(256, 256, bytes);
    } catch (e) {
      // If network fails or tile missing, return transparent tile so map doesn't lag
      return TileProvider.noTile;
    }
  }
}

class FadeInText extends StatefulWidget {
  final Widget child;
  const FadeInText({super.key, required this.child});

  @override
  State<FadeInText> createState() => _FadeInTextState();
}

class _FadeInTextState extends State<FadeInText>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: _opacity, child: widget.child);
  }
}
