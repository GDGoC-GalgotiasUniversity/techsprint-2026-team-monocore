//FILE TO HANDLE THE GEMINI SIDE | Model | Prompt | Response

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

  // Callback to update the map with routes and destination AQI
  // Signature: (routes, destLat, destLng, destAqi)
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
    // Declare two tools Gemini can call: get AQI and plan a trip
    final aqiTool = FunctionDeclaration(
      'get_current_air_quality',
      'Returns the real-time AQI. Call this immediately if the user asks about safety. No arguments required.',
      Schema(SchemaType.object, properties: {}),
    );

    final tripTool = FunctionDeclaration(
      'plan_trip_to_destination',
      'Calculates a route to a destination and returns travel time/distance.',
      Schema(
        SchemaType.object,
        properties: {
          'destination_name': Schema(
            SchemaType.string,
            description: "The name of the city or place to go to.",
          ),
        },
        requiredProperties: ['destination_name'],
      ),
    );

    // Initialize the local Gemini model with my system instruction
    _model = GenerativeModel(
      model: 'models/gemini-3-flash',
      apiKey: Secrets.geminiApiKey,
      tools: [
        Tool(functionDeclarations: [aqiTool, tripTool]),
      ],
      systemInstruction: Content.system(
        'You are AeroGuard. You have the user\'s location internally. NEVER ask for it. '
        '1. Safety Queries: Call `get_current_air_quality`. '
        '   - Response MUST be: One summary sentence. Then exactly 3 short bullet points with emojis. '
        '2. Trip Planning: Call `plan_trip_to_destination`. '
        '   - If 2 routes are found: Compare them (Fastest vs Cleaner). '
        '   - If ONLY 1 route is found: State that "The fastest route is also the only viable option right now." '
        '3. Be concise.',
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

        // AQI tool: return current location AQI if we have coords
        if (call.name == 'get_current_air_quality') {
          if (_currentLat != null) {
            try {
              toolResult = await _waqiService.getAirQuality(
                _currentLat!,
                _currentLng!,
              );
            } catch (e) {
              print("🔴 WAQI service error (current): $e");
              toolResult = {'error': 'Failed to fetch current AQI'};
            }
          } else {
            toolResult = {'error': 'Location not found'};
          }
        }
        // Trip planning: get directions, fetch dest AQI, and call back to UI
        else if (call.name == 'plan_trip_to_destination') {
          final dest = call.args['destination_name'] as String?;
          print("🤖 Agent attempting to plan trip to: $dest");

          if (dest != null && _currentLat != null) {
            try {
              final routes = await _directionsService.getDirections(
                LatLng(_currentLat!, _currentLng!),
                dest,
              );

              if (routes.isNotEmpty) {
                // destination coords from first route's last point
                final firstCoords = routes[0]['coordinates'] as List<LatLng>;
                final double destLat = firstCoords.last.latitude;
                final double destLng = firstCoords.last.longitude;

                // fetch destination AQI
                int? destAqi;
                try {
                  final destAqiData = await _waqiService.getAirQuality(
                    destLat,
                    destLng,
                  );
                  if (destAqiData['aqi'] is int)
                    destAqi = destAqiData['aqi'] as int;
                } catch (e) {
                  print("🔴 WAQI service error (destination): $e");
                }

                // call UI callback with route coords and destination info
                if (onRouteFound != null) {
                  List<List<LatLng>> routeCoords = [];
                  for (var r in routes) {
                    routeCoords.add(
                      List<LatLng>.from(r['coordinates'] as List),
                    );
                  }
                  onRouteFound!(routeCoords, destLat, destLng, destAqi);
                }

                // return structured route summary to Gemini
                toolResult = {
                  'routes_found': routes.length,
                  'destination_aqi': destAqi,
                  'primary_route': {
                    'summary': routes[0]['summary'],
                    'duration': routes[0]['duration'],
                    'distance': routes[0]['distance'],
                    'tag': 'Fastest',
                  },
                  'alternative_route': routes.length > 1
                      ? {
                          'summary': routes[1]['summary'],
                          'duration': routes[1]['duration'],
                          'distance': routes[1]['distance'],
                          'tag': 'Cleaner Air Choice',
                        }
                      : null,
                };
              }
            } catch (e) {
              print("🔴 Directions service error: $e");
              toolResult = {'error': 'Failed to get directions: $e'};
            }
          } else {
            toolResult = {'error': 'Destination or current location missing.'};
          }
        }

        // send the tool result back to Gemini
        response = await _chat.sendMessage(
          Content.functionResponse(call.name, toolResult),
        );
      }

      return response.text ?? "I'm having trouble thinking.";
    } catch (e) {
      print("🔴 Gemini/API Error: $e");
      return "I encountered a technical error: $e";
    }
  }
}
