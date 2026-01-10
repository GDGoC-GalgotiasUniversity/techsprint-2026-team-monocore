import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../secrets.dart';
import 'waqi_service.dart';
import 'directions_service.dart';

class GeminiService {
  late final GenerativeModel _model;
  late final ChatSession _chat;
  final WaqiService _waqiService = WaqiService();
  final DirectionsService _directionsService = DirectionsService();

  double? _currentLat;
  double? _currentLng;

  Function(
    List<List<LatLng>> routes,
    double? destLat,
    double? destLng,
    int? destAqi,
  )?
  onRouteFound;

  void updateLocation(double lat, double lng) {
    _currentLat = lat;
    _currentLng = lng;
  }

  Future<void> init() async {
    final aqiTool = FunctionDeclaration(
      'get_current_air_quality',
      'Returns real-time AQI. No arguments.',
      Schema(SchemaType.object, properties: {}),
    );

    final tripTool = FunctionDeclaration(
      'plan_trip_to_destination',
      'Calculates routes to a destination.',
      Schema(
        SchemaType.object,
        properties: {
          'destination_name': Schema(
            SchemaType.string,
            description: "City or place name.",
          ),
        },
        requiredProperties: ['destination_name'],
      ),
    );

    _model = GenerativeModel(
      model: 'gemini-flash-latest',
      apiKey: Secrets.geminiApiKey,
      tools: [
        Tool(functionDeclarations: [aqiTool, tripTool]),
      ],
      // UPDATED PROMPT: Forces comparison logic
      systemInstruction: Content.system(
        'You are AeroGuard. You have location access. NEVER ask for it. '
        '1. Safety Queries: Call `get_current_air_quality`. Response: Summary + 3 bullets. '
        '2. Trip Planning: Call `plan_trip_to_destination`. '
        '   - IF 2 ROUTES FOUND: You MUST list both options with their duration. '
        '     Example: "🔵 **Fastest:** 20 mins | 🟢 **Cleaner:** 24 mins (+4 mins). I recommend the Green route for better air." '
        '   - IF 1 ROUTE FOUND: "Only one viable route exists right now: [Duration]."',
      ),
    );

    _chat = _model.startChat();
  }

  Future<String> sendMessage(String message) async {
    try {
      var response = await _chat.sendMessage(Content.text(message));

      final functionCalls = response.functionCalls.toList();
      if (functionCalls.isNotEmpty) {
        final call = functionCalls.first;
        Map<String, dynamic> toolResult = {};

        if (call.name == 'get_current_air_quality') {
          if (_currentLat != null) {
            toolResult = await _waqiService.getAirQuality(
              _currentLat!,
              _currentLng!,
            );
          } else {
            toolResult = {'error': 'Location context missing'};
          }
        } else if (call.name == 'plan_trip_to_destination') {
          final dest = call.args['destination_name'] as String?;

          if (dest != null && _currentLat != null) {
            final routes = await _directionsService.getDirections(
              LatLng(_currentLat!, _currentLng!),
              dest,
            );

            if (routes.isNotEmpty) {
              double destLat = routes[0]['coordinates'].last.latitude;
              double destLng = routes[0]['coordinates'].last.longitude;
              final destAqiData = await _waqiService.getAirQuality(
                destLat,
                destLng,
              );
              final int? destAqi = destAqiData['aqi'] is int
                  ? destAqiData['aqi']
                  : null;

              if (onRouteFound != null) {
                List<List<LatLng>> routeCoords = [];
                for (var r in routes) {
                  routeCoords.add(r['coordinates'] as List<LatLng>);
                }
                onRouteFound!(routeCoords, destLat, destLng, destAqi);
              }

              // CALCULATE DIFFERENCES MANUALLY FOR THE AGENT
              String diffText = "";
              if (routes.length > 1) {
                int val1 = routes[0]['duration_value'];
                int val2 = routes[1]['duration_value'];
                int diffMinutes = ((val2 - val1) / 60).round();
                diffText = "+$diffMinutes mins";
              }

              toolResult = {
                'routes_found': routes.length,
                'destination_aqi': destAqi,
                'primary_route': {
                  'summary': routes[0]['summary'],
                  'duration': routes[0]['duration'],
                  'distance': routes[0]['distance'],
                  'tag': 'Fastest (Blue)',
                },
                'alternative_route': routes.length > 1
                    ? {
                        'summary': routes[1]['summary'],
                        'duration': routes[1]['duration'],
                        'distance': routes[1]['distance'],
                        'time_difference':
                            diffText, // Sending the calculated math
                        'tag': 'Cleaner Option (Green)',
                      }
                    : null,
              };
            } else {
              toolResult = {'error': 'No routes found via API.'};
            }
          }
        }

        response = await _chat.sendMessage(
          Content.functionResponse(call.name, toolResult),
        );
      }

      return response.text ?? "Analyzing routes...";
    } catch (e) {
      print("Gemini Service Error: $e");
      return "Connection error. Please try again.";
    }
  }
}
