import 'package:flutter/material.dart';
import 'package:venera_next/features/comic_source/mirror_probe.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

/// Probe every candidate of [group] and let the user pick one.
///
/// Returns the chosen URL, or null when the user backs out. The caller is
/// responsible for persisting the value and reloading the source.
Future<String?> showMirrorProbeDialog(
  BuildContext context, {
  required MirrorSettingGroup group,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => MirrorProbeDialog(group: group),
  );
}

class MirrorProbeDialog extends StatefulWidget {
  const MirrorProbeDialog({super.key, required this.group});

  final MirrorSettingGroup group;

  @override
  State<MirrorProbeDialog> createState() => _MirrorProbeDialogState();
}

class _MirrorProbeDialogState extends State<MirrorProbeDialog> {
  List<MirrorProbeResult>? _results;
  bool _running = true;
  String? _selected;
  String? _error;
  DateTime? _measuredAt;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final results = await MirrorProbe.probeAll(widget.group.candidates);
      if (!mounted) return;
      final sorted = _sorted(results);
      setState(() {
        _results = sorted;
        _running = false;
        _measuredAt = DateTime.now();
        _selected = _defaultSelection(sorted);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = '$error';
      });
    }
  }

  List<MirrorProbeResult> _sorted(List<MirrorProbeResult> results) {
    final copy = List<MirrorProbeResult>.from(results);
    copy.sort((a, b) {
      final byRank = _rank(a).compareTo(_rank(b));
      if (byRank != 0) return byRank;
      final left = a.latencyMs ?? 1 << 30;
      final right = b.latencyMs ?? 1 << 30;
      return left.compareTo(right);
    });
    return copy;
  }

  int _rank(MirrorProbeResult result) => switch (result.status) {
    MirrorStatus.ok => 0,
    MirrorStatus.blocked => 1,
    MirrorStatus.serverError => 2,
    MirrorStatus.unreachable => 3,
    MirrorStatus.invalid => 4,
  };

  /// Keep the mirror already in use when it still works, otherwise take the
  /// fastest one. Sorting already put the fastest usable mirror first.
  String? _defaultSelection(List<MirrorProbeResult> sorted) {
    final current = widget.group.current;
    if (current != null) {
      for (final result in sorted) {
        if (result.url == current && result.isUsable) return current;
      }
    }
    for (final result in sorted) {
      if (result.isUsable) return result.url;
    }
    return null;
  }

  MirrorProbeResult? get _selectedResult {
    final results = _results;
    final selected = _selected;
    if (results == null || selected == null) return null;
    for (final result in results) {
      if (result.url == selected) return result;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final results = _results;
    final changed = _selected != null && _selected != widget.group.current;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Mirror speed test'.tl,
                    style: ts.s18.bold,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${widget.group.sourceName} · ${widget.group.title.tl}',
                    style: ts.s12.withColor(colors.onSurfaceVariant),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Flexible(child: _buildBody(context, results)),
            _buildActions(context, changed),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, List<MirrorProbeResult>? results) {
    final colors = context.colorScheme;
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Text(
          _error!,
          style: ts.s14.withColor(colors.error),
        ),
      );
    }
    if (_running && results == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                'Testing @count mirrors…'.tlParams({
                  'count': '${widget.group.candidates.length}',
                }),
                style: ts.s14.withColor(colors.onSurfaceVariant),
              ),
            ),
          ],
        ),
      );
    }
    final list = results ?? const <MirrorProbeResult>[];
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: list.length,
      itemBuilder: (context, index) => _MirrorRow(
        result: list[index],
        selected: list[index].url == _selected,
        isCurrent: list[index].url == widget.group.current,
        onTap: list[index].isUsable
            ? () => setState(() => _selected = list[index].url)
            : null,
      ),
    );
  }

  Widget _buildActions(BuildContext context, bool changed) {
    final colors = context.colorScheme;
    final selected = _selectedResult;
    final measuredAt = _measuredAt;
    return Column(
      children: [
        if (measuredAt != null && !_running)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
            child: Row(
              children: [
                Icon(
                  Icons.schedule,
                  size: 12,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Measured at @time on the current network'.tlParams({
                      'time':
                          '${measuredAt.hour.toString().padLeft(2, '0')}:'
                          '${measuredAt.minute.toString().padLeft(2, '0')}',
                    }),
                    style: ts.s12.withColor(colors.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: _running ? null : _run,
                icon: _running
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
                label: Text('Test again'.tl),
              ),
              const Spacer(),
              FilledButton(
                onPressed: changed ? () => Navigator.of(context).pop(_selected) : null,
                child: Text(
                  selected == null
                      ? 'No usable mirror'.tl
                      : changed
                      ? 'Use @latency'.tlParams({
                          'latency': selected.latencyMs == null
                              ? selected.url
                              : '${selected.latencyMs}ms',
                        })
                      : 'Already in use'.tl,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MirrorRow extends StatelessWidget {
  const _MirrorRow({
    required this.result,
    required this.selected,
    required this.isCurrent,
    required this.onTap,
  });

  final MirrorProbeResult result;
  final bool selected;
  final bool isCurrent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final statusColor = _statusColor(context);
    final host = Uri.tryParse(result.url)?.host ?? result.url;

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? colors.primaryContainer.toOpacity(0.35) : null,
          border: Border(
            left: BorderSide(
              color: selected ? colors.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          host,
                          style: ts.s14,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isCurrent) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: colors.secondaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'In use'.tl,
                            style: ts.s10.withColor(
                              colors.onSecondaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    normalizeMirrorUrl(result.url) ?? result.url,
                    style: ts.s12.withColor(colors.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              _statusLabel(),
              style: ts.s14.withColor(statusColor),
            ),
            if (selected) ...[
              const SizedBox(width: 6),
              Icon(Icons.check, size: 16, color: colors.primary),
            ],
          ],
        ),
      ),
    );
  }

  String _statusLabel() {
    final latency = result.latencyMs;
    return switch (result.status) {
      MirrorStatus.ok => latency == null ? 'OK' : '${latency}ms',
      MirrorStatus.blocked =>
        '${result.statusCode ?? ''} ${'Mirror blocked'.tl}'.trim(),
      MirrorStatus.serverError =>
        '${result.statusCode ?? ''} ${'Server error'.tl}'.trim(),
      MirrorStatus.unreachable => 'Unreachable'.tl,
      MirrorStatus.invalid => 'Invalid'.tl,
    };
  }

  Color _statusColor(BuildContext context) {
    return switch (result.status) {
      MirrorStatus.ok => switch (result.bucket) {
        MirrorLatencyBucket.fast => context.useTextColor(Colors.green),
        MirrorLatencyBucket.normal => context.useTextColor(Colors.orange),
        MirrorLatencyBucket.slow => context.useTextColor(Colors.deepOrange),
        null => context.useTextColor(Colors.green),
      },
      MirrorStatus.blocked => context.useTextColor(Colors.orange),
      MirrorStatus.serverError => context.useTextColor(Colors.deepOrange),
      MirrorStatus.unreachable => context.colorScheme.error,
      MirrorStatus.invalid => context.colorScheme.outline,
    };
  }
}
