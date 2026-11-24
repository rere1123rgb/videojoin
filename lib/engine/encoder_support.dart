import 'ffmpeg_tools.dart';
import 'planner.dart';

/// 실제로 쓸 수 있는 하드웨어 인코더.
///
/// `ffmpeg -encoders` 에는 드라이버가 없어도 h264_nvenc 가 뜬다.
/// 그래서 1프레임짜리 더미 인코딩을 돌려 성공한 것만 쓴다.
class EncoderSupport {
  final bool h264Nvenc;
  final bool hevcNvenc;
  final bool h264Qsv;
  final bool hevcQsv;
  final bool h264Amf;
  final bool hevcAmf;

  const EncoderSupport({
    this.h264Nvenc = false,
    this.hevcNvenc = false,
    this.h264Qsv = false,
    this.hevcQsv = false,
    this.h264Amf = false,
    this.hevcAmf = false,
  });

  bool get anyGpu => h264Nvenc || h264Qsv || h264Amf;

  String get gpuLabel {
    if (h264Nvenc) return 'NVIDIA';
    if (h264Qsv) return 'Intel';
    if (h264Amf) return 'AMD';
    return '';
  }

  /// GPU 를 못 쓰거나 꺼져 있으면 CPU 인코더로 떨어진다.
  String encoderFor(CodecChoice codec, {required bool preferGpu}) {
    if (preferGpu) {
      if (codec == CodecChoice.h264) {
        if (h264Nvenc) return 'h264_nvenc';
        if (h264Qsv) return 'h264_qsv';
        if (h264Amf) return 'h264_amf';
      } else {
        if (hevcNvenc) return 'hevc_nvenc';
        if (hevcQsv) return 'hevc_qsv';
        if (hevcAmf) return 'hevc_amf';
      }
    }
    return codec == CodecChoice.h264 ? 'libx264' : 'libx265';
  }

  bool isGpuEncoder(String name) => !name.startsWith('lib');

  static EncoderSupport? _cached;

  static Future<EncoderSupport> detect(FFTools tools, {bool force = false}) async {
    if (_cached != null && !force) return _cached!;

    final list = await runCaptured(
      tools.ffmpegPath,
      ['-hide_banner', '-encoders'],
      timeout: const Duration(seconds: 20),
    );
    final available = list.stdout;

    Future<bool> check(String name) async {
      if (!available.contains(name)) return false;
      return _testEncode(tools, name);
    }

    // 우선순위가 정해져 있고 실패하는 테스트는 몇 초 걸리므로, 앞선 쪽이 되면 나머지는 건너뛴다.
    final nv = await check('h264_nvenc');
    final qsv = nv ? false : await check('h264_qsv');
    final amf = (nv || qsv) ? false : await check('h264_amf');

    final nvH = nv ? await check('hevc_nvenc') : false;
    final qsvH = qsv ? await check('hevc_qsv') : false;
    final amfH = amf ? await check('hevc_amf') : false;

    _cached = EncoderSupport(
      h264Nvenc: nv,
      hevcNvenc: nvH,
      h264Qsv: qsv,
      hevcQsv: qsvH,
      h264Amf: amf,
      hevcAmf: amfH,
    );
    return _cached!;
  }

  static Future<bool> _testEncode(FFTools tools, String encoder) async {
    final res = await runCaptured(
      tools.ffmpegPath,
      [
        '-hide_banner',
        '-nostdin',
        '-f', 'lavfi',
        '-i', 'color=c=black:s=320x240:r=30:d=0.1',
        '-c:v', encoder,
        '-frames:v', '1',
        '-f', 'null',
        '-',
      ],
      timeout: const Duration(seconds: 25),
    );
    return res.ok;
  }
}
