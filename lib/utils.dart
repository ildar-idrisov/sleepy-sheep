import 'dart:io';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity/connectivity.dart';
import 'package:wifi_info_flutter/wifi_info_flutter.dart';
import 'package:lan_scanner/lan_scanner.dart';
import 'package:http/http.dart' as http;

void dprint(String message) {
  assert(() {
    print('=== Debug === $message');
    return true;
  }());
}

String compress(String data) {
  var bytes = utf8.encode(data);
  var compressed = gzip.encode(bytes);
  return base64.encode(compressed);
}

String? decompress(String data) {
  try {
    var compressed = base64.decode(data);
    var bytes = gzip.decode(compressed);
    return utf8.decode(bytes);
  } catch (e) {
    dprint('Error decompressing data: $e');
    return null;
  }
}

Future<String?> getLocalIpAddress() async {
  var connectivityResult = await (Connectivity().checkConnectivity());
  if (connectivityResult == ConnectivityResult.wifi) {
    var wifiIP = await WifiInfo().getWifiIP();
    return wifiIP;
  }
  return null;
}

Future<List<Host>> discoverServices() async {
  List<Host> foundDevices = [];
  final scanner = LanScanner();
  var wifiIP = await getLocalIpAddress();
  if (wifiIP != null) {
    var subnet = ipToCSubnet(wifiIP);
    foundDevices = await scanner.quickIcmpScanAsync(subnet);
  }

  return foundDevices;
}

Future<String?> findFirstService() async {
  var wifiIP = await getLocalIpAddress();
  if (wifiIP != null) {
    var subnet = ipToCSubnet(wifiIP);
    for (var dev = 1; dev < 255; dev++) {
      var ip = '$subnet.$dev';
      bool status = await checkSignalServer(ip, '8080');
      if (status == true) {
        return ip;
      }
    }
  }

  return null;
}

Future<bool> checkSignalServer(String? serverIP, String? serverPort) async {
  if (serverIP != null) {
    try {
      var uri = 'http://$serverIP:8080/check-available';
      final response = await http.get(Uri.parse(uri));
      if (response.statusCode == 200 &&
          response.body == "Server is available") {
        return true;
      }
    } catch (e) {
      dprint('Failed to check server: $e');
    }
  }
  return false;
}

Future<void> saveToStorage(String key, String val) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(key, val);
}

Future<String?> getFromStorage(String key) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(key);
}

Future<void> cleanStorage() async {
  SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.clear();
}
