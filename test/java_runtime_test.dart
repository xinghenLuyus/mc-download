import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:mc_download/core/java_runtime.dart';
import 'package:mc_download/core/models.dart';

void main() {
  test('automatic Java chooses compatible major and newest update', () {
    const installed = [
      JavaRuntime('java21', '21.0.3', 21),
      JavaRuntime('java17old', '17.0.9', 17),
      JavaRuntime('java8', '1.8.0_442', 8),
      JavaRuntime('java17new', '17.0.14', 17),
    ];
    expect(selectJava(installed).executable, 'java8');
    expect(selectJava(installed, minimumMajor: 17).executable, 'java17new');
    expect(selectJava(installed, minimumMajor: 20).executable, 'java21');
    expect(() => selectJava(installed, minimumMajor: 25), throwsStateError);
    expect(() => selectJava([]), throwsStateError);
    expect(automaticJava(AppSettings().javaPath), isTrue);
    expect(
      automaticJava(AppSettings.fromJson({'javaPath': 'java'}).javaPath),
      isTrue,
    );
    expect(automaticJava(r'C:\custom\java.exe'), isFalse);
  });

  test(
    'discovery lists more than twenty installed runtimes and deduplicates roots',
    () async {
      final root = await Directory.systemTemp.createTemp('mcd-java-scan-');
      addTearDown(() => root.delete(recursive: true));
      final canonicalRoot = await root.resolveSymbolicLinks();
      final exe = Platform.isWindows ? 'java.exe' : 'java';
      for (var i = 0; i < 25; i++) {
        final file = File(p.join(root.path, 'jdk-$i', 'bin', exe));
        await file.parent.create(recursive: true);
        await file.writeAsString('fixture');
      }
      final broken = File(p.join(root.path, 'broken', 'bin', exe));
      await broken.parent.create(recursive: true);
      await broken.writeAsString('invalid runtime');
      final inspected = <String>[];
      final found = await discoverJava(
        extraRoots: [root.path, root.path],
        inspect: (file) async {
          if (!p.isWithin(canonicalRoot, file)) {
            throw const FormatException('not a fixture');
          }
          if (p.basename(p.dirname(p.dirname(file))) == 'broken') {
            throw StateError('invalid runtime');
          }
          inspected.add(file);
          return JavaRuntime(file, '17.0.14', 17);
        },
      );
      expect(found, hasLength(25));
      expect(inspected.toSet(), hasLength(25));
      expect(inspected, hasLength(25));
    },
  );
}
