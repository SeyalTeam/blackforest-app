import 'package:flutter/material.dart';
import 'package:blackforest_app/common_scaffold.dart';

class ChatPage extends StatelessWidget {
  const ChatPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const CommonScaffold(
      title: 'Chat',
      pageType: PageType.chat,
      body: ColoredBox(color: Color(0xFFF8F9FA), child: SizedBox.expand()),
    );
  }
}
