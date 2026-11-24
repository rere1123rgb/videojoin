import 'dart:ffi';
import 'dart:io';

/// 돌고 있는 프로세스를 얼렸다 녹인다. "일시정지" 에 쓴다.
///
/// ffmpeg 을 죽였다 다시 켜면 만들던 조각을 처음부터 다시 해야 하므로 얼려 둔다.
/// ntdll 의 `NtSuspendProcess` / `NtResumeProcess` (비공개 API, 작업 관리자의
/// "일시 중단" 과 같다)를 쓰며, 실패하면 그냥 안 멈출 뿐 인코딩엔 영향이 없다.
class ProcessFreezer {
  static const int _processSuspendResume = 0x0800;

  static bool _looked = false;
  static int Function(int, int, int)? _openProcess;
  static int Function(int)? _closeHandle;
  static int Function(int)? _suspend;
  static int Function(int)? _resume;

  static void _lookup() {
    if (_looked) return;
    _looked = true;
    if (!Platform.isWindows) return;
    try {
      final k32 = DynamicLibrary.open('kernel32.dll');
      final nt = DynamicLibrary.open('ntdll.dll');
      _openProcess = k32.lookupFunction<IntPtr Function(Uint32, Int32, Uint32),
          int Function(int, int, int)>('OpenProcess');
      _closeHandle = k32
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
              'CloseHandle');
      _suspend = nt.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'NtSuspendProcess');
      _resume = nt.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'NtResumeProcess');
    } on Object {
      _openProcess = null;
    }
  }

  static bool _act(int pid, {required bool freeze}) {
    _lookup();
    final open = _openProcess;
    final close = _closeHandle;
    final fn = freeze ? _suspend : _resume;
    if (open == null || close == null || fn == null || pid <= 0) return false;

    final handle = open(_processSuspendResume, 0, pid);
    if (handle == 0) return false;
    try {
      // NTSTATUS 는 0(STATUS_SUCCESS)일 때만 성공이다.
      return fn(handle) == 0;
    } on Object {
      return false;
    } finally {
      close(handle);
    }
  }

  static bool freeze(int pid) => _act(pid, freeze: true);

  static bool thaw(int pid) => _act(pid, freeze: false);
}

/// 이 프로그램이 죽으면 띄워 둔 ffmpeg 도 함께 죽게 묶어 둔다.
///
/// 비정상 종료 시에는 정리 코드가 불리지 않아 ffmpeg 이 고아로 남을 수 있다
/// (얼어 있었다면 파일을 붙잡은 채). Job Object 에 `KILL_ON_JOB_CLOSE` 를 걸어
/// 두면 이 프로세스가 어떻게 끝나든 윈도우가 대신 정리한다.
class ProcessGuard {
  static const int _jobObjectExtendedLimitInformation = 9;
  static const int _killOnJobClose = 0x2000;
  static const int _processSetQuota = 0x0100;
  static const int _processTerminate = 0x0001;

  /// JOBOBJECT_EXTENDED_LIMIT_INFORMATION 의 크기(64비트)와 그 안의 LimitFlags 위치.
  static const int _infoSize = 144;

  static const int _limitFlagsOffset = 16;

  static bool _tried = false;
  static int _job = 0;
  static int Function(int, int, int)? _openProcess;
  static int Function(int)? _closeHandle;
  static int Function(int, int)? _assign;

  static void _init() {
    if (_tried) return;
    _tried = true;
    if (!Platform.isWindows) return;
    try {
      final k32 = DynamicLibrary.open('kernel32.dll');
      final createJob = k32.lookupFunction<IntPtr Function(IntPtr, IntPtr),
          int Function(int, int)>('CreateJobObjectW');
      final setInfo = k32.lookupFunction<
          Int32 Function(IntPtr, Int32, IntPtr, Uint32),
          int Function(int, int, int, int)>('SetInformationJobObject');
      final localAlloc = k32.lookupFunction<IntPtr Function(Uint32, IntPtr),
          int Function(int, int)>('LocalAlloc');
      final localFree = k32
          .lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
              'LocalFree');
      _openProcess = k32.lookupFunction<IntPtr Function(Uint32, Int32, Uint32),
          int Function(int, int, int)>('OpenProcess');
      _closeHandle = k32
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
              'CloseHandle');
      _assign = k32.lookupFunction<Int32 Function(IntPtr, IntPtr),
          int Function(int, int)>('AssignProcessToJobObject');

      final job = createJob(0, 0);
      if (job == 0) return;

      // LPTR(0x40) 은 0 으로 채운 메모리를 준다.
      final mem = localAlloc(0x40, _infoSize);
      if (mem == 0) return;
      try {
        Pointer<Uint32>.fromAddress(mem + _limitFlagsOffset).value =
            _killOnJobClose;
        if (setInfo(job, _jobObjectExtendedLimitInformation, mem, _infoSize) ==
            0) {
          return;
        }
      } finally {
        localFree(mem);
      }
      // 핸들은 일부러 닫지 않는다. 프로세스 종료 시 닫히는 것이 목적이다.
      _job = job;
    } on Object {
      _job = 0;
    }
  }

  /// [pid] 를 이 프로그램의 수명에 묶는다. 실패해도 조용히 넘어간다.
  static bool attach(int pid) {
    _init();
    final open = _openProcess;
    final close = _closeHandle;
    final assign = _assign;
    if (_job == 0 || open == null || close == null || assign == null) {
      return false;
    }
    final h = open(_processSetQuota | _processTerminate, 0, pid);
    if (h == 0) return false;
    try {
      return assign(_job, h) != 0;
    } on Object {
      return false;
    } finally {
      close(h);
    }
  }
}
