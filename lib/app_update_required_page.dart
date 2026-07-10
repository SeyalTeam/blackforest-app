import 'package:flutter/material.dart';
import 'package:blackforest_app/app_version.dart';

/// Full-screen page shown when the server blocks this app version.
/// The user cannot navigate away — they must update the app.
class AppUpdateRequiredPage extends StatelessWidget {
  final String message;

  const AppUpdateRequiredPage({
    super.key,
    this.message =
        'This version of the app is no longer supported. Please update to continue.',
  });

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // prevent back button
      child: Scaffold(
        backgroundColor: const Color(0xFF1A1A2E),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Icon
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      color: const Color(0xFF16213E),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: const Color(0xFFE94560),
                        width: 2,
                      ),
                    ),
                    child: const Icon(
                      Icons.system_update_alt_rounded,
                      size: 52,
                      color: Color(0xFFE94560),
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Title
                  const Text(
                    'Update Required',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                    textAlign: TextAlign.center,
                  ),

                  const SizedBox(height: 16),

                  // Message from server
                  Text(
                    message,
                    style: const TextStyle(
                      color: Color(0xFFB0B0C0),
                      fontSize: 15,
                      height: 1.6,
                    ),
                    textAlign: TextAlign.center,
                  ),

                  const SizedBox(height: 40),

                  // Divider line
                  Container(
                    height: 1,
                    color: const Color(0xFF2A2A4A),
                  ),

                  const SizedBox(height: 24),

                  // Current version info
                  Text(
                    'Current version: ${AppVersion.current.isEmpty ? 'unknown' : AppVersion.current}',
                    style: const TextStyle(
                      color: Color(0xFF606080),
                      fontSize: 13,
                    ),
                  ),

                  const SizedBox(height: 8),

                  const Text(
                    'Please ask your administrator for the latest version of the app.',
                    style: TextStyle(
                      color: Color(0xFF606080),
                      fontSize: 13,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
