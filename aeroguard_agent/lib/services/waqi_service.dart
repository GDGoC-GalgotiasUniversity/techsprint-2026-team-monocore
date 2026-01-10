// FILE TO HANDLE THE WAQI SIDE
// ts is so slow on maps i almost gave up on this

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../secrets.dart';

class WaqiService {
  static const String baseUrl = 'https://api.waqi.info/feed';

  /// Fetch AQI for the given latitude/longitude and return a small map
  /// with `aqi`, `city`, `dominentpol` and `timestamp` when available.
  Future<Map<String, dynamic>> getAirQuality(double lat, double lng) async {
    final String url = '$baseUrl/geo:$lat;$lng/?token=${Secrets.waqiApiKey}';

    try {
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['status'] == 'ok') {
          return {
            'aqi': data['data']['aqi'], // numeric AQI
            'city': data['data']['city']['name'], // station name
            'dominentpol': data['data']['dominentpol'], // e.g. "pm25"
            'timestamp': data['data']['time']['s'], // last update
          };
        }
      }
      throw Exception('Failed to load air quality data');
    } catch (e) {
      print("Error fetching AQI: $e");
      // Return a simple error map so callers can handle it
      return {'aqi': -1, 'error': e.toString()};
    }
  }
}
