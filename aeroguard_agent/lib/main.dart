// ignore_for_file: unused_import, unused_field, unused_local_variable
//MAIN CODE FILE

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'secrets.dart';
import 'services/waqi_service.dart';
import 'services/gemini_service.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

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
  // ============================================================
  // For Rounds, enabling and disabling features
  // ============================================================
  static const bool enableHeatmap =
      true; // Set false for Round 1, true for Round 2
  static const bool enableRouting =
      true; // Set false for Round 1, true for Round 2
  // ============================================================

  final Completer<GoogleMapController> _controller = Completer();
  final GeminiService _geminiService = GeminiService();
  final TextEditingController _textController = TextEditingController();

  static const LatLng _initialPosition = LatLng(28.3639, 77.5360);
  LatLng? _currentPosition;

  final Set<Polyline> _polylines = {};
  final Set<Marker> _markers = {};
  final Set<TileOverlay> _tileOverlays = {};
  bool _isCardExpanded = true;
  bool _showHeatmap = true;

  bool _isLoading = true;
  bool _isAgentThinking = false;
  String _agentResponse =
      "I am monitoring the air quality around you. Planning to go somewhere?";

  int? _startAqi;
  int? _destAqi;

  @override
  void initState() {
    super.initState();
    // MODULE CHECK: Only load heatmap if enabled for this round
    if (enableHeatmap) {
      _initializeHeatmap();
    }
    _initializeSystem();
  }

  void _initializeHeatmap() {
    final String overlayId = DateTime.now().millisecondsSinceEpoch.toString();

    final TileOverlay tileOverlay = TileOverlay(
      tileOverlayId: TileOverlayId(overlayId),
      tileProvider: WaqiTileProvider(Secrets.waqiApiKey),
      transparency: 0.4,
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
          // MODULE CHECK: If routing is disabled in this round, ignore the data
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

            // Auto-hide heatmap when routing (if heatmap is supported)
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
            markers: _markers,
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
          children: [
            Card(
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(30),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
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
                      Container(
                        width: 1,
                        height: 20,
                        color: Colors.grey.shade300,
                      ),
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
            const Spacer(),

            // MODULE CHECK: Hide toggle if heatmap is disabled
            if (enableHeatmap) ...[
              FloatingActionButton.small(
                heroTag: "heatmap_toggle",
                backgroundColor: _showHeatmap ? Colors.teal : Colors.white,
                child: Icon(
                  Icons.layers,
                  color: _showHeatmap ? Colors.white : Colors.black54,
                ),
                onPressed: () {
                  setState(() {
                    _showHeatmap = !_showHeatmap;
                  });
                },
              ),
              const SizedBox(width: 8),
            ],

            // MODULE CHECK: Hide reset if routing is disabled (since reset is mostly for routes)
            if (enableRouting) ...[
              FloatingActionButton.small(
                heroTag: "reset_btn",
                backgroundColor: Colors.white,
                child: const Icon(Icons.refresh, color: Colors.black54),
                onPressed: _resetApp,
              ),
            ],
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

class WaqiTileProvider implements TileProvider {
  final String apiKey;
  WaqiTileProvider(this.apiKey);

  @override
  Future<Tile> getTile(int x, int y, int? zoom) async {
    final url =
        "https://tiles.waqi.info/tiles/usepa-aqi/$zoom/$x/$y.png?token=$apiKey";
    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'AeroGuard/1.0 (Flutter)'},
      );
      if (response.statusCode == 200) {
        return Tile(256, 256, response.bodyBytes);
      }
    } catch (e) {
      print("Heatmap Error: $e");
    }
    return TileProvider.noTile;
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


/* NOTES:
THINGS NOT TO MESS WITH WITHOUT HELP:
buildAgentCard: It's as dynamic as i could get it, any more changes and it breaks, it will become a mess
WAQI Heatmap takes time to load, it's all dependant on network, no need to worry about it.
Map animation is FINE, DONT change anything with the zoom controls.

*Gemini flash has limit, isko only use in testing, for demo can use other models but only when in production. */