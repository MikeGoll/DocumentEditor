import 'dart:math';

import 'package:flutter/material.dart';
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
  const MainLayout({super.key});

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
            return const Row(
              children: [
                Expanded(
                  flex: 3,
                  child: DocumentViewPane(),
                ),
                VerticalDivider(width: 1),
                SizedBox(
                  width: kChatPaneWidth,
                  child: AgentChatPane(),
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
                    onClose: _hideChatOverlay,
                  ),
                ),
              Positioned(
                bottom: 20,
                right: 20,
                child: ExpandChatButton(
                  onPressed: _chatOverlayVisible ? null : _showChatOverlay,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
