import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/features/comic_details/comic_details_cache.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/comic_source/mirror_probe.dart';
import 'package:venera_next/features/comic_source/mirror_probe_dialog.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

/// Sweeps every source that declares several mirror hosts and reports which
/// ones no longer answer.
///
/// This is a diagnostic page, never a background task: it only probes while the
/// user is looking at it, because probing every mirror costs real requests.
class MirrorHealthPage extends StatefulWidget {
  const MirrorHealthPage({super.key});

  @override
  State<MirrorHealthPage> createState() => _MirrorHealthPageState();
}

enum _GroupHealth { healthy, degraded, broken, pending }

class _MirrorHealthPageState extends State<MirrorHealthPage> {
  final Map<String, List<MirrorProbeResult>> _results = {};
  List<MirrorSettingGroup> _groups = const [];
  bool _scanning = false;
  int _scanned = 0;
  DateTime? _scannedAt;
  String? _error;
  bool _started = false;

  /// Resolved in [didChangeDependencies]: the inherited lookup is not available
  /// from [initState], and probing starts right after the first frame.
  ComicSourceManager? _managerRef;
  ComicSourceManager get _manager => _managerRef!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _managerRef = SourceInstallationsScope.ownerOf(context).queue.manager;
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scan();
    });
  }

  String _keyOf(MirrorSettingGroup group) =>
      '${group.sourceKey}\u0000${group.settingKey}';

  List<MirrorSettingGroup> _collect() {
    final groups = <MirrorSettingGroup>[];
    for (final source in _manager.all()) {
      groups.addAll(mirrorGroupsOf(source));
    }
    return groups;
  }

  Future<void> _scan() async {
    if (_scanning) return;
    if (!mounted) return;
    final groups = _collect();
    setState(() {
      _scanning = true;
      _groups = groups;
      _results.clear();
      _scanned = 0;
      _scannedAt = null;
      _error = null;
    });

    try {
      for (final group in groups) {
        final results = await MirrorProbe.probeAll(
          group.candidates,
          options: MirrorProbeOptions.sweep,
        );
        if (!mounted) return;
        setState(() {
          _results[_keyOf(group)] = results;
          _scanned++;
        });
      }
    } catch (error, stack) {
      Log.error('MirrorHealth', error, stack);
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) {
        setState(() {
          _scanning = false;
          _scannedAt = DateTime.now();
        });
      }
    }
  }

  _GroupHealth _healthOf(MirrorSettingGroup group) {
    final results = _results[_keyOf(group)];
    if (results == null) return _GroupHealth.pending;
    var anyUsable = false;
    for (final result in results) {
      if (result.isUsable) anyUsable = true;
    }
    if (!anyUsable) return _GroupHealth.broken;
    final current = group.currentOrFirst;
    for (final result in results) {
      if (result.url != current) continue;
      return result.isUsable ? _GroupHealth.healthy : _GroupHealth.degraded;
    }
    // The stored value is not one of the declared options, so nothing tells us
    // it still works.
    return _GroupHealth.degraded;
  }

  int _rankOf(_GroupHealth health) => switch (health) {
    _GroupHealth.broken => 0,
    _GroupHealth.degraded => 1,
    _GroupHealth.healthy => 2,
    _GroupHealth.pending => 3,
  };

  List<MirrorSettingGroup> get _sortedGroups {
    final list = List<MirrorSettingGroup>.from(_groups);
    list.sort((a, b) {
      final byHealth = _rankOf(_healthOf(a)).compareTo(_rankOf(_healthOf(b)));
      if (byHealth != 0) return byHealth;
      return a.sourceName.compareTo(b.sourceName);
    });
    return list;
  }

  int get _attentionCount => _groups
      .where((group) => _healthOf(group) != _GroupHealth.healthy)
      .length;

  Future<void> _open(MirrorSettingGroup group) async {
    final picked = await showMirrorProbeDialog(context, group: group);
    if (picked == null || picked == group.current) return;
    final source = _manager.find(group.sourceKey);
    if (source == null) return;
    try {
      final edit = source.prepareDataEdit((draft) {
        (draft['settings'] ??= <String, dynamic>{})[group.settingKey] = picked;
      });
      await edit.save();
      await ComicDetailsCache.instance.invalidateSource(source.key);
      await _manager.reload();
      if (!mounted) return;
      setState(() {
        _groups = _collect();
        _results.clear();
      });
      await _scan();
    } catch (error, stack) {
      Log.error('MirrorHealth', error, stack);
      if (mounted) {
        context.showMessage(message: 'Failed to reload sources'.tl);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text('Mirror health'.tl)),
        SliverToBoxAdapter(child: _buildSummary()),
        if (_groups.isEmpty && !_scanning)
          SliverToBoxAdapter(child: _buildEmpty())
        else
          SliverList.builder(
            itemCount: _sortedGroups.length,
            itemBuilder: (context, index) {
              final group = _sortedGroups[index];
              return _MirrorGroupTile(
                group: group,
                results: _results[_keyOf(group)],
                health: _healthOf(group),
                onOpen: _scanning ? null : () => _open(group),
              );
            },
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _buildSummary() {
    final colors = context.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Check every source's mirrors and find hosts that no longer answer."
                .tl,
            style: ts.s12.withColor(colors.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: _scanning ? null : _scan,
                icon: const Icon(Icons.speed, size: 18),
                label: Text(
                  _scanning
                      ? 'Scanning @count mirror groups…'.tlParams({
                          'count': '$_scanned/${_groups.length}',
                        })
                      : _scannedAt == null
                      ? 'Scan all mirrors'.tl
                      : 'Test again'.tl,
                ),
              ),
            ],
          ),
          if (_scanning) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: _groups.isEmpty ? null : _scanned / _groups.length,
            ),
          ],
          if (!_scanning && _groups.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              _attentionCount == 0
                  ? 'All mirror groups are usable'.tl
                  : '@count mirror groups need attention'.tlParams({
                      'count': '$_attentionCount',
                    }),
              style: ts.s14.withColor(
                _attentionCount == 0
                    ? context.useTextColor(Colors.green)
                    : context.useTextColor(Colors.orange),
              ),
            ),
          ],
          if (_scannedAt != null && !_scanning) ...[
            const SizedBox(height: 4),
            Text(
              'Last scanned at @time'.tlParams({
                'time':
                    '${_scannedAt!.hour.toString().padLeft(2, '0')}:'
                    '${_scannedAt!.minute.toString().padLeft(2, '0')}',
              }),
              style: ts.s12.withColor(colors.onSurfaceVariant),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 6),
            Text(_error!, style: ts.s12.withColor(colors.error)),
          ],
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 32, 16, 32),
      child: Text(
        'No source declares multiple mirrors.'.tl,
        style: ts.s14.withColor(context.colorScheme.onSurfaceVariant),
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _MirrorGroupTile extends StatelessWidget {
  const _MirrorGroupTile({
    required this.group,
    required this.results,
    required this.health,
    required this.onOpen,
  });

  final MirrorSettingGroup group;
  final List<MirrorProbeResult>? results;
  final _GroupHealth health;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final currentResult = _resultFor(group.currentOrFirst);
    final best = _bestUsable();
    final currentHost = Uri.tryParse(group.currentOrFirst)?.host ??
        group.currentOrFirst;

    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(top: 6, right: 12),
              decoration: BoxDecoration(
                color: _healthColor(context),
                shape: BoxShape.circle,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${group.sourceName} · ${group.title.tl}',
                    style: ts.s14,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$currentHost · ${_describe(currentResult)}',
                    style: ts.s12.withColor(
                      currentResult != null && !currentResult.isUsable
                          ? colors.error
                          : colors.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (best != null && (currentResult?.isUsable != true)) ...[
                    const SizedBox(height: 2),
                    Text(
                      '${'Suggested'.tl}: ${Uri.tryParse(best.url)?.host ?? best.url}'
                      ' · ${best.latencyMs ?? 0}ms',
                      style: ts.s12.withColor(context.useTextColor(Colors.green)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: onOpen,
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Speed test'.tl,
            ),
          ],
        ),
      ),
    );
  }

  MirrorProbeResult? _resultFor(String url) {
    final list = results;
    if (list == null) return null;
    for (final result in list) {
      if (result.url == url) return result;
    }
    return null;
  }

  MirrorProbeResult? _bestUsable() {
    final list = results;
    if (list == null) return null;
    MirrorProbeResult? best;
    for (final result in list) {
      if (!result.isUsable) continue;
      if (best == null || (result.latencyMs ?? 1 << 30) < (best.latencyMs ?? 1 << 30)) {
        best = result;
      }
    }
    return best;
  }

  String _describe(MirrorProbeResult? result) {
    if (result == null) return 'Not tested'.tl;
    return switch (result.status) {
      MirrorStatus.ok => result.latencyMs == null ? 'OK' : '${result.latencyMs}ms',
      MirrorStatus.blocked =>
        '${result.statusCode ?? ''} ${'Mirror blocked'.tl}'.trim(),
      MirrorStatus.serverError =>
        '${result.statusCode ?? ''} ${'Server error'.tl}'.trim(),
      MirrorStatus.unreachable => 'Unreachable'.tl,
      MirrorStatus.invalid => 'Invalid'.tl,
    };
  }

  Color _healthColor(BuildContext context) => switch (health) {
    _GroupHealth.healthy => context.useTextColor(Colors.green),
    _GroupHealth.degraded => context.useTextColor(Colors.orange),
    _GroupHealth.broken => context.colorScheme.error,
    _GroupHealth.pending => context.colorScheme.outline,
  };
}
