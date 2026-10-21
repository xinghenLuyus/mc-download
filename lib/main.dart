import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'core/platform_support.dart';
import 'app_state.dart';
import 'ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'MC Download',
    ], await rootBundle.loadString('LICENSE'));
  });
  try {
    final state = AppState(await applicationDataDirectory());
    await state.initialize();
    runApp(DownloadApp(state: state));
  } catch (e) {
    runApp(
      MaterialApp(
        home: Scaffold(body: Center(child: SelectableText('无法初始化应用数据目录\n$e'))),
      ),
    );
  }
}

class DownloadApp extends StatelessWidget {
  final AppState state;
  const DownloadApp({super.key, required this.state});
  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness brightness) {
      final dark = brightness == Brightness.dark;
      final scheme =
          ColorScheme.fromSeed(
            seedColor: const Color(0xff246cf0),
            brightness: brightness,
          ).copyWith(
            primary: dark ? const Color(0xff8db4ff) : const Color(0xff276be9),
            onPrimary: dark ? const Color(0xff132c56) : Colors.white,
          );
      return ThemeData(
        useMaterial3: true,
        brightness: brightness,
        colorScheme: scheme,
        fontFamily: 'Microsoft YaHei UI',
        fontFamilyFallback: const ['Segoe UI', 'Arial'],
        scaffoldBackgroundColor: dark
            ? const Color(0xff121721)
            : const Color(0xfff5f7fb),
        cardTheme: CardThemeData(
          elevation: 0,
          color: dark ? const Color(0xff1b2330) : Colors.white,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: .45),
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          isDense: true,
          filled: true,
          fillColor: dark ? const Color(0xff222c3b) : const Color(0xfff6f8fc),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 14,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: .6),
            ),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        dividerColor: scheme.outlineVariant.withValues(alpha: .5),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(fontSize: 13),
          bodySmall: TextStyle(fontSize: 12),
          titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      );
    }

    final lightTheme = theme(Brightness.light);
    final darkTheme = theme(Brightness.dark);
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) => MaterialApp(
        title: 'MC Download',
        debugShowCheckedModeBanner: false,
        theme: lightTheme,
        darkTheme: darkTheme,
        themeMode: state.settings.dark ? ThemeMode.dark : ThemeMode.light,
        home: AppShell(state: state),
      ),
    );
  }
}
