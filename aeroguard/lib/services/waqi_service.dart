import 'dart:convert';
import 'package:http/http.dart' as http;
import '../secrets.dart';

class WaqiService {
  static const String baseUrl = 'https://api.waqi.info/feed';

  Future<Map<String, dynamic>> getAirQuality(double lat, double lng) async {
    final String url = '$baseUrl/geo:$lat;$lng/?token=${Secrets.waqiApiKey}';

    try {
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['status'] == 'ok') {
          return {
            'aqi': data['data']['aqi'],
            'city': data['data']['city']['name'],
            'dominentpol': data['data']['dominentpol'],
            'timestamp': data['data']['time']['s'],
          };
        }
      }
      throw Exception('Failed to load air quality data');
    } catch (e) {
      print("Error fetching AQI: $e");
      return {'aqi': -1, 'error': e.toString()};
    }
  }
}
