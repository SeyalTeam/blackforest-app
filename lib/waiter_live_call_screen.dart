import 'package:flutter/material.dart';
import 'waiter_live_call_service.dart';

class WaiterLiveCallScreen extends StatefulWidget {
  final String callerName;

  const WaiterLiveCallScreen({
    super.key,
    required this.callerName,
  });

  @override
  State<WaiterLiveCallScreen> createState() => _WaiterLiveCallScreenState();
}

class _WaiterLiveCallScreenState extends State<WaiterLiveCallScreen> {
  late final WaiterLiveCallService _callService;

  @override
  void initState() {
    super.initState();
    _callService = WaiterLiveCallService.instance;
    _callService.addListener(_handleCallStateChanged);
  }

  @override
  void dispose() {
    _callService.removeListener(_handleCallStateChanged);
    super.dispose();
  }

  void _handleCallStateChanged() {
    if (!mounted) return;
    setState(() {});
    if (_callService.callState == WaiterCallState.ended ||
        _callService.callState == WaiterCallState.idle) {
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldExit = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('End Live Call?'),
            content: const Text('Do you want to hang up this live call with Admin?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Stay'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('End Call', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        );
        if (shouldExit == true) {
          final nav = Navigator.of(context);
          await _callService.endCall();
          if (nav.canPop()) {
            nav.pop();
          }
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0F1A20),
        body: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 16),
              // Security badge
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.lock_outline, size: 14, color: Colors.white54),
                  SizedBox(width: 6),
                  Text(
                    'Live Audio Call • Blackforest Admin',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white54,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),

              // Caller Title
              Text(
                widget.callerName,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'SUPER ADMIN',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF25D366),
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 12),

              // Duration Timer
              Text(
                _callService.formattedDuration,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF25D366),
                  letterSpacing: 0.8,
                ),
              ),

              const Spacer(),

              // Center Avatar
              Container(
                width: 140,
                height: 140,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    colors: [Color(0xFF075E54), Color(0xFF128C7E)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF25D366).withOpacity(0.3),
                      blurRadius: 20,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: const Center(
                  child: Icon(
                    Icons.admin_panel_settings,
                    color: Colors.white,
                    size: 68,
                  ),
                ),
              ),

              const Spacer(),

              // Connected audio status badge
              Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: Color(0xFF25D366),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Live Audio Connected',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),

              // Call Controls Bar
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 20),
                decoration: BoxDecoration(
                  color: const Color(0xFF182229),
                  borderRadius: BorderRadius.circular(32),
                  border: Border.all(color: Colors.white10),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Speakerphone Toggle
                    _ControlCircleButton(
                      icon: _callService.isSpeakerOn
                          ? Icons.volume_up
                          : Icons.volume_down_outlined,
                      label: 'Speaker',
                      isActive: _callService.isSpeakerOn,
                      onTap: _callService.toggleSpeaker,
                    ),

                    // Mic Mute Toggle
                    _ControlCircleButton(
                      icon: _callService.isMuted ? Icons.mic_off : Icons.mic,
                      label: _callService.isMuted ? 'Muted' : 'Mute',
                      isActive: _callService.isMuted,
                      activeColor: Colors.amber,
                      onTap: _callService.toggleMute,
                    ),

                    // End Call Button
                    GestureDetector(
                      onTap: () async {
                        final nav = Navigator.of(context);
                        await _callService.endCall();
                        if (nav.canPop()) {
                          nav.pop();
                        }
                      },
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 58,
                            height: 58,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.redAccent,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.redAccent,
                                  blurRadius: 10,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.call_end,
                              color: Colors.white,
                              size: 28,
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'End',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white70,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _ControlCircleButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final Color activeColor;
  final VoidCallback onTap;

  const _ControlCircleButton({
    required this.icon,
    required this.label,
    this.isActive = false,
    this.activeColor = const Color(0xFF25D366),
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isActive
                  ? activeColor.withOpacity(0.2)
                  : Colors.white.withOpacity(0.08),
              border: Border.all(
                color: isActive ? activeColor : Colors.white24,
                width: 1.5,
              ),
            ),
            child: Icon(
              icon,
              color: isActive ? activeColor : Colors.white,
              size: 24,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.white70,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
