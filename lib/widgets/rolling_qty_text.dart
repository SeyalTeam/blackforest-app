import 'package:flutter/material.dart';

class RollingQtyText extends StatefulWidget {
  final double value;
  final TextStyle style;
  final double height;

  const RollingQtyText({
    super.key,
    required this.value,
    required this.style,
    required this.height,
  });

  @override
  State<RollingQtyText> createState() => _RollingQtyTextState();
}

class _RollingQtyTextState extends State<RollingQtyText> {
  int _direction = 1;

  @override
  void didUpdateWidget(covariant RollingQtyText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value > oldWidget.value) {
      _direction = 1;
    } else if (widget.value < oldWidget.value) {
      _direction = -1;
    }
  }

  String _formatQty(double qty) {
    if (qty == qty.floorToDouble()) {
      return qty.toInt().toString();
    }
    return qty.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    final text = _formatQty(widget.value);
    final incomingOffset = _direction > 0 ? 1.0 : -1.0;
    final outgoingOffset = _direction > 0 ? -1.0 : 1.0;

    return SizedBox(
      height: widget.height,
      child: ClipRect(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          reverseDuration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          layoutBuilder: (currentChild, previousChildren) {
            return Stack(
              alignment: Alignment.center,
              children: [
                ...previousChildren,
                if (currentChild != null) currentChild,
              ],
            );
          },
          transitionBuilder: (child, animation) {
            final isCurrent = child.key == ValueKey<String>(text);
            final position = Tween<Offset>(
              begin: isCurrent
                  ? Offset(0, incomingOffset)
                  : Offset(0, outgoingOffset),
              end: Offset.zero,
            ).animate(animation);

            return SlideTransition(
              position: position,
              child: FadeTransition(opacity: animation, child: child),
            );
          },
          child: Text(
            text,
            key: ValueKey<String>(text),
            maxLines: 1,
            style: widget.style,
          ),
        ),
      ),
    );
  }
}
