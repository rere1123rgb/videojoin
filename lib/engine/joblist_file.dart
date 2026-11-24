import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// 작업 목록(경로, 회전, 편집)을 파일 하나로 저장/불러오기.
///
/// 한글 파일명이 들어가므로 **반드시 BOM 없는 UTF-8 로 읽고 쓴다** (기본 CP949 는 깨진다).
class JobListFile {
  static const String extension = 'vjlist';
  static const int _version = 1;

  static Future<void> save(String path, List<ClipItem> clips) async {
    final data = {
      'version': _version,
      'savedAt': DateTime.now().toIso8601String(),
      'clips': [
        for (final c in clips)
          {
            'path': c.spec.path,
            'rotation': c.userRotation,
            if (!c.edit.isDefault) 'edit': c.edit.toJson(),
          },
      ],
    };
    // UTF-8 바이트로 직접 써서 플랫폼 기본 인코딩이 끼지 않게 한다.
    final text = const JsonEncoder.withIndent('  ').convert(data);
    await File(path).writeAsBytes(utf8.encode(text), flush: true);
  }

  /// 경로와 회전 각도만 돌려준다. 스펙은 파일이 바뀌었을 수 있으니 호출한 쪽에서 다시 probe 한다.
  static Future<List<({String path, int rotation, ClipEdit edit})>> load(
      String path) async {
    final bytes = await File(path).readAsBytes();
    final text = utf8.decode(bytes, allowMalformed: true);
    final json = jsonDecode(text) as Map<String, dynamic>;

    final list = (json['clips'] as List?) ?? const [];
    final result = <({String path, int rotation, ClipEdit edit})>[];
    for (final e in list) {
      final m = (e as Map).cast<String, dynamic>();
      final p = m['path'] as String?;
      if (p == null || p.isEmpty) continue;
      final r = (m['rotation'] as num?)?.toInt() ?? 0;
      result.add((path: p, rotation: r, edit: ClipEdit.fromJson(m['edit'])));
    }
    return result;
  }
}
