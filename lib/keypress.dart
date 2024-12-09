import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';

class KeyPressListener extends StatefulWidget {
  final Widget child;
  final Function(KeyDownEvent) onKeyPress;
  final Duration repeatInterval;

  const KeyPressListener({
    super.key,
    required this.child,
    required this.onKeyPress,
    this.repeatInterval = const Duration(milliseconds: 50),  // Default repeat interval
  });

  @override
  State<KeyPressListener> createState() => _KeyPressListenerState();
}

class _KeyPressListenerState extends State<KeyPressListener> {
  FocusNode? _focusNode;
  Timer? _repeatTimer;
  Set<LogicalKeyboardKey> _pressedKeys = {};

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _stopTimer();
    _focusNode?.dispose();
    super.dispose();
  }

  void _startTimer(KeyDownEvent event) {
    _stopTimer();
    _repeatTimer = Timer.periodic(widget.repeatInterval, (_) {
      if (_pressedKeys.contains(event.logicalKey)) {
        widget.onKeyPress(event);
      } else {
        _stopTimer();
      }
    });
  }

  void _stopTimer() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
  }

  KeyEventResult _handleKeyPress(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      _pressedKeys.add(event.logicalKey);
      widget.onKeyPress(event);
      _startTimer(event);
      return KeyEventResult.handled;
    } 
    
    if (event is KeyUpEvent) {
      _pressedKeys.remove(event.logicalKey);
      if (_pressedKeys.isEmpty) {
        _stopTimer();
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyPress,
      child: widget.child,
      autofocus: true,
    );
  }
}