import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:http/http.dart' as http;
import 'utils.dart';

class SignalServer {
  HttpServer? _server;
  String? _sdp;
  String? _answer;
  List<String> _candidates = [];
  String? _availablePhrase = "Server is available";
  List<String> _commandsBroadcaster = [];
  List<String> _commandsClient = [];

  Map<String, String> _params = {};

  Future<void> start() async {
    var router = Router();

    router.post('/sdp', (shelf.Request request) async {
      var body = await request.readAsString();
      _sdp = body;
      _commandsClient.add('sdp-to-client');
      return shelf.Response.ok('SDP received');
    });

    router.get('/get-sdp', (shelf.Request request) {
      _commandsClient.remove('sdp-to-client');
      if (_sdp != null) {
        return shelf.Response.ok(_sdp,
            headers: {'Content-Type': 'application/json'});
      } else {
        return shelf.Response.notFound('No sdp yet');
      }
    });

    router.post('/answer', (shelf.Request request) async {
      var body = await request.readAsString();
      _answer = body;
      _commandsBroadcaster.add('answer-to-broadcaster');
      return shelf.Response.ok('Answer received');
    });

    router.get('/check-answer', (shelf.Request request) {
      _commandsBroadcaster.remove('answer-to-broadcaster');
      if (_answer != null) {
        return shelf.Response.ok(_answer!,
            headers: {'Content-Type': 'application/json'});
      } else {
        return shelf.Response.notFound('No answer yet');
      }
    });

    router.post('/ice-candidate', (shelf.Request request) async {
      var body = await request.readAsString();
      _candidates.add(body);
      _commandsClient.add('ice-candidate-to-client');
      return shelf.Response.ok('Candidate received');
    });

    router.get('/check-ice-candidate', (shelf.Request request) {
      _commandsClient.remove('ice-candidate-to-client');
      if (_candidates.isNotEmpty) {
        return shelf.Response.ok(jsonEncode(_candidates),
            headers: {'Content-Type': 'application/json'});
      } else {
        return shelf.Response.notFound('No ice candidate yet');
      }
    });

    router.post('/available', (shelf.Request request) async {
      var body = await request.readAsString();
      _availablePhrase = body;
      return shelf.Response.ok('Server is available');
    });

    router.get('/check-available', (shelf.Request request) {
      return shelf.Response.ok(_availablePhrase,
          headers: {'Content-Type': 'application/json'});
    });

    router.get('/check-commands-broadcaster', (shelf.Request request) {
      if (_commandsBroadcaster.isNotEmpty) {
        List<String> responseCommands = List<String>.from(_commandsBroadcaster);
        _commandsBroadcaster.clear();
        return shelf.Response.ok(jsonEncode(responseCommands),
            headers: {'Content-Type': 'application/json'});
      } else {
        return shelf.Response.notFound('No commands yet');
      }
    });

    router.get('/check-commands-client', (shelf.Request request) {
      if (_commandsClient.isNotEmpty) {
        List<String> responseCommands = List<String>.from(_commandsClient);
        _commandsClient.clear();
        return shelf.Response.ok(jsonEncode(responseCommands),
            headers: {'Content-Type': 'application/json'});
      } else {
        return shelf.Response.notFound('No commands yet');
      }
    });

    router.post('/set-params', (shelf.Request request) async {
      var body = await request.readAsString();
      var map = json.decode(body);
      _params.addAll(Map<String, String>.from(map));
      _commandsBroadcaster.add('params-to-broadcaster');
      _commandsClient.add('params-to-client');
      return shelf.Response.ok('Params received');
    });

    router.get('/get-params', (shelf.Request request) {
      return shelf.Response.ok(json.encode(_params),
          headers: {'Content-Type': 'application/json'});
    });

    _server = await io.serve(router, InternetAddress.anyIPv4, 8080);
  }

  void stop() {
    _server?.close(force: true);
  }
}

class CommandHandler {
  String? serverIp;
  String? side;
  Function(List<String>)? processCommandsFunction;
  Timer? _timer;

  void start(String serverIp, String side,
      Function(List<String>) processCommandsFunction) {
    this.serverIp = serverIp;
    this.side = side;
    this.processCommandsFunction = processCommandsFunction;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      await _fetchCommands();
    });
  }

  void stop() {
    _timer?.cancel();
  }

  Future<void> _fetchCommands() async {
    var uri = 'http://$serverIp:8080/check-commands-$side';
    try {
      final response = await http.get(Uri.parse(uri));
      if (response.statusCode == 200) {
        final commands = (jsonDecode(response.body) as List)
            .map((item) => item.toString())
            .toList();
        if (processCommandsFunction != null) {
          processCommandsFunction!(commands);
        }
      }
    } catch (e) {
      dprint('Error fetching commands: $e');
    }
  }
}
