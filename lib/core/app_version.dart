/// Supplied by the build workflow; local builds default to dev.
const appVersion = String.fromEnvironment(
  'MC_DOWNLOAD_VERSION',
  defaultValue: 'dev',
);
const appTitle = 'MC Download $appVersion';
