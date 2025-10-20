{
  lib,
  makeSetupHook,
  rsync,
  stdenv,
  gnutar,
  zstd,
}:
{
  goConfigHook = makeSetupHook {
    name = "goConfigHook";
    # propagatedBuildInputs = [ rsync gnutar zstd ];
    substitutions = {
      inherit rsync gnutar zstd;
    };
  } ./go-config-hook.sh;

  goBuildHook = makeSetupHook {
    name = "goBuildHook";
    substitutions = {
      hostPlatformConfig = stdenv.hostPlatform.config;
      buildPlatformConfig = stdenv.buildPlatform.config;
    };
  } ./go-build-hook.sh;

  goCheckHook = makeSetupHook {
    name = "goCheckHook";
  } ./go-check-hook.sh;

  goInstallHook = makeSetupHook {
    name = "goInstallHook";
  } ./go-install-hook.sh;
}
