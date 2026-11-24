// 파일명 정렬 검증.
//
//   flutter test test/sort_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:videojoin/engine/models.dart';

List<String> sortedSmart(List<String> names) {
  final order = detectNameKeyOrder(names);
  final out = [...names]..sort((a, b) => smartNameCompare(a, b, order));
  return out;
}

List<String> sortedPlain(List<String> names) =>
    [...names]..sort(naturalCompare);

void main() {
  group('일반 이름순(자연 정렬)', () {
    test('숫자를 숫자로 비교한다', () {
      expect(
        sortedPlain(['영상10.mp4', '영상2.mp4', '영상1.mp4']),
        ['영상1.mp4', '영상2.mp4', '영상10.mp4'],
      );
    });

    test('앞자리 0 이 붙어도 같게 본다', () {
      expect(
        sortedPlain(['a007.mp4', 'a8.mp4', 'a06.mp4']),
        ['a06.mp4', 'a007.mp4', 'a8.mp4'],
      );
    });
  });

  group('자동 감지 정렬', () {
    // 앞 2자리가 그날의 순번, 뒤 3자리가 날짜인 카메라.
    //
    // 실제로는 탐색기가 이름순으로 정렬해서 넘겨주므로 촬영 순서로 들어온다고
    // 가정하면 안 된다.
    final camera = [
      'E-10463.mp4', 'E-10464.mp4', 'E-10465.mp4',
      'E-20463.mp4', 'E-20464.mp4', 'E-20465.mp4',
      'E-30463.mp4', 'E-30464.mp4', 'E-30465.mp4',
    ];

    test('일반 정렬은 날짜가 뒤섞인다 (문제 재현)', () {
      final plain = sortedPlain(camera);
      // 10463, 10464, 10465, 20463 ... 순으로 날짜가 흩어진다
      expect(plain.first, 'E-10463.mp4');
      expect(plain[1], 'E-10464.mp4');
      expect(plain[2], 'E-10465.mp4');
    });

    test('자동 감지는 날짜별로 묶는다', () {
      expect(sortedSmart(camera), [
        'E-10463.mp4', 'E-20463.mp4', 'E-30463.mp4',
        'E-10464.mp4', 'E-20464.mp4', 'E-30464.mp4',
        'E-10465.mp4', 'E-20465.mp4', 'E-30465.mp4',
      ]);
    });

    test('어떤 순서로 들어와도 같은 결과가 나온다', () {
      // 탐색기 순서 / 촬영 순서 / 뒤집힌 순서 — 전부 같아야 한다.
      final shot = [
        'E-10463.mp4', 'E-20463.mp4', 'E-30463.mp4',
        'E-10464.mp4', 'E-20464.mp4', 'E-30464.mp4',
        'E-10465.mp4', 'E-20465.mp4', 'E-30465.mp4',
      ];
      final reversed = camera.reversed.toList();
      expect(sortedSmart(shot), sortedSmart(camera));
      expect(sortedSmart(reversed), sortedSmart(camera));
    });

    test('감지 결과가 뒷자리를 상위 키로 잡는다', () {
      final o = detectNameKeyOrder(camera);
      expect(o.isPlain, isFalse);
      expect(o.digits, 5);
      // tailDigits 의 구체적인 값은 검증하지 않는다. 이 파일명들은 어느
      // 지점에서 잘라도 정렬 결과가 같아서(10463 → "1|0463" 이든
      // "10|463" 이든 날짜별로 묶인다) 값 자체는 의미가 없다.
      // 중요한 건 결과 순서이고, 그건 위 테스트가 확인한다.
      expect(o.tailDigits, inInclusiveRange(1, o.digits - 1));
    });

    test('평범한 파일명은 건드리지 않는다', () {
      final normal = [
        'IMG_0001.mp4', 'IMG_0002.mp4', 'IMG_0003.mp4',
        'IMG_0004.mp4', 'IMG_0005.mp4', 'IMG_0006.mp4',
      ];
      expect(detectNameKeyOrder(normal).isPlain, isTrue);
      expect(sortedSmart(normal), sortedPlain(normal));
    });

    test('순차 증가하는 이름도 건드리지 않는다', () {
      final seq = List.generate(20, (i) => '영상${i + 1}.mp4');
      expect(detectNameKeyOrder(seq).isPlain, isTrue);
      expect(sortedSmart(seq), sortedPlain(seq));
    });

    test('숫자가 없으면 평범한 정렬로 넘어간다', () {
      final none = ['가.mp4', '나.mp4', '다.mp4', '라.mp4', '마.mp4'];
      expect(detectNameKeyOrder(none).isPlain, isTrue);
      expect(sortedSmart(none), sortedPlain(none));
    });

    test('자릿수가 제각각이면 평범한 정렬로 넘어간다', () {
      final mixed = ['a1.mp4', 'a22.mp4', 'a333.mp4', 'a4444.mp4', 'a5.mp4'];
      expect(detectNameKeyOrder(mixed).isPlain, isTrue);
    });

    test('파일이 너무 적으면 판단하지 않는다', () {
      expect(detectNameKeyOrder(['E-10463.mp4', 'E-20463.mp4']).isPlain, isTrue);
    });

    test('한글 파일명이 섞여도 죽지 않는다', () {
      final k = [
        '가족여행 10463.mp4', '가족여행 20463.mp4', '가족여행 30463.mp4',
        '가족여행 10464.mp4', '가족여행 20464.mp4', '가족여행 30464.mp4',
      ];
      final out = sortedSmart(k);
      expect(out.length, 6);
      expect(out[0], '가족여행 10463.mp4');
      expect(out[1], '가족여행 20463.mp4');
      expect(out[3], '가족여행 10464.mp4');
    });

    test('다른 규칙(뒤 2자리가 상위 키)에도 통한다', () {
      final other = [
        'CAM_101.mp4', 'CAM_201.mp4', 'CAM_301.mp4', 'CAM_401.mp4',
        'CAM_102.mp4', 'CAM_202.mp4', 'CAM_302.mp4', 'CAM_402.mp4',
      ];
      final out = sortedSmart(other);
      expect(out.take(4).toList(),
          ['CAM_101.mp4', 'CAM_201.mp4', 'CAM_301.mp4', 'CAM_401.mp4']);
    });
  });
}
