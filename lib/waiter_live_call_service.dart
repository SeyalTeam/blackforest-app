import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'global_kot_realtime_service.dart';
import 'notification_service.dart';
import 'waiter_call_history_service.dart';
import 'waiter_live_call_screen.dart';

enum WaiterCallState {
  idle,
  connecting,
  ringing,
  connected,
  ended,
  declined,
  busy,
  offline,
  error,
}

class WaiterLiveCallService extends ChangeNotifier {
  static final WaiterLiveCallService instance = WaiterLiveCallService._internal();
  WaiterLiveCallService._internal();

  GlobalKey<NavigatorState>? _navigatorKey;
  StreamSubscription? _signalSub;
  final AudioPlayer _ringtonePlayer = AudioPlayer();
  Timer? _autoCleanupTimer;

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  WaiterCallState _callState = WaiterCallState.idle;
  WaiterCallState get callState => _callState;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  String? _currentCallId;
  String? get currentCallId => _currentCallId;

  String? _callerUserId;
  String? get callerUserId => _callerUserId;

  String _callerName = 'Admin';
  String get callerName => _callerName;

  dynamic _pendingOfferSdp;

  bool _isMuted = false;
  bool get isMuted => _isMuted;

  bool _isSpeakerOn = false;
  bool get isSpeakerOn => _isSpeakerOn;

  bool _isOutgoing = false;
  bool get isOutgoing => _isOutgoing;

  Timer? _durationTimer;
  int _durationSeconds = 0;
  int get durationSeconds => _durationSeconds;

  String get formattedDuration {
    final minutes = (_durationSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (_durationSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  final Map<String, dynamic> _iceConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  void init(GlobalKey<NavigatorState> navigatorKey) {
    _navigatorKey = navigatorKey;
    _signalSub?.cancel();
    _signalSub = GlobalKotRealtimeService.instance.onCallSignal.listen(
      _handleCallSignal,
      onError: (err) {
        debugPrint('WaiterLiveCallService: signal stream error: $err');
      },
    );
  }

  Future<void> _handleCallSignal(Map<String, dynamic> message) async {
    final prefs = await SharedPreferences.getInstance();
    final role = (prefs.getString('role') ?? prefs.getString('userRole') ?? '').trim().toLowerCase();
    final myUserId = (prefs.getString('user_id') ?? prefs.getString('userId') ?? prefs.getString('employee_id') ?? '').trim();
    debugPrint('WaiterLiveCallService: signal received: $message (myRole: $role, myUserId: $myUserId)');

    final signalType = message['signalType']?.toString();
    final callId = message['callId']?.toString();
    final senderId = message['senderId']?.toString();
    final senderName = message['senderName']?.toString() ?? message['callerName']?.toString() ?? 'Admin';
    final senderRole = message['senderRole']?.toString() ?? message['callerRole']?.toString() ?? 'Super Admin';

    // Discard signals not intended for us
    final targetUserId = (message['targetUserId'] ?? message['recipientUserId'])?.toString().trim();
    if (targetUserId != null && targetUserId.isNotEmpty && myUserId.isNotEmpty && targetUserId != myUserId) {
      debugPrint('WaiterLiveCallService: targetUserId ($targetUserId) != myUserId ($myUserId), ignoring');
      return;
    }

    if (signalType == 'offer') {
      if (_callState != WaiterCallState.idle) {
        // Already on a call, respond busy
        if (senderId != null) {
          GlobalKotRealtimeService.instance.sendJsonMessage({
            'action': 'call_signal',
            'callId': callId,
            'signalType': 'busy',
            'targetUserId': senderId,
          });
        }
        return;
      }

      _autoCleanupTimer?.cancel();
      _isOutgoing = false;
      _currentCallId = callId;
      _callerUserId = senderId;
      _callerName = senderName;
      _pendingOfferSdp = message['sdp'];
      _callState = WaiterCallState.ringing;
      _errorMessage = null;
      _durationSeconds = 0;
      _isMuted = false;
      _isSpeakerOn = false;
      notifyListeners();

      // Notify admin that waiter's device is ringing
      if (senderId != null) {
        GlobalKotRealtimeService.instance.sendJsonMessage({
          'action': 'call_signal',
          'callId': callId,
          'signalType': 'ringing',
          'targetUserId': senderId,
        });
      }

      // Play looping ringtone
      await _startRingtone();

      // Send local notification in case app is in background
      try {
        await NotificationService().showNotification(
          id: 9991,
          title: 'Incoming Call from $senderName',
          body: 'Admin is calling you live. Tap to answer.',
          payload: 'call_incoming',
        );
      } catch (_) {}

      // Record incoming voice call in permanent call history
      unawaited(WaiterCallHistoryService.recordVoiceCall(
        callId: callId ?? 'call_${DateTime.now().millisecondsSinceEpoch}',
        callerName: senderName,
        callerRole: senderRole,
        callerUserId: senderId,
        status: 'missed',
      ));

      // Open Waiter Live Call Screen directly (Full screen UI matching Admin app)
      _showIncomingCallScreen();
    } else if (signalType == 'ringing') {
      if (_currentCallId == callId && _callState == WaiterCallState.connecting) {
        _callState = WaiterCallState.ringing;
        notifyListeners();
      }
    } else if (signalType == 'answer') {
      if (_currentCallId == callId) {
        await _handleRemoteAnswer(message['sdp']);
      }
    } else if (signalType == 'ice_candidate') {
      if (_currentCallId == callId) {
        await _handleRemoteIceCandidate(message['candidate']);
      }
    } else if (signalType == 'reject') {
      if (_currentCallId == callId || _callState != WaiterCallState.idle) {
        await _stopRingtone();
        _callState = WaiterCallState.declined;
        _errorMessage = 'Call declined by Admin';
        notifyListeners();
        if (_currentCallId != null) {
          unawaited(WaiterCallHistoryService.updateVoiceCallStatus(
            callId: _currentCallId!,
            status: 'declined',
          ));
        }
        _scheduleAutoCleanup();
      }
    } else if (signalType == 'busy') {
      if (_currentCallId == callId || _callState != WaiterCallState.idle) {
        await _stopRingtone();
        _callState = WaiterCallState.busy;
        _errorMessage = 'Admin line is busy';
        notifyListeners();
        if (_currentCallId != null) {
          unawaited(WaiterCallHistoryService.updateVoiceCallStatus(
            callId: _currentCallId!,
            status: 'missed',
          ));
        }
        _scheduleAutoCleanup();
      }
    } else if (signalType == 'user_offline') {
      if (_isOutgoing && (_currentCallId == callId || _callState == WaiterCallState.connecting || _callState == WaiterCallState.ringing)) {
        await _stopRingtone();
        _callState = WaiterCallState.offline;
        _errorMessage = 'Super Admin is currently offline';
        notifyListeners();
        if (_currentCallId != null) {
          unawaited(WaiterCallHistoryService.updateVoiceCallStatus(
            callId: _currentCallId!,
            status: 'missed',
          ));
        }
        _scheduleAutoCleanup();
      }
    } else if (signalType == 'end') {
      if (_currentCallId == callId || _callState != WaiterCallState.idle) {
        await _stopRingtone();
        final wasConnected = _durationSeconds > 0;
        _callState = WaiterCallState.ended;
        _errorMessage = 'Call ended';
        notifyListeners();
        if (_currentCallId != null) {
          unawaited(WaiterCallHistoryService.updateVoiceCallStatus(
            callId: _currentCallId!,
            status: wasConnected ? 'accepted' : 'missed',
            durationSeconds: _durationSeconds,
          ));
        }
        _scheduleAutoCleanup();
      }
    }
  }

  Future<void> _startRingtone() async {
    try {
      await _ringtonePlayer.setReleaseMode(ReleaseMode.loop);
      await _ringtonePlayer.play(AssetSource('sounds/table.mp3'));
    } catch (e) {
      debugPrint('WaiterLiveCallService: error playing ringtone: $e');
    }
  }

  Future<void> _stopRingtone() async {
    try {
      await _ringtonePlayer.stop();
      await _ringtonePlayer.release();
    } catch (_) {}
  }

  void _showIncomingCallScreen() {
    void push() {
      final context = _navigatorKey?.currentContext;
      if (context == null) {
        debugPrint('WaiterLiveCallService: context is null, retrying incoming screen in 200ms...');
        Future.delayed(const Duration(milliseconds: 200), () {
          if (_callState == WaiterCallState.ringing) {
            _showIncomingCallScreen();
          }
        });
        return;
      }

      // Check if already on the call screen
      bool isAlreadyOnScreen = false;
      Navigator.of(context).popUntil((route) {
        if (route.settings.name == 'waiter_live_call_screen') {
          isAlreadyOnScreen = true;
        }
        return true;
      });

      if (!isAlreadyOnScreen) {
        _navigatorKey?.currentState?.push(
          MaterialPageRoute(
            settings: const RouteSettings(name: 'waiter_live_call_screen'),
            builder: (ctx) => WaiterLiveCallScreen(callerName: _callerName),
          ),
        );
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => push());
  }

  Future<void> acceptCall() async {
    await _stopRingtone();

    // Request microphone permission
    final micStatus = await Permission.microphone.request();
    if (micStatus.isDenied || micStatus.isPermanentlyDenied) {
      declineCall();
      return;
    }

    _callState = WaiterCallState.connecting;
    _isSpeakerOn = false;
    notifyListeners();

    try {
      // Default audio output to ear speaker (earpiece)
      await Helper.setSpeakerphoneOn(false);

      _peerConnection = await createPeerConnection(_iceConfig);

      final constraints = <String, dynamic>{
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false,
      };

      _localStream = await navigator.mediaDevices.getUserMedia(constraints);
      for (final track in _localStream!.getAudioTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }

      _peerConnection!.onIceCandidate = (candidate) {
        if (candidate.candidate != null && _callerUserId != null) {
          GlobalKotRealtimeService.instance.sendJsonMessage({
            'action': 'call_signal',
            'callId': _currentCallId,
            'signalType': 'ice_candidate',
            'targetUserId': _callerUserId,
            'candidate': {
              'candidate': candidate.candidate,
              'sdpMid': candidate.sdpMid,
              'sdpMLineIndex': candidate.sdpMLineIndex,
            },
          });
        }
      };

      _peerConnection!.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams[0];
          _applyAudioRouting();
          notifyListeners();
        }
      };

      _peerConnection!.onConnectionState = (state) {
        debugPrint('WaiterLiveCallService: connection state: $state');
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _onConnected();
        } else if (state ==
                RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          if (_callState == WaiterCallState.connected) {
            endCall();
          }
        }
      };

      // Set remote offer
      if (_pendingOfferSdp != null) {
        final sdpMap = _pendingOfferSdp is Map
            ? Map<String, dynamic>.from(_pendingOfferSdp)
            : jsonDecode(_pendingOfferSdp.toString());
        final description = RTCSessionDescription(
          sdpMap['sdp']?.toString() ?? '',
          sdpMap['type']?.toString() ?? 'offer',
        );
        await _peerConnection!.setRemoteDescription(description);
      }

      // Create answer
      final answer = await _peerConnection!.createAnswer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': 0,
      });
      await _peerConnection!.setLocalDescription(answer);

      // Send answer to admin
      final prefs = await SharedPreferences.getInstance();
      final myName = prefs.getString('user_name') ?? 'Waiter';

      GlobalKotRealtimeService.instance.sendJsonMessage({
        'action': 'call_signal',
        'callId': _currentCallId,
        'signalType': 'answer',
        'targetUserId': _callerUserId,
        'sdp': answer.toMap(),
        'callerName': myName,
        'callerRole': 'waiter',
      });

      _onConnected();
    } catch (e) {
      debugPrint('WaiterLiveCallService: error accepting call: $e');
      await declineCall();
    }
  }

  Future<void> _handleRemoteIceCandidate(dynamic candidateData) async {
    if (_peerConnection == null || candidateData == null) return;
    try {
      final cMap = candidateData is Map
          ? Map<String, dynamic>.from(candidateData)
          : jsonDecode(candidateData.toString());
      final candidate = RTCIceCandidate(
        cMap['candidate']?.toString(),
        cMap['sdpMid']?.toString(),
        cMap['sdpMLineIndex'] as int?,
      );
      await _peerConnection!.addCandidate(candidate);
    } catch (e) {
      debugPrint('WaiterLiveCallService: error adding ice candidate: $e');
    }
  }

  Future<void> _handleRemoteAnswer(dynamic sdpData) async {
    if (_peerConnection == null || sdpData == null) return;
    try {
      final sdpMap = sdpData is Map
          ? Map<String, dynamic>.from(sdpData)
          : jsonDecode(sdpData.toString());
      final description = RTCSessionDescription(
        sdpMap['sdp']?.toString() ?? '',
        sdpMap['type']?.toString() ?? 'answer',
      );
      await _peerConnection!.setRemoteDescription(description);
      _onConnected();
    } catch (e) {
      debugPrint('WaiterLiveCallService: error setting remote answer: $e');
    }
  }

  Future<void> startCallToAdmin({
    required String adminUserId,
    String adminName = 'Super Admin',
  }) async {
    if (_callState != WaiterCallState.idle) return;

    final prefs = await SharedPreferences.getInstance();
    final myUserId = (prefs.getString('user_id') ?? prefs.getString('userId'))?.trim() ?? '';

    // Safety: ensure waiter never calls himself
    if (adminUserId.isEmpty || adminUserId == myUserId) {
      final resolvedId = await WaiterCallHistoryService.getLastAdminUserId();
      if (resolvedId != null && resolvedId.isNotEmpty && resolvedId != myUserId) {
        adminUserId = resolvedId;
      } else {
        debugPrint('WaiterLiveCallService: Cannot call admin - target ID matches myUserId or is invalid');
        throw Exception('Admin contact is unavailable. Please try again later.');
      }
    }

    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      debugPrint('WaiterLiveCallService: microphone permission denied');
      return;
    }

    final myName = prefs.getString('user_name') ??
        prefs.getString('name') ??
        prefs.getString('email') ??
        'Waiter';

    _autoCleanupTimer?.cancel();
    _isOutgoing = true;
    _currentCallId = 'call_${DateTime.now().millisecondsSinceEpoch}';
    _callerUserId = adminUserId;
    _callerName = adminName;
    _callState = WaiterCallState.connecting;
    _errorMessage = null;
    _durationSeconds = 0;
    _isMuted = false;
    _isSpeakerOn = false;
    notifyListeners();

    // Show call screen immediately
    _showIncomingCallScreen();

    // Record outgoing call in history
    unawaited(WaiterCallHistoryService.recordVoiceCall(
      callId: _currentCallId!,
      callerName: adminName,
      callerRole: 'Super Admin',
      callerUserId: adminUserId,
      status: 'missed',
      direction: 'outgoing',
    ));

    try {
      await Helper.setSpeakerphoneOn(false);

      _peerConnection = await createPeerConnection(_iceConfig);

      final constraints = <String, dynamic>{
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false,
      };

      _localStream = await navigator.mediaDevices.getUserMedia(constraints);
      for (final track in _localStream!.getAudioTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }

      _peerConnection!.onIceCandidate = (candidate) {
        if (candidate.candidate != null) {
          GlobalKotRealtimeService.instance.sendJsonMessage({
            'action': 'call_signal',
            'callId': _currentCallId,
            'signalType': 'ice_candidate',
            'targetUserId': adminUserId,
            'candidate': candidate.toMap(),
          });
        }
      };

      _peerConnection!.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams[0];
          _applyAudioRouting();
          notifyListeners();
        }
      };

      _peerConnection!.onConnectionState = (state) {
        debugPrint('WaiterLiveCallService: connection state: $state');
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _onConnected();
        } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          if (_callState == WaiterCallState.connected) {
            endCall();
          }
        }
      };

      final offer = await _peerConnection!.createOffer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': 0,
      });
      await _peerConnection!.setLocalDescription(offer);

      GlobalKotRealtimeService.instance.sendJsonMessage({
        'action': 'call_signal',
        'callId': _currentCallId,
        'signalType': 'offer',
        'targetUserId': adminUserId,
        'sdp': offer.toMap(),
        'callerName': myName,
        'callerRole': 'waiter',
      });
    } catch (e) {
      debugPrint('WaiterLiveCallService: error starting call to admin: $e');
      _callState = WaiterCallState.error;
      _errorMessage = 'Call failed to connect';
      notifyListeners();
      _scheduleAutoCleanup();
    }
  }

  void _onConnected() {
    if (_callState == WaiterCallState.connected) return;
    _callState = WaiterCallState.connected;
    _errorMessage = null;
    _isSpeakerOn = false;
    _durationSeconds = 0;
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _durationSeconds++;
      notifyListeners();
    });

    if (_currentCallId != null) {
      unawaited(WaiterCallHistoryService.updateVoiceCallStatus(
        callId: _currentCallId!,
        status: 'accepted',
      ));
    }

    _applyAudioRouting();
    notifyListeners();
  }

  Future<void> _applyAudioRouting() async {
    try {
      await Helper.setSpeakerphoneOn(_isSpeakerOn);
      Future.delayed(const Duration(milliseconds: 300), () async {
        try {
          await Helper.setSpeakerphoneOn(_isSpeakerOn);
        } catch (_) {}
      });
      Future.delayed(const Duration(milliseconds: 800), () async {
        try {
          await Helper.setSpeakerphoneOn(_isSpeakerOn);
        } catch (_) {}
      });
    } catch (e) {
      debugPrint('WaiterLiveCallService: _applyAudioRouting error: $e');
    }
  }

  Future<void> declineCall() async {
    await _stopRingtone();
    if (_callerUserId != null && _currentCallId != null) {
      GlobalKotRealtimeService.instance.sendJsonMessage({
        'action': 'call_signal',
        'callId': _currentCallId,
        'signalType': 'reject',
        'targetUserId': _callerUserId,
        'reason': 'declined',
      });
      unawaited(WaiterCallHistoryService.updateVoiceCallStatus(
        callId: _currentCallId!,
        status: 'declined',
      ));
    }
    _callState = WaiterCallState.declined;
    _errorMessage = 'Call declined';
    notifyListeners();
    await _cleanupWebrtc();
    _popScreenImmediately();
  }

  Future<void> endCall() async {
    await _stopRingtone();
    if (_callerUserId != null && _currentCallId != null) {
      GlobalKotRealtimeService.instance.sendJsonMessage({
        'action': 'call_signal',
        'callId': _currentCallId,
        'signalType': 'end',
        'targetUserId': _callerUserId,
      });
    }
    if (_currentCallId != null) {
      unawaited(WaiterCallHistoryService.updateVoiceCallStatus(
        callId: _currentCallId!,
        status: _durationSeconds > 0 ? 'accepted' : 'missed',
        durationSeconds: _durationSeconds,
      ));
    }
    _callState = WaiterCallState.ended;
    _errorMessage = 'Call ended';
    notifyListeners();
    await _cleanupWebrtc();
    _popScreenImmediately();
  }

  void _popScreenImmediately() {
    _navigatorKey?.currentState?.popUntil((route) {
      return route.settings.name != 'waiter_live_call_screen' &&
          route.settings.name != 'incoming_call_dialog';
    });
  }

  void _scheduleAutoCleanup({Duration delay = const Duration(milliseconds: 2800)}) {
    _autoCleanupTimer?.cancel();
    _autoCleanupTimer = Timer(delay, () async {
      await _cleanupWebrtc();
      _popScreenImmediately();
    });
  }

  Future<void> toggleMute() async {
    if (_localStream == null) return;
    _isMuted = !_isMuted;
    for (final track in _localStream!.getAudioTracks()) {
      track.enabled = !_isMuted;
    }
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    _isSpeakerOn = !_isSpeakerOn;
    try {
      await Helper.setSpeakerphoneOn(_isSpeakerOn);
      debugPrint('WaiterLiveCallService: speakerphone toggled to $_isSpeakerOn');
    } catch (e) {
      debugPrint('WaiterLiveCallService: setSpeakerphoneOn error: $e');
    }
    notifyListeners();
  }

  Future<void> _cleanupWebrtc() async {
    _autoCleanupTimer?.cancel();
    _autoCleanupTimer = null;
    _durationTimer?.cancel();
    _durationTimer = null;

    try {
      await Helper.setSpeakerphoneOn(false);
    } catch (_) {}

    try {
      _localStream?.getTracks().forEach((track) => track.stop());
      await _localStream?.dispose();
    } catch (_) {}
    _localStream = null;

    try {
      _remoteStream?.getTracks().forEach((track) => track.stop());
      await _remoteStream?.dispose();
    } catch (_) {}
    _remoteStream = null;

    try {
      await _peerConnection?.close();
      await _peerConnection?.dispose();
    } catch (_) {}
    _peerConnection = null;

    _callState = WaiterCallState.idle;
    _currentCallId = null;
    _callerUserId = null;
    _pendingOfferSdp = null;
    _errorMessage = null;
    notifyListeners();
  }
}
