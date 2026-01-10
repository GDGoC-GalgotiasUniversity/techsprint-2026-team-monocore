//FILE FOR GETTING ROUTES | One/Two

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import '../secrets.dart';

class DirectionsService {
  static const String _baseUrl =
      'https://maps.googleapis.com/maps/api/directions/json';

  // Fetch up to 2 route summaries (coordinates, distance, duration, etc.)
  Future<List<Map<String, dynamic>>> getDirections(
    LatLng origin,
    String destination,
  ) async {
    final String url =
        '$_baseUrl?origin=${origin.latitude},${origin.longitude}'
        '&destination=$destination'
        '&alternatives=true'
        '&key=${Secrets.googleMapsApiKey}';

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        List<Map<String, dynamic>> tempRoutes = [];

        if ((data['routes'] as List).isNotEmpty) {
          for (var route in (data['routes'] as List)) {
            final leg = route['legs'][0];
            final points = PolylinePoints.decodePolyline(
              route['overview_polyline']['points'],
            );
            final coords = points
                .map((p) => LatLng(p.latitude, p.longitude))
                .toList();

            tempRoutes.add({
              'coordinates': coords,
              'distance': leg['distance']['text'],
              'duration': leg['duration']['text'],
              'duration_value':
                  leg['duration']['value'], // Critical for sorting
              'end_address': leg['end_address'],
              'summary': route['summary'],
              'end_location': {
                'lat': leg['end_location']['lat'],
                'lng': leg['end_location']['lng'],
              },
            });
          }

          // Had to sort by duration value so the fastest route is first, if there are 2
          tempRoutes.sort(
            (a, b) => (a['duration_value'] as int).compareTo(
              b['duration_value'] as int,
            ),
          );

          return tempRoutes.take(2).toList();
        }
      }
      return [];
    } catch (e) {
      print("Directions Error: $e");
      return [];
    }
  }
}
