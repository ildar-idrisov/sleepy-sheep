import 'dart:core';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:qr_code_scanner/qr_code_scanner.dart';
import 'package:lan_scanner/lan_scanner.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'signal_server.dart';
import 'utils.dart';

class VideoBroadcasting extends StatefulWidget {
  final bool isBroadcaster;

  VideoBroadcasting({required this.isBroadcaster});

  @override
  _VideoBroadcastingState createState() => _VideoBroadcastingState();
}

class _VideoBroadcastingState extends State<VideoBroadcasting> {
  late RTCPeerConnection _peerConnection;
  late MediaStream _localStream;
  final _remoteRenderer = RTCVideoRenderer();
  final _localRenderer = RTCVideoRenderer();
  final _signalServer = SignalServer();
  String? _localServerIP = '';
  String? _remoteServerIP = '';
  final String _serverPort = '8080';
  String _compressedServerIP = '';
  final _commandHandler = CommandHandler();

  final GlobalKey qrKey = GlobalKey(debugLabel: 'QR');
  QRViewController? controller;

  Future<void>? _initializationFuture;

  Map<String, String> _params = {};
  bool _isFrontCamera = true;
  bool _isMuted = true;

  @override
  void initState() {
    super.initState();
    _initializationFuture = initRenderers();
  }

  Future<void> initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();

    if (widget.isBroadcaster) {
      _signalServer.start();
      _localServerIP = await getLocalIpAddress();
      if (_localServerIP == null) {
        // Send message to user - Wrong network settings
        return;
      }
      setState(() {});
      dprint("localServerIP: $_localServerIP");
    }

    final peerConnection = await _createPeerConnection();
    _peerConnection = peerConnection;

    if (widget.isBroadcaster) {
      final localStream = await _getUserMedia();
      _localStream = localStream;
      _localRenderer.srcObject = _localStream;
      setState(() {});
      await _broadcastStream();
    } else {
      await _receiveStream();
    }

    if (widget.isBroadcaster) {
      _commandHandler.start(
          _localServerIP!, 'broadcaster', processCommandsFunctionBroadcaster);
    } else {
      _commandHandler.start(
          _remoteServerIP!, 'client', processCommandsFunctionClient);
    }
  }

  Future<RTCPeerConnection> _createPeerConnection() async {
    final Map<String, dynamic> config = {
      "iceServers": [
        {"url": "stun:stun.l.google.com:19302"}
      ]
    };

    final Map<String, dynamic> constraints = {
      "mandatory": {
        "OfferToReceiveAudio": true,
        "OfferToReceiveVideo": true,
      },
      "optional": [],
    };

    final pc = await createPeerConnection(config, constraints);
    if (!widget.isBroadcaster) {
      pc.onTrack = _onTrack;
    }
    if (widget.isBroadcaster) {
      pc.onIceCandidate = _onIceCandidate;
    }
    return pc;
  }

  void _onTrack(RTCTrackEvent event) {
    if (event.track.kind == 'video') {
      _remoteRenderer.srcObject = event.streams[0];

      _isMuted = true;
      List<MediaStreamTrack> audioTracks =
          _remoteRenderer.srcObject!.getAudioTracks();
      for (MediaStreamTrack track in audioTracks) {
        track.enabled = !_isMuted;
      }
      setState(() {});
    }
  }

  Future<void> _onIceCandidate(RTCIceCandidate candidate) async {
    var uri = 'http://$_localServerIP:$_serverPort/ice-candidate';
    try {
      final response = await http.post(
        Uri.parse(uri),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        }),
      );
      if (response.statusCode != 200) {
        dprint('Failed to send ICE candidate: ${response.statusCode}');
      }
    } catch (e) {
      dprint('Error sending ICE candidate: $e');
    }
  }

  void handleRemoteIceCandidate(RTCIceCandidate candidate) async {
    try {
      await _peerConnection.addCandidate(candidate);
    } catch (e) {
      dprint('Error adding remote ICE candidate: $e');
    }
  }

  Future<MediaStream> _getUserMedia() async {
    final Map<String, dynamic> constraints = {
      'audio': true,
      'video': {
        'mandatory': {
          'minWidth': '720',
          'minHeight': '405',
          'minFrameRate': '30',
        },
        'facingMode': 'user',
        'optional': [],
      }
    };
    final stream = await navigator.mediaDevices.getUserMedia(constraints);
    return stream;
  }

  Future<void> _broadcastStream() async {
    _localStream.getTracks().forEach((track) {
      _peerConnection.addTrack(track, _localStream);
    });
    await _createOffer();
  }

  Future<void> _createOffer() async {
    try {
      final offer =
          await _peerConnection.createOffer({'offerToReceiveVideo': 1});
      await _peerConnection.setLocalDescription(offer);
      await _sendSdpToServer(offer.sdp!);
    } catch (e) {
      dprint('Error creating offer: $e');
    }
  }

  Future<void> _sendSdpToServer(String sdp) async {
    var uri = 'http://$_localServerIP:$_serverPort/sdp';
    try {
      var response = await http.post(
        Uri.parse(uri),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'sdp': sdp}),
      );
      if (response.statusCode == 200) {
      } else {
        dprint('Failed to send sdp to server: ${response.statusCode}');
      }
    } catch (e) {
      dprint('Error sending sdp to server: $e');
    }
  }

  _shareServerIPviaQR() async {
    _compressedServerIP = compress(_localServerIP!);
    setState(() {});
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("Scan it"),
          content: _compressedServerIP.isNotEmpty
              ? SizedBox(
                  width: 300.0,
                  height: 300.0,
                  child: Center(
                    child: QrImageView(
                      data: _compressedServerIP,
                      version: QrVersions.auto,
                      size: 300,
                      gapless: false,
                    ),
                  ),
                )
              : const Text('Waiting...'),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Ok'),
            ),
          ],
        );
      },
    );
  }

  void _handleAnswer(String sdpDescription) async {
    try {
      RTCSessionDescription description =
          RTCSessionDescription(sdpDescription, 'answer');
      await _peerConnection.setRemoteDescription(description);
    } catch (e) {
      dprint('Error handling answer: $e');
    }
  }

  Future<void> _setRemoteServerIP() async {
    // For Debug
    //await cleanStorage();

    if (_remoteServerIP == "") {
      var serverIP = await getFromStorage('serverIP');
      var status = await checkSignalServer(serverIP, _serverPort);
      if (status == true) {
        _remoteServerIP = serverIP;
        saveToStorage('serverIP', _remoteServerIP!);
      } else {
        //var ip = await findFirstService();
        //if (ip != null) {
        //  _remoteServerIP = ip;
        //  saveToStorage('serverIP', _remoteServerIP!);
        //}
        showDialog(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text("First time connection"),
              content: const Text(
                  "It looks like you're adding a new device to the network. We'll quickly find and remember your child's device to make future connections a breeze!"),
              actions: <Widget>[
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                  child: const Text('Ok'),
                ),
              ],
            );
          },
        );
        List<Host> potentialServers = await discoverServices();
        for (Host host in potentialServers) {
          status = await checkSignalServer(
              host.internetAddress.address, _serverPort);
          if (status == true) {
            _remoteServerIP = host.internetAddress.address;
            saveToStorage('serverIP', _remoteServerIP!);
            break;
          }
        }
      }
      if (_remoteServerIP == "") {
        await _scanQRCode();
      }
    }
    if (_remoteServerIP == "") {
      showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text("Incorrect network"),
            content: const Text(
                "You need to be on the same network as the child's phone"),
            actions: <Widget>[
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                },
                child: const Text('Ok'),
              ),
            ],
          );
        },
      );
    }
    dprint("remoteServerIP: $_remoteServerIP");
  }

  void _onQRViewCreated(QRViewController controller) {
    this.controller = controller;
    controller.scannedDataStream.listen((scanData) {
      controller.pauseCamera();
      Navigator.pop(context, scanData.code);
    });
  }

  Future<void> _receiveStream() async {
    await _setRemoteServerIP();
  }

  _handleSdp(String sdpDescription) async {
    try {
      RTCSessionDescription description =
          RTCSessionDescription(sdpDescription, 'offer');
      await _peerConnection.setRemoteDescription(description);
      RTCSessionDescription answer =
          await _peerConnection.createAnswer({'offerToReceiveVideo': 1});
      await _peerConnection.setLocalDescription(answer);
      await _sendAnswerToServer(answer.sdp!);
    } catch (e) {
      dprint('Error handling incoming call: $e');
    }
  }

  // parents
  Future<void> _sendAnswerToServer(String sdp) async {
    var uri = 'http://$_remoteServerIP:$_serverPort/answer';
    try {
      var response = await http.post(
        Uri.parse(uri),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'sdp': sdp}),
      );
      if (response.statusCode == 200) {
      } else {
        dprint('Failed to send answer to server: ${response.statusCode}');
      }
    } catch (e) {
      dprint('Error sending answer to server: $e');
    }
  }

  Future<void> _showQRCode() async {
    _shareServerIPviaQR();
  }

  Future<void> _scanQRCode() async {
    var data = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          body: Stack(
            children: <Widget>[
              QRView(
                key: qrKey,
                onQRViewCreated: _onQRViewCreated,
              ),
              Center(
                child: Container(
                  height: 200,
                  width: 200,
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: Colors.white.withOpacity(0.5), width: 2),
                  ),
                ),
              ),
              Positioned(
                top: 50,
                left: 0,
                right: 0,
                child: Center(
                  child: Text(
                    "Scan QR code please on Baby's device",
                    style: TextStyle(
                        fontSize: 20, color: Colors.white.withOpacity(0.5)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    _remoteServerIP = decompress(data);
    if (_remoteServerIP == null) {
      // Send message to user - Wrong scan
      return;
    }
    setState(() {});
    saveToStorage('serverIP', _remoteServerIP!);
  }

  Future<void> _toggleCamera() async {
    await _localStream.getVideoTracks()[0].stop();

    final Map<String, dynamic> constraints = {
      'audio': true,
      'video': {
        'mandatory': {
          'minWidth': '720',
          'minHeight': '405',
          'minFrameRate': '30',
        },
        'facingMode': _isFrontCamera ? 'environment' : 'user',
        'optional': [],
      }
    };

    _localStream = await navigator.mediaDevices.getUserMedia(constraints);
    _localRenderer.srcObject = _localStream;

    _broadcastStream();
    _isFrontCamera = !_isFrontCamera;

    await _setParamsToServer(
        _localServerIP!, _serverPort, 'isFrontCamera', _isFrontCamera);
  }

  Future<void> _toggleAudio() async {
    if (_remoteRenderer.srcObject != null) {
      List<MediaStreamTrack> audioTracks =
          _remoteRenderer.srcObject!.getAudioTracks();
      for (MediaStreamTrack track in audioTracks) {
        track.enabled = _isMuted;
      }
      _isMuted = !_isMuted;
      setState(() {});
    }
  }

  Future<void> _setParamsToServer(
      String ip, String port, String key, dynamic val) async {
    var uri = 'http://$ip:$port/set-params';
    try {
      final response = await http.post(
        Uri.parse(uri),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({key: val.toString()}),
      );
      if (response.statusCode != 200) {
        dprint('Failed to send params: ${response.statusCode}');
      }
    } catch (e) {
      dprint('Error sending params: $e');
    }
  }

  Future<Map<String, String>> _getParamsFromServer(
      String ip, String port) async {
    try {
      var uri = 'http://$ip:$port/get-params';
      final response = await http.get(Uri.parse(uri));
      if (response.statusCode == 200) {
        var data = json.decode(response.body);
        return Map<String, String>.from(data);
      }
    } catch (e) {
      dprint('Failed to check server: $e');
    }
    return {};
  }

  void processCommandsFunctionClient(List<String> commands) {
    for (var command in commands) {
      switch (command) {
        case 'sdp-to-client':
          _commandSdp();
          break;
        case 'ice-candidate-to-client':
          _commandIceCandidate();
          break;
        case 'params-to-client':
          _commandParams();
          break;
      }
    }
  }

  void processCommandsFunctionBroadcaster(List<String> commands) {
    for (var command in commands) {
      switch (command) {
        case 'answer-to-broadcaster':
          _commandAnswer();
          break;
        case 'params-to-broadcaster':
          _commandParams();
          break;
      }
    }
  }

  Future<void> _commandSdp() async {
    try {
      var uri = 'http://$_remoteServerIP:$_serverPort/get-sdp';
      final response = await http.get(Uri.parse(uri));
      if (response.statusCode == 200) {
        var data = json.decode(response.body);
        var sdp = data['sdp'] as String;
        _handleSdp(sdp);
      } else {
        dprint('Failed to load SDP: ${response.statusCode}');
      }
    } catch (e) {
      dprint('Failed to load SDP: $e');
    }
  }

  Future<void> _commandAnswer() async {
    var uri = 'http://$_localServerIP:$_serverPort/check-answer';
    try {
      for (int i = 0; i < 120; i++) {
        var response = await http.get(Uri.parse(uri));
        if (response.statusCode == 200 && response.body.isNotEmpty) {
          var data = json.decode(response.body);
          var sdp = data['sdp'] as String;
          _handleAnswer(sdp);
          break;
        } else {
          await Future.delayed(const Duration(seconds: 1));
        }
      }
    } catch (e) {
      dprint('Error getting answer from server: $e');
    }
  }

  Future<void> _commandIceCandidate() async {
    var uri = 'http://$_remoteServerIP:$_serverPort/check-ice-candidate';
    try {
      for (int i = 0; i < 30; i++) {
        final response = await http.get(Uri.parse(uri));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          for (var candidateItem in data) {
            final candidateMap = jsonDecode(candidateItem);
            final candidate = RTCIceCandidate(
              candidateMap['candidate'],
              candidateMap['sdpMid'],
              candidateMap['sdpMLineIndex'],
            );
            handleRemoteIceCandidate(candidate);
          }
        } else {
          dprint(
              'Failed to fetch remote ICE candidate. HTTP status: ${response.statusCode}');
        }
        await Future.delayed(const Duration(seconds: 1));
      }
    } catch (e) {
      dprint('Failed to fetch remote ICE candidate: $e');
    }
  }

  Future<void> _commandParams() async {
    String? serverIP;
    if (widget.isBroadcaster) {
      serverIP = _localServerIP;
    } else {
      serverIP = _remoteServerIP;
    }
    _params = await _getParamsFromServer(serverIP!, _serverPort);

    _isFrontCamera = _params['isFrontCamera']!.toLowerCase() == 'true';
    setState(() {});
  }

  @override
  void dispose() {
    if (widget.isBroadcaster) {
      _signalServer.stop();
    }
    _commandHandler.stop();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _peerConnection.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> buttons = [];
    if (widget.isBroadcaster) {
      buttons = [
        ElevatedButton(
          onPressed: _showQRCode,
          child: const Padding(
            padding: EdgeInsets.all(10.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.qr_code_rounded,
                  size: 50.0,
                ),
                Text('Connect via QR'),
              ],
            ),
          ),
        ),
        ElevatedButton(
          onPressed: _toggleCamera,
          child: const Padding(
            padding: EdgeInsets.all(10.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.switch_camera_rounded,
                  size: 50.0,
                ),
                Text('Toggle Camera'),
              ],
            ),
          ),
        ),
      ];
    } else {
      buttons = [
        ElevatedButton(
          onPressed: _scanQRCode,
          child: const Padding(
            padding: EdgeInsets.all(10.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.qr_code_rounded,
                  size: 50.0,
                ),
                Text('Scan QR'),
              ],
            ),
          ),
        ),
        ElevatedButton(
          onPressed: _toggleAudio,
          child: Padding(
            padding: const EdgeInsets.all(10.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                  size: 50.0,
                ),
                Text(_isMuted ? 'Unmute' : 'Mute'),
              ],
            ),
          ),
        ),
      ];
    }
    return Scaffold(
      appBar: null,
      body: FutureBuilder<void>(
        future: _initializationFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return SingleChildScrollView(
              child: Column(
                children: [
                  const SizedBox(height: 35.0),
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.85,
                    child: widget.isBroadcaster
                        ? RTCVideoView(
                            _localRenderer,
                            mirror: _isFrontCamera ? true : false,
                          )
                        : RTCVideoView(
                            _remoteRenderer,
                            mirror: _isFrontCamera ? true : false,
                          ),
                  ),
                  //const SizedBox(height: 5.0),
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.3,
                    child: GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        childAspectRatio: 2,
                        crossAxisSpacing: 10.0,
                        mainAxisSpacing: 10.0,
                      ),
                      itemBuilder: (BuildContext context, int index) {
                        return buttons[index];
                      },
                      itemCount: buttons.length, // The number of buttons
                    ),
                  ),
                ],
              ),
            );
          } else if (snapshot.hasError) {
            return const Center(child: Text('Error initializing camera'));
          } else {
            return const Center(child: CircularProgressIndicator());
          }
        },
      ),
    );
  }
}
