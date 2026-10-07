import 'dart:math';

import 'package:flutter/material.dart';
import 'package:document_editor/src/chat/chat_controller.dart';
import 'package:document_editor/src/ui/agent_chat_pane.dart';
import 'package:document_editor/src/ui/document_view_pane.dart';
import 'package:document_editor/src/ui/expand_chat_button.dart';

/// Minimum window width at which both panes fit side-by-side.
const double kSideBySideMinWidth = 1024;

/// Preferred width of the chat pane in the side-by-side layout.
const double kChatPaneWidth = 360;

/// Root layout for the app.
///
/// On wide windows (>= [kSideBySideMinWidth]) the document viewer and agent
/// chat sit side-by-side. On narrower windows the chat pane collapses and a
/// floating button appears that overlays the chat on top of the document.
class MainLayout extends StatefulWidget {
  const MainLayout({super.key, required this.chat});

  /// Chat state shared by both chat pane layouts.
  final ChatController chat;

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> {
  bool _chatOverlayVisible = false;

  void _showChatOverlay() {
    setState(() => _chatOverlayVisible = true);
  }

  void _hideChatOverlay() {
    setState(() => _chatOverlayVisible = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= kSideBySideMinWidth;

          if (isWide) {
            return Row(
              children: [
                const Expanded(
                  flex: 3,
                  child: DocumentViewPane(),
                ),
                const VerticalDivider(width: 1),
                SizedBox(
                  width: kChatPaneWidth,
                  child: AgentChatPane(chat: widget.chat),
                ),
              ],
            );
          }

          // Narrow layout: document fills the screen, chat overlays it.
          return Stack(
            children: [
              const Positioned.fill(child: DocumentViewPane()),
              if (_chatOverlayVisible)
                Positioned(
                  top: 12,
                  right: 12,
                  bottom: 12,
                  width: min(constraints.maxWidth - 24, kChatPaneWidth),
                  child: AgentChatPane(
                    chat: widget.chat,
                    onClose: _hideChatOverlay,
                  ),
                ),
              // Hidden (not just disabled) while the overlay is open: a
              // disabled button would still absorb taps aimed at the chat
              // input behind it.
              if (!_chatOverlayVisible)
                Positioned(
                  bottom: 20,
                  right: 20,
                  child: ExpandChatButton(
                    onPressed: _showChatOverlay,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
