import 'dart:async';
import 'dart:io';
// 창 닫기를 가로챌 때 쓴다. dart:ui 를 통째로 열면 TextStyle 등이 부딪히므로 일부만 가져온다.
import 'dart:ui' show AppExitResponse;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:windows_taskbar/windows_taskbar.dart';

import '../engine/models.dart';
import '../engine/planner.dart';
import '../engine/transitions.dart';
import '../state/app_state.dart';
import 'editor/editor_debug.dart';
import 'theme.dart';
import 'widgets/clip_editor.dart';
import 'widgets/clip_list.dart';
import 'widgets/common.dart';
import 'widgets/queue_panel.dart';
import 'widgets/settings_panel.dart';
import 'widgets/signature.dart';

class HomeScreen extends StatefulWidget {
  final AppState state;

  const HomeScreen({super.key, required this.state});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _dragging = false;
  double _lastTaskbarProgress = -1;
  final _scroll = ScrollController();

  late final AppLifecycleListener _lifecycle;

  bool _debugEditOpened = false;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onStateChanged);
    // 창을 닫으려 할 때 한 번 가로챈다. 실수로 X 를 누르면 작업이 전부 날아간다.
    _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    widget.state.removeListener(_onStateChanged);
    _scroll.dispose();
    super.dispose();
  }

  /// 창을 닫아도 되는지 판단한다.
  ///
  /// 만들던 중이거나 줄 서 있는 작업(일시정지 포함)이 있으면 물어본다.
  /// 대기열이 비었거나 전부 끝났으면 묻지 않고 닫는다.
  Future<AppExitResponse> _onExitRequested() async {
    final state = widget.state;
    if (!state.hasUnfinishedWork) return AppExitResponse.exit;
    if (!mounted) return AppExitResponse.exit;

    final ok = await _confirmExit(context, state);
    if (!ok) return AppExitResponse.cancel;

    // 남은 대기열을 적어 두고 ffmpeg 을 직접 끝낸 뒤에 닫는다.
    await state.prepareForExit();
    return AppExitResponse.exit;
  }

  Future<bool> _confirmExit(BuildContext context, AppState state) async {
    final d = Dim.of(context);
    final running = state.runningJob;
    final waiting = state.waitingCount;

    final lines = <String>[];
    if (running != null) {
      lines.add(state.isPaused
          ? '일시정지 중: ${running.title}'
          : '만드는 중: ${running.title}');
    }
    if (waiting > 0) lines.add('차례를 기다리는 작업: $waiting개');

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded,
                color: AppColors.warning, size: d.px(30)),
            SizedBox(width: d.px(10)),
            Flexible(
              child: Text('아직 다 만들지 않았습니다',
                  style: TextStyle(
                      fontSize: d.px(22), fontWeight: FontWeight.w700)),
            ),
          ],
        ),
        content: SizedBox(
          width: d.px(560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(d.px(14)),
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(d.px(8)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in lines) ...[
                      Text(line,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: d.px(17),
                              fontWeight: FontWeight.w600)),
                      SizedBox(height: d.px(4)),
                    ],
                  ],
                ),
              ),
              SizedBox(height: d.px(14)),
              Text(
                '지금 닫으면 만들던 영상은 완성되지 않습니다.\n'
                '다음에 켤 때 이어서 만들지 물어봅니다.',
                style: TextStyle(fontSize: d.px(17), color: AppColors.text),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('계속 만들기', style: TextStyle(fontSize: d.px(17))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('그래도 닫기',
                style: TextStyle(fontSize: d.px(17), color: AppColors.danger)),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  /// 대기열에 넣은 뒤 화면 맨 위로 올린다.
  ///
  /// 맨 위에서는 대기열과 "만드는 중에도 계속 추가할 수 있다"는 안내가 함께 보인다.
  ///
  /// 프레임을 한 번 넘기고 움직이는 이유 — 대기열에 넣는 순간 목록이 비워져
  /// 내용 높이가 줄어든다. 같은 프레임에서 애니메이션을 걸면 줄어든 높이에
  /// 맞춰 위치가 다시 잡히면서 중간에서 멈춘다. 새 배치가 끝난 뒤에 올려야 한다.
  void _scrollToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    });
  }

  /// 작업표시줄 아이콘에도 진행률을 그린다.
  /// 창을 최소화해 두어도 진행 상황이 보인다.
  bool _askingShortcut = false;
  bool _askingRestore = false;

  /// 지난번에 끝내지 못한 작업을 이어서 만들지 묻는다.
  Future<void> _askRestore() async {
    final d = Dim.of(context);
    final state = widget.state;
    final n = state.pendingRestoreCount;

    final resume = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.history, color: AppColors.primary, size: d.px(30)),
            SizedBox(width: d.px(10)),
            Flexible(
              child: Text('끝내지 못한 작업이 있습니다',
                  style: TextStyle(
                      fontSize: d.px(22), fontWeight: FontWeight.w700)),
            ),
          ],
        ),
        content: SizedBox(
          width: d.px(560),
          child: Text(
            '지난번에 대기열에 걸어 둔 작업 $n개가 끝나지 않은 채로 '
            '프로그램이 꺼졌습니다.\n'
            '이어서 만들까요? 만들다 만 부분부터 계속합니다.',
            style: TextStyle(fontSize: d.px(17)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('버리기',
                style: TextStyle(fontSize: d.px(17), color: AppColors.danger)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('이어서 만들기', style: TextStyle(fontSize: d.px(17))),
          ),
        ],
      ),
    );

    final lost = await state.answerRestore(resume ?? false);
    _askingRestore = false;
    if (!mounted) return;
    if (lost > 0) {
      _toast(context, '작업 $lost개는 영상 파일을 찾을 수 없어 되살리지 못했습니다.',
          isError: true);
    }
    // 바로가기 질문이 밀려 있었다면 이제 물어볼 차례다.
    _onStateChanged();
  }

  void _onStateChanged() {
    final s = widget.state;

    // 진단용: 환경 변수 VIDEOJOIN_DEBUG_EDIT 를 주고 영상 파일과 함께 띄우면
    // 첫 영상의 손보기 창이 클릭 없이 바로 열린다.
    if (editorDebugEnabled &&
        !_debugEditOpened &&
        !s.loading &&
        s.clips.any((c) => c.spec.ok) &&
        mounted) {
      _debugEditOpened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showClipEditor(context, s, s.clips.firstWhere((c) => c.spec.ok));
        }
      });
    }

    if (s.pendingRestoreCount > 0 && !_askingRestore && mounted) {
      _askingRestore = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _askRestore();
      });
    }

    // 첫 실행에 바탕화면 바로가기를 만들지 한 번만 물어본다.
    // 팝업 두 개가 겹치지 않게, 위 질문이 끝난 뒤에 묻는다.
    if (s.needAskDesktopShortcut &&
        !_askingShortcut &&
        s.pendingRestoreCount == 0 &&
        mounted) {
      _askingShortcut = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _askDesktopShortcut();
      });
    }

    try {
      if (s.runningJob != null) {
        // 대기열 전체 기준으로 그린다. 작업 하나가 끝났다고 막대가
        // 되감기면 오히려 헷갈린다.
        final p = s.queueProgress;
        if ((p - _lastTaskbarProgress).abs() > 0.01) {
          _lastTaskbarProgress = p;
          WindowsTaskbar.setProgress((p * 1000).round(), 1000);
        }
      } else {
        if (_lastTaskbarProgress >= 0) {
          // 방금 전까지 돌고 있었다 → 대기열을 다 비운 순간이다.
          WindowsTaskbar.setFlashTaskbarAppIcon(
            mode: TaskbarFlashMode.tray,
            timeout: const Duration(milliseconds: 1500),
          );
        }
        WindowsTaskbar.setProgressMode(TaskbarProgressMode.noProgress);
        _lastTaskbarProgress = -1;
      }
    } on Object {
      // 작업표시줄 표시는 부가 기능이다. 실패해도 무시한다.
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;

    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        if (!state.initialized) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (state.fatalError != null) {
          return Scaffold(body: _fatal(context, state.fatalError!));
        }

        return Scaffold(body: _buildSetup(context, state));
      },
    );
  }

  Widget _fatal(BuildContext context, String message) {
    final d = Dim.of(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.all(d.px(40)),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: d.px(60), color: AppColors.danger),
            SizedBox(height: d.gap),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: d.px(20))),
          ],
        ),
      ),
    );
  }

  Widget _buildSetup(BuildContext context, AppState state) {
    final d = Dim.of(context);

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) {
        setState(() => _dragging = false);
        state.addPaths(detail.files.map((f) => f.path).toList());
      },
      child: Stack(
        children: [
          Column(
            children: [
              _Header(state: state),
              Expanded(
                child: SingleChildScrollView(
                  controller: _scroll,
                  padding:
                      EdgeInsets.fromLTRB(d.px(32), d.px(20), d.px(32), d.px(40)),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: d.px(1180)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // 컴퓨터가 곧 꺼진다는 사실은 무엇보다 먼저,
                          // 가장 크게 보여야 한다. Windows 가 띄우는
                          // 종료 경고는 알아보기 어렵고 취소 방법도 모른다.
                          if (state.shutdownAt != null) ...[
                            _ShutdownBanner(state: state),
                            SizedBox(height: d.gap),
                          ],
                          // 대기열은 언제나 맨 위에 있다. 만드는 동안에도 아래에서
                          // 다음 묶음을 준비할 수 있다.
                          QueuePanel(state: state),
                          if (state.clips.isEmpty)
                            _buildEmptyState(context, state)
                          else ...[
                            _buildStep1(context, state),
                            SizedBox(height: d.gap),
                            _buildStep2(context, state),
                            SizedBox(height: d.gap),
                            _buildStep3(context, state),
                            SizedBox(height: d.gap),
                            _buildSummaryAndStart(context, state),
                          ],
                          const Signature(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_dragging) _dropOverlay(context),
        ],
      ),
    );
  }

  Widget _dropOverlay(BuildContext context) {
    final d = Dim.of(context);
    return Positioned.fill(
      child: Container(
        color: AppColors.primary.withValues(alpha: 0.12),
        child: Center(
          child: Container(
            padding: EdgeInsets.symmetric(
                horizontal: d.px(50), vertical: d.px(36)),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(d.px(18)),
              border: Border.all(color: AppColors.primary, width: 3),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.file_download_outlined,
                    size: d.px(56), color: AppColors.primary),
                SizedBox(height: d.px(12)),
                Text('여기에 놓으세요',
                    style: TextStyle(
                        fontSize: d.px(26),
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 영상이 하나도 없을 때의 화면.
  Widget _buildEmptyState(BuildContext context, AppState state) {
    final d = Dim.of(context);

    return Padding(
      padding: EdgeInsets.symmetric(vertical: d.px(20)),
      child: Container(
        width: double.infinity,
        // 스크롤 안에 들어가므로 높이를 명시한다.
        // 대기열이 돌 때는 안내 배너가 하나 더 들어가므로 조금 더 준다.
        height: state.queueActive ? d.px(540) : d.px(440),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(d.px(20)),
          border: Border.all(color: AppColors.borderStrong, width: 2.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (state.loading) ...[
              SizedBox(
                width: d.px(360),
                child: LinearProgressIndicator(
                  value: state.loadTotal == 0
                      ? null
                      : state.loadDone / state.loadTotal,
                  minHeight: d.px(10),
                ),
              ),
              SizedBox(height: d.px(16)),
              Text('영상 정보를 읽는 중… ${state.loadDone} / ${state.loadTotal}',
                  style:
                      TextStyle(fontSize: d.px(19), color: AppColors.textSub)),
            ] else ...[
              // 뒤에서 영상이 만들어지는 중이라면, 기다리지 않고 다음 묶음을
              // 준비해도 된다는 걸 알려 준다.
              if (state.queueActive) ...[
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: d.px(22), vertical: d.px(14)),
                  decoration: BoxDecoration(
                    color: AppColors.primaryLight,
                    borderRadius: BorderRadius.circular(d.px(12)),
                    border: Border.all(
                        color: AppColors.primary.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.autorenew,
                          size: d.px(26), color: AppColors.primary),
                      SizedBox(width: d.px(10)),
                      Text(
                        '만드는 중에도 다음 영상을 넣을 수 있습니다',
                        style: TextStyle(
                          fontSize: d.px(19),
                          fontWeight: FontWeight.w700,
                          color: AppColors.primaryDark,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: d.px(24)),
              ],
              Icon(Icons.video_library_outlined,
                  size: d.px(110), color: AppColors.borderStrong),
              SizedBox(height: d.px(28)),
              Text(
                state.queueActive
                    ? '다음에 합칠 영상을 여기에 끌어다 놓으세요'
                    : '합칠 영상을 여기에 끌어다 놓으세요',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: d.px(30),
                  fontWeight: FontWeight.w700,
                  color: AppColors.text,
                ),
              ),
              SizedBox(height: d.px(10)),
              Text(
                state.queueActive
                    ? '지금 만드는 작업이 끝나면 이어서 만듭니다'
                    : '폴더를 통째로 놓아도 됩니다',
                style: TextStyle(fontSize: d.px(19), color: AppColors.textSub),
              ),
              SizedBox(height: d.px(28)),
              // 끌어다 놓기와 버튼이 같은 결과라는 걸 '또는' 으로 잇는다.
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: d.px(90),
                    child: Divider(color: AppColors.border, thickness: 1),
                  ),
                  SizedBox(width: d.px(14)),
                  Text('또는',
                      style: TextStyle(
                          fontSize: d.px(17), color: AppColors.textFaint)),
                  SizedBox(width: d.px(14)),
                  SizedBox(
                    width: d.px(90),
                    child: Divider(color: AppColors.border, thickness: 1),
                  ),
                ],
              ),
              SizedBox(height: d.px(20)),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  BigButton(
                    label: '영상 고르기',
                    icon: Icons.insert_drive_file_outlined,
                    expanded: false,
                    onPressed: () => _pickFiles(state),
                  ),
                  SizedBox(width: d.gap),
                  OutlineButton(
                    label: '폴더 고르기',
                    icon: Icons.folder_open,
                    onPressed: () => _pickFolder(state),
                  ),
                ],
              ),
              SizedBox(height: d.px(14)),
              Text(
                '어느 쪽이든 똑같이 목록에 들어갑니다',
                style: TextStyle(fontSize: d.px(15), color: AppColors.textFaint),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStep1(BuildContext context, AppState state) {
    final d = Dim.of(context);

    return SectionCard(
      stepNumber: '1',
      title: '영상 넣기',
      trailing: OutlineButton(
        label: '모두 비우기',
        icon: Icons.delete_outline,
        color: AppColors.danger,
        onPressed: state.clearAll,
      ),
      child: Column(
        children: [
          if (state.loading) ...[
            LinearProgressIndicator(
              value: state.loadTotal == 0
                  ? null
                  : state.loadDone / state.loadTotal,
              minHeight: d.px(8),
            ),
            SizedBox(height: d.px(10)),
            Text('영상 정보를 읽는 중… ${state.loadDone} / ${state.loadTotal}',
                style: TextStyle(fontSize: d.px(16), color: AppColors.textSub)),
            SizedBox(height: d.gap),
          ],
          // 끌어다 놓기와 버튼이 같은 일을 한다는 걸 '또는' 으로 묶어 보여준다.
          // 좌우로 떨어뜨려 놓으면 서로 다른 기능처럼 읽힌다.
          Row(
            children: [
              Icon(Icons.file_download_outlined,
                  size: d.px(30), color: AppColors.textFaint),
              SizedBox(width: d.px(12)),
              Text(
                '창 안에 끌어다 놓기',
                style: TextStyle(
                    fontSize: d.px(18),
                    fontWeight: FontWeight.w500,
                    color: AppColors.textSub),
              ),
              SizedBox(width: d.px(16)),
              Text(
                '또는',
                style: TextStyle(
                    fontSize: d.px(16), color: AppColors.textFaint),
              ),
              SizedBox(width: d.px(16)),
              BigButton(
                label: '영상 고르기',
                icon: Icons.add,
                expanded: false,
                onPressed: () => _pickFiles(state),
              ),
              SizedBox(width: d.px(10)),
              OutlineButton(
                label: '폴더 고르기',
                icon: Icons.folder_open,
                onPressed: () => _pickFolder(state),
              ),
            ],
          ),
          if (state.duplicateSkipped > 0) ...[
            SizedBox(height: d.gap),
            NoticeBar.info(
              '이미 목록에 있는 영상 ${state.duplicateSkipped}개는 넣지 않았습니다.',
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _pickFiles(AppState state) async {
    const group = XTypeGroup(
      label: '동영상',
      extensions: [
        'mp4', 'avi', 'mov', 'mkv', 'wmv', 'm4v', 'mpg', 'mpeg',
        'mts', 'm2ts', 'ts', 'flv', 'webm', '3gp', 'vob', 'asf', 'divx',
      ],
    );
    final files = await openFiles(acceptedTypeGroups: const [group]);
    if (files.isNotEmpty) {
      await state.addPaths(files.map((f) => f.path).toList());
    }
  }

  Future<void> _pickFolder(AppState state) async {
    final dir = await getDirectoryPath(confirmButtonText: '이 폴더의 영상 넣기');
    if (dir != null) await state.addPaths([dir]);
  }

  // 목록 저장 / 불러오기 버튼은 화면에서 뺐다. 엔진 쪽(AppState.saveJobList /
  // loadJobList, joblist_file.dart)은 남아 있다.

  /// 첫 실행에 바탕화면 바로가기를 만들지 물어본다.
  ///
  /// 대답이 무엇이든 다시 묻지 않는다(바로가기를 일부러 지운 사람에게 계속 권하지 않게).
  Future<void> _askDesktopShortcut() async {
    final state = widget.state;
    final d = Dim.of(context);

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.desktop_windows_outlined,
                color: AppColors.primary, size: d.px(30)),
            SizedBox(width: d.px(10)),
            Expanded(
              child: Text('바탕화면에 아이콘을 만들까요?',
                  style: TextStyle(
                      fontSize: d.px(22), fontWeight: FontWeight.w700)),
            ),
          ],
        ),
        content: Text(
          '다음부터 바탕화면에서 바로 실행할 수 있습니다.\n'
          '시작 메뉴에는 이미 등록해 두었습니다.',
          style: TextStyle(fontSize: d.px(17)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('괜찮습니다', style: TextStyle(fontSize: d.px(17))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('만들기',
                style: TextStyle(
                    fontSize: d.px(17),
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary)),
          ),
        ],
      ),
    );

    await state.answerDesktopShortcut(ok ?? false);
  }

  /// 같은 이름의 파일을 덮어쓰기 전에 확인받는다.
  ///
  /// 기존 파일의 날짜와 크기를 같이 보여 줘서 지워도 되는지 판단하게 한다.
  Future<bool> _confirmOverwrite(BuildContext context, AppState state) async {
    final d = Dim.of(context);
    final s = state.buildSettings();
    if (s == null) return true;

    String info = '';
    try {
      final f = File(s.outputPath);
      if (f.existsSync()) {
        final st = f.statSync();
        final m = st.modified;
        String two(int v) => v.toString().padLeft(2, '0');
        info = '만든 날짜 ${m.year}-${two(m.month)}-${two(m.day)} '
            '${two(m.hour)}:${two(m.minute)}   ·   ${formatBytes(st.size)}';
      }
    } on Object {
      info = '';
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded,
                color: AppColors.warning, size: d.px(30)),
            SizedBox(width: d.px(10)),
            Text('같은 이름의 파일이 있습니다',
                style:
                    TextStyle(fontSize: d.px(22), fontWeight: FontWeight.w700)),
          ],
        ),
        content: SizedBox(
          width: d.px(560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(d.px(14)),
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(d.px(8)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${s.outputName}.mp4',
                        style: TextStyle(
                            fontSize: d.px(18), fontWeight: FontWeight.w700)),
                    if (info.isNotEmpty) ...[
                      SizedBox(height: d.px(4)),
                      Text(info,
                          style: TextStyle(
                              fontSize: d.px(15), color: AppColors.textSub)),
                    ],
                    SizedBox(height: d.px(4)),
                    Text(s.outputDir,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: d.px(14), color: AppColors.textFaint)),
                  ],
                ),
              ),
              SizedBox(height: d.px(14)),
              Text(
                '그대로 만들면 이 파일이 지워지고 새 영상으로 바뀝니다.\n'
                '되돌릴 수 없습니다.',
                style: TextStyle(fontSize: d.px(17), color: AppColors.text),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('취소하고 이름 바꾸기',
                style: TextStyle(fontSize: d.px(17))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('덮어쓰기',
                style:
                    TextStyle(fontSize: d.px(17), color: AppColors.danger)),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  /// 컴퓨터 끄기는 되돌리기 어려운 동작이라 켤 때 한 번 확인받는다.
  /// 실수로 켜진 채 자리를 비우면 작업 중이던 다른 프로그램까지 함께 꺼진다.
  Future<void> _toggleShutdown(
      BuildContext context, AppState state, bool value) async {
    if (!value) {
      state.setShutdownWhenDone(false);
      return;
    }
    final d = Dim.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('컴퓨터를 자동으로 끌까요?',
            style: TextStyle(fontSize: d.px(22), fontWeight: FontWeight.w700)),
        content: Text(
          '대기열의 영상을 모두 만든 뒤 컴퓨터를 끕니다.\n'
          '끄기 전에 2분 동안 취소할 수 있습니다.',
          style: TextStyle(fontSize: d.px(17)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('아니요', style: TextStyle(fontSize: d.px(17))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('네, 끄세요',
                style: TextStyle(fontSize: d.px(17), color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok == true) state.setShutdownWhenDone(true);
  }

  void _toast(BuildContext context, String message, {bool isError = false}) {
    final d = Dim.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: TextStyle(fontSize: d.px(17))),
        backgroundColor: isError ? AppColors.danger : AppColors.success,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Widget _buildStep2(BuildContext context, AppState state) {
    final d = Dim.of(context);
    final plan = state.plan;
    final valid = state.clips.where((c) => c.spec.ok).toList();
    // 겹치기 전환을 쓰면 겹친 만큼 짧아진 길이를 보여준다(결과물과 같은 숫자).
    final st = state.buildSettings();
    final totalDur = st == null
        ? valid.fold<double>(0, (s, c) => s + c.effectiveDuration)
        : outputDurationFor(valid, st);
    final totalBytes = valid.fold<int>(0, (s, c) => s + c.spec.fileSize);

    return SectionCard(
      stepNumber: '2',
      title: '순서 정하기',
      trailing: Text(
        '${valid.length}개 · ${formatDurationKorean(totalDur)} · ${formatBytes(totalBytes)}',
        style: TextStyle(fontSize: d.px(17), color: AppColors.textSub),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipList(state: state),
          if (plan != null && plan.warnings.isNotEmpty) ...[
            SizedBox(height: d.gap),
            for (final w in plan.warnings) ...[
              switch (w.level) {
                WarningLevel.error =>
                  NoticeBar.error(w.message, detail: w.detail),
                WarningLevel.caution =>
                  NoticeBar.caution(w.message, detail: w.detail),
                WarningLevel.info => NoticeBar.info(w.message, detail: w.detail),
              },
              SizedBox(height: d.px(8)),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildStep3(BuildContext context, AppState state) {
    final d = Dim.of(context);
    return SectionCard(
      stepNumber: '3',
      title: '저장 설정',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsPanel(state: state),
          SizedBox(height: d.gapLg),
          const Divider(),
          SizedBox(height: d.gapLg),
          OutputPanel(state: state),
        ],
      ),
    );
  }

  Widget _buildSummaryAndStart(BuildContext context, AppState state) {
    final d = Dim.of(context);
    final plan = state.plan;
    if (plan == null) return const SizedBox.shrink();

    final estBytes = state.estimatedBytes;
    final estSec = state.estimatedSeconds;
    final original = plan.totalInputBytes;
    final validCount = state.clips.where((c) => c.spec.ok).length;
    final saved = original > 0 ? (1 - estBytes / original) * 100 : 0.0;
    final issue = state.blockingIssue;

    return Container(
      padding: EdgeInsets.all(d.sectionPad),
      decoration: BoxDecoration(
        color: AppColors.primaryLight,
        borderRadius: BorderRadius.circular(d.radius),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // '원본'이 무엇을 가리키는지 분명히 해 둔다.
          // 넣은 영상 파일들의 용량 합계다.
          SummaryRow(
            label: '넣은 영상',
            value: '${validCount}개  ${formatBytes(original)}',
            note: '지금 목록에 있는 영상 파일들의 용량 합계',
          ),
          SummaryRow(
            label: '예상 용량',
            value: formatBytes(estBytes),
            emphasize: true,
            valueColor: AppColors.primaryDark,
            note: saved > 3
                ? '합계보다 약 ${saved.round()}% 작아짐'
                : (saved < -3
                    ? '합계보다 약 ${(-saved).round()}% 커짐'
                    : '합계와 비슷'),
          ),
          SummaryRow(
            label: '예상 시간',
            value: _timeLabel(estSec),
            note: state.useLossless
                ? '다시 만들지 않으므로 금방 끝납니다'
                : (state.useGpu && state.encoders.anyGpu
                    ? '${state.encoders.gpuLabel} 그래픽카드로 처리'
                    : 'CPU 로 처리'),
          ),
          // 저장해 둔 폴더(outputDir)가 아니라 실제로 쓰이는 값을 보여줘야 한다.
          SummaryRow(
            label: '저장 위치',
            value: '${state.effectiveOutputName}.mp4',
            note: state.effectiveOutputDir,
          ),
          SizedBox(height: d.gap),
          Wrap(
            spacing: d.px(24),
            runSpacing: d.px(4),
            children: [
              // 만드는 '동안'의 이야기라 끝난 뒤 동작들보다 앞에 둔다.
              _AfterDoneCheck(
                label: '만드는 동안 절전 모드 막기',
                value: state.preventSleep,
                onChanged: (v) => state.setPreventSleep(v),
              ),
              _AfterDoneCheck(
                label: '다 만들어지면 폴더 열기',
                value: state.openFolderWhenDone,
                onChanged: (v) => state.setOpenFolderWhenDone(v),
              ),
              _AfterDoneCheck(
                label: '다 만들어지면 컴퓨터 끄기',
                value: state.shutdownWhenDone,
                onChanged: (v) => _toggleShutdown(context, state, v),
              ),
            ],
          ),
          // 화면까지 밤새 켜 두는 줄 알면 켜기가 꺼려진다. 무엇을 막는지 밝힌다.
          if (state.preventSleep) ...[
            SizedBox(height: d.px(8)),
            Text(
              '다 만들 때까지 컴퓨터가 잠들지 않습니다. 화면은 평소대로 꺼집니다.',
              style: TextStyle(fontSize: d.px(15), color: AppColors.textSub),
            ),
          ],
          if (state.shutdownWhenDone && state.openFolderWhenDone) ...[
            SizedBox(height: d.px(8)),
            Text(
              '컴퓨터를 끄기 때문에 폴더는 열리지 않습니다.',
              style: TextStyle(fontSize: d.px(15), color: AppColors.warning),
            ),
          ],
          SizedBox(height: d.gap),
          // 원본 화질을 그대로 유지하는 것이 기본값이라, 작은 영상이 섞여 있으면
          // 그 영상들이 큰 규격에 맞춰지면서 전체 용량이 늘어난다.
          // 정상 동작이지만 당황스러운 숫자라 이유와 줄이는 방법을 한 줄로 알려준다.
          if (!state.useLossless && saved < -15) ...[
            NoticeBar.caution(
              '합친 뒤 용량이 원본보다 커집니다.',
              detail: '작은 영상들을 ${state.resolution?.label ?? ""} 크기에 맞추기 '
                  '때문입니다. 해상도나 비트레이트를 한 단계 낮추면 줄어듭니다.',
            ),
            SizedBox(height: d.gap),
          ],
          if (issue != null) ...[
            NoticeBar.error(issue),
            SizedBox(height: d.gap),
          ],
          // 대기열에 넣으면 곧바로 처리가 시작된다.
          // 이미 만들고 있는 중이면 그 뒤에 줄을 선다.
          BigButton(
            label: state.queueActive ? '대 기 열 에  추 가' : '영 상  합 치 기',
            sublabel: state.queueActive
                ? '지금 만드는 작업이 끝나면 이어서 만듭니다'
                : (state.useLossless
                    ? '그대로 이어붙입니다'
                    : '${state.resolution?.label ?? ""}  '
                        '${state.fps?.label ?? ""}  '
                        '${state.selectedBitrate?.label ?? ""}'),
            icon: state.queueActive ? Icons.playlist_add : Icons.merge_type,
            onPressed: issue != null
                ? null
                : () async {
                    // 덮어쓰기는 되돌릴 수 없다. 화면의 안내 띠를 못 보고
                    // 지나칠 수 있으니 시작 직전에 한 번 더 확인받는다.
                    if (state.outputExists) {
                      final ok = await _confirmOverwrite(context, state);
                      if (!ok) return;
                    }
                    if (!context.mounted) return;
                    final err = state.enqueueCurrent();
                    if (err != null) {
                      _toast(context, err, isError: true);
                    } else {
                      // 대기열은 화면 맨 위에 있다. 방금 넣은 작업이
                      // 시작되는 걸 바로 볼 수 있게 올려 준다.
                      _scrollToTop();
                    }
                  },
          ),
        ],
      ),
    );
  }

  static String _timeLabel(double seconds) {
    if (seconds < 60) return '약 ${seconds.round()}초';
    if (seconds < 3600) return '약 ${(seconds / 60).round()}분';
    final h = seconds ~/ 3600;
    final m = ((seconds % 3600) / 60).round();
    return '약 $h시간 $m분';
  }
}

/// 요약 칸 아래에 붙는 체크박스 한 개 ("만드는 동안 ~", "다 만들어지면 ~").
/// 글자를 눌러도 켜지도록 해서 작은 네모를 정확히 겨냥하지 않아도 되게 한다.
class _AfterDoneCheck extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _AfterDoneCheck({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(d.px(8)),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: d.px(2), horizontal: d.px(4)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IgnorePointer(
              child: Checkbox(
                value: value,
                onChanged: (_) {},
              ),
            ),
            SizedBox(width: d.px(4)),
            Text(label, style: TextStyle(fontSize: d.px(17))),
          ],
        ),
      ),
    );
  }
}

/// 컴퓨터 자동 종료 예고 배너.
///
/// 이 기능은 실수로 켜지기 쉽고, 켜진 줄 모르면 작업 중인 다른 프로그램까지
/// 함께 꺼진다. Windows 자체 경고만 믿지 않고 앱에서 크고 분명하게 알린다.
class _ShutdownBanner extends StatefulWidget {
  final AppState state;
  const _ShutdownBanner({required this.state});

  @override
  State<_ShutdownBanner> createState() => _ShutdownBannerState();
}

class _ShutdownBannerState extends State<_ShutdownBanner> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final at = widget.state.shutdownAt;
    if (at == null) return const SizedBox.shrink();

    final left = at.difference(DateTime.now()).inSeconds.clamp(0, 9999);

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(d.px(22)),
      decoration: BoxDecoration(
        color: AppColors.dangerLight,
        borderRadius: BorderRadius.circular(d.radius),
        border: Border.all(color: AppColors.danger, width: 3),
      ),
      child: Row(
        children: [
          Icon(Icons.power_settings_new, size: d.px(44), color: AppColors.danger),
          SizedBox(width: d.px(18)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$left초 뒤에 컴퓨터가 꺼집니다',
                  style: TextStyle(
                    fontSize: d.px(26),
                    fontWeight: FontWeight.w800,
                    color: AppColors.danger,
                  ),
                ),
                SizedBox(height: d.px(4)),
                Text(
                  '끄지 않으려면 오른쪽 단추를 눌러 주세요.',
                  style: TextStyle(fontSize: d.px(17), color: AppColors.text),
                ),
              ],
            ),
          ),
          BigButton(
            label: '컴퓨터 끄지 않기',
            icon: Icons.cancel_outlined,
            color: AppColors.danger,
            expanded: false,
            onPressed: widget.state.cancelShutdown,
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final AppState state;

  const _Header({required this.state});

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: d.px(32), vertical: d.px(18)),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.movie_filter_outlined,
              size: d.px(34), color: AppColors.primary),
          SizedBox(width: d.px(12)),
          Text(
            '영상 합치기',
            style: TextStyle(
              fontSize: d.px(28),
              fontWeight: FontWeight.w800,
              color: AppColors.text,
            ),
          ),
          const Spacer(),
          // 글자 크기 조절. 자동 보정 뒤에도 작으면 직접 키울 수 있어야 한다.
          Text('글자 크기',
              style: TextStyle(fontSize: d.px(15), color: AppColors.textSub)),
          SizedBox(width: d.px(10)),
          _ScaleButton(
            label: '작게',
            selected: state.uiScaleBoost <= 1.0,
            onTap: () => state.setUiScaleBoost(1.0),
          ),
          SizedBox(width: d.px(6)),
          _ScaleButton(
            label: '보통',
            selected: state.uiScaleBoost > 1.0 && state.uiScaleBoost < 1.3,
            onTap: () => state.setUiScaleBoost(1.15),
          ),
          SizedBox(width: d.px(6)),
          _ScaleButton(
            label: '크게',
            selected: state.uiScaleBoost >= 1.3,
            onTap: () => state.setUiScaleBoost(1.35),
          ),
        ],
      ),
    );
  }
}

class _ScaleButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ScaleButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    return Material(
      color: selected ? AppColors.primary : const Color(0xFFEDF1F5),
      borderRadius: BorderRadius.circular(d.px(8)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(d.px(8)),
        child: Container(
          height: d.px(40),
          padding: EdgeInsets.symmetric(horizontal: d.px(14)),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: d.px(16),
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : AppColors.text,
            ),
          ),
        ),
      ),
    );
  }
}
