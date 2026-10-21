import 'models.dart';

const loaderOrder = [
  'NeoForge',
  'Cleanroom',
  'Forge',
  'Quilt',
  'LegacyFabric',
  'Fabric',
  'LiteLoader',
  'OptiFine',
];

/// Read installation metadata only; never guess a loader from a directory name
/// or the presence of mods, and never execute a launcher or a game JAR.
({String game, Map<String, String> components}) identifyVersion(
  Json manifest,
  Json saved,
  String fallbackId,
) {
  String text(dynamic value) => value is String ? value : '';
  var game = text(manifest['clientVersion']);
  if (game.isEmpty) game = text(manifest['inheritsFrom']);
  if (game.isEmpty) game = text(saved['game']);
  if (game.isEmpty) game = fallbackId;
  final components = <String, String>{};
  void mark(String name, String version) {
    if (version.isNotEmpty || !components.containsKey(name)) {
      components[name] = version;
    }
  }

  String coordinateVersion(String version) {
    final match = RegExp(r'^(1\.\d+(?:\.\d+)?)-(.+)$').firstMatch(version);
    if (match == null) return version;
    game = match[1]!;
    return match[2]!;
  }

  for (final raw in asList(manifest['libraries'])) {
    final coordinate = text(asMap(raw)['name']).split(':');
    if (coordinate.length < 3) continue;
    final group = coordinate[0],
        artifact = coordinate[1],
        version = coordinate[2];
    if (group == 'net.fabricmc' && artifact == 'fabric-loader') {
      mark('Fabric', version);
    }
    if (group == 'org.quiltmc' && artifact == 'quilt-loader') {
      mark('Quilt', version);
    }
    if (group == 'net.minecraftforge' &&
        [
          'forge',
          'minecraftforge',
          'fmlloader',
          'fmlcore',
          'fmlearlydisplay',
        ].contains(artifact)) {
      mark('Forge', coordinateVersion(version));
    }
    if (group == 'net.neoforged' && ['neoforge', 'forge'].contains(artifact)) {
      mark('NeoForge', coordinateVersion(version));
    }
    if (group == 'net.neoforged.fancymodloader' &&
        ['loader', 'core'].contains(artifact)) {
      mark(
        'NeoForge',
        RegExp(r'^1\.\d+(?:\.\d+)?-').hasMatch(version)
            ? coordinateVersion(version)
            : '',
      );
    }
    if (group.toLowerCase() == 'optifine' &&
        artifact.toLowerCase() == 'optifine') {
      final match = RegExp(r'^(1\.\d+(?:\.\d+)?)_(.+)$').firstMatch(version);
      if (match != null) game = match[1]!;
      mark('OptiFine', match?[2] ?? version);
    }
    if (group == 'com.cleanroommc' && artifact == 'cleanroom') {
      mark('Cleanroom', version);
    }
    if (group == 'com.mumfrey' && artifact == 'liteloader') {
      mark('LiteLoader', version);
    }
  }
  if (asList(
    manifest['libraries'],
  ).any((raw) => '${asMap(raw)['name']}'.startsWith('net.legacyfabric:'))) {
    final version = components.remove('Fabric');
    if (version != null) mark('LegacyFabric', version);
  }
  final patchNames = {
    'cleanroom': 'Cleanroom',
    'legacyfabric': 'LegacyFabric',
    'forge': 'Forge',
    'neoforge': 'NeoForge',
    'fabric': 'Fabric',
    'quilt': 'Quilt',
    'optifine': 'OptiFine',
    'liteloader': 'LiteLoader',
  };
  for (final raw in asList(manifest['patches'])) {
    final patch = asMap(raw);
    if (patch['hidden'] == true) continue;
    final id = text(patch['id']).toLowerCase(),
        version = text(patch['version']);
    if (id == 'game' && version.isNotEmpty) game = version;
    if (patchNames.containsKey(id)) {
      mark(
        patchNames[id]!,
        ['forge', 'neoforge'].contains(id)
            ? coordinateVersion(version)
            : version,
      );
    }
  }
  final arguments = <String>[];
  void append(dynamic value) {
    if (value is String) {
      arguments.add(value);
    } else if (value is Map) {
      final argument = value['value'];
      if (argument is String) arguments.add(argument);
      if (argument is List) arguments.addAll(argument.whereType<String>());
    }
  }

  for (final value in asList(asMap(manifest['arguments'])['game'])) {
    append(value);
  }
  for (final match in RegExp(
    r'''"([^"]*)"|'([^']*)'|(\S+)''',
  ).allMatches(text(manifest['minecraftArguments']))) {
    arguments.add(match[1] ?? match[2] ?? match[3]!);
  }
  String flag(String name) {
    for (var i = arguments.length - 1; i >= 0; i--) {
      if (arguments[i].startsWith('$name=')) {
        return arguments[i].substring(name.length + 1);
      }
      if (arguments[i] == name &&
          i + 1 < arguments.length &&
          !arguments[i + 1].startsWith('--')) {
        return arguments[i + 1];
      }
    }
    return '';
  }

  final mc = flag('--fml.mcVersion');
  if (mc.isNotEmpty) game = mc;
  final neo = flag('--fml.neoForgeVersion');
  if (neo.isNotEmpty) mark('NeoForge', neo);
  final forge = flag('--fml.forgeVersion');
  if (forge.isNotEmpty) {
    mark(
      flag('--fml.forgeGroup').startsWith('net.neoforged') ||
              components.containsKey('NeoForge')
          ? 'NeoForge'
          : 'Forge',
      coordinateVersion(forge),
    );
  }
  final entrypoints = [text(manifest['mainClass']), ...arguments].join(' ');
  if (entrypoints.contains('net.neoforged.fml.')) mark('NeoForge', '');
  if (!components.containsKey('NeoForge') &&
      (entrypoints.contains('net.minecraftforge.') ||
          entrypoints.contains('cpw.mods.fml.'))) {
    mark('Forge', '');
  }
  if (entrypoints.contains('net.fabricmc.loader.') &&
      !components.containsKey('LegacyFabric')) {
    mark('Fabric', '');
  }
  if (entrypoints.contains('org.quiltmc.loader.')) mark('Quilt', '');
  if (entrypoints.contains('optifine.OptiFine')) mark('OptiFine', '');
  if (entrypoints.contains('com.mumfrey.liteloader.')) mark('LiteLoader', '');
  // Saved tool records are a fallback; stale records cannot replace live evidence.
  final previous = text(saved['loader']);
  if (components.isEmpty &&
      manifest['mainClass'] != 'net.minecraft.client.main.Main' &&
      loaderOrder.contains(previous)) {
    mark(previous, text(saved['loaderVersion']));
  }
  if (components[previous] == '') mark(previous, text(saved['loaderVersion']));
  // NeoForge can retain Forge namespaces/libraries; it is not a second Forge install.
  if (components.containsKey('NeoForge')) components.remove('Forge');
  return (
    game: game,
    components: {
      for (final name in loaderOrder)
        if (components.containsKey(name)) name: components[name]!,
    },
  );
}

String releaseLoaderVersion(String game, String loader, String version) {
  if (['Forge', 'NeoForge'].contains(loader) && version.startsWith('$game-')) {
    return version.substring(game.length + 1);
  }
  if (loader == 'OptiFine' && version.startsWith('${game}_')) {
    return version.substring(game.length + 1);
  }
  return version;
}

String installerArtifactVersion(String game, String loader, String version) {
  final release = releaseLoaderVersion(game, loader, version);
  return loader == 'Forge' || (loader == 'NeoForge' && game == '1.20.1')
      ? '$game-$release'
      : release;
}
