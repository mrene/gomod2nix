{
  buildEnv,
  buildPackages,
  cacert,
  fetchgit,
  git,
  gomod2nix,
  jq,
  lib,
  makeSetupHook,
  pkgsBuildBuild,
  rsync,
  runCommand,
  runtimeShell,
  stdenv,
  stdenvNoCC,
  writeScript,
}:
let

  hooks = import ./hooks/default.nix {
    inherit
      lib
      makeSetupHook
      rsync
      stdenv
      ;
  };

  inherit (hooks)
    goConfigHook
    goBuildHook
    goCheckHook
    goInstallHook
    ;

  inherit (builtins)
    elemAt
    hasAttr
    readFile
    split
    substring
    toJSON
    ;
  inherit (lib)
    concatStringsSep
    fetchers
    filterAttrs
    mapAttrs
    mapAttrsToList
    optional
    optionalAttrs
    optionalString
    pathExists
    removePrefix
    ;

  parseGoMod = import ./parser.nix;

  # Internal only build-time attributes
  internal =
    let
      mkInternalPkg =
        name: src:
        pkgsBuildBuild.runCommand "gomod2nix-${name}"
          {
            inherit (pkgsBuildBuild.go) GOOS GOARCH;
            nativeBuildInputs = [ pkgsBuildBuild.go ];
          }
          ''
            export HOME=$(mktemp -d)
            go build -o "$HOME/bin" ${src}
            mv "$HOME/bin" "$out"
          '';
    in
    {
      # Create a symlink tree of vendored sources
      symlink = mkInternalPkg "symlink" ./symlink/symlink.go;

      # Install development dependencies from tools.go
      install = mkInternalPkg "symlink" ./install/install.go;
    };

  fetchGoModule =
    {
      hash,
      goPackagePath,
      version,
      go,
    }:
    stdenvNoCC.mkDerivation {
      name = "${baseNameOf goPackagePath}_${version}";
      builder = ./fetch.sh;
      inherit goPackagePath version;
      nativeBuildInputs = [
        cacert
        git
        go
        jq
      ];
      outputHashMode = "recursive";
      outputHashAlgo = null;
      outputHash = hash;
      impureEnvVars = fetchers.proxyImpureEnvVars ++ [ "GOPROXY" ];
    };

  mkVendorEnv =
    {
      go,
      modulesStruct,
      defaultPackage ? "",
      goMod,
      pwd,
    }:
    let
      localReplaceCommands =
        let
          localReplaceAttrs = filterAttrs (n: v: hasAttr "path" v) goMod.replace;
          commands = (
            mapAttrsToList (name: value: (''
              mkdir -p $(dirname vendor/${name})
              ln -s ${pwd + "/${value.path}"} vendor/${name}
            '')) localReplaceAttrs
          );
        in
        if goMod != null then commands else [ ];

      sources = mapAttrs (
        goPackagePath: meta:
        fetchGoModule {
          goPackagePath = meta.replaced or goPackagePath;
          inherit (meta) version hash;
          inherit go;
        }
      ) modulesStruct.mod;
    in
    runCommand "vendor-env"
      {
        nativeBuildInputs = [ go ];
        json = toJSON (filterAttrs (n: _: n != defaultPackage) modulesStruct.mod);

        sources = toJSON (filterAttrs (n: _: n != defaultPackage) sources);

        passthru = {
          inherit sources;
        };

        passAsFile = [
          "json"
          "sources"
        ];
      }
      (''
        mkdir vendor

        export GOCACHE=$TMPDIR/go-cache
        export GOPATH="$TMPDIR/go"

        ${internal.symlink}
        ${concatStringsSep "\n" localReplaceCommands}

        mv vendor $out
      '');

  # Return a Go attribute and error out if the Go version is older than was specified in go.mod.
  selectGo =
    attrs: goMod:
    attrs.go or (
      if goMod == null then
        buildPackages.go
      else
        (
          let
            goVersion = goMod.go;
            goAttrs = lib.reverseList (
              builtins.filter (
                attr:
                lib.hasPrefix "go_" attr
                && (
                  let
                    try = builtins.tryEval buildPackages.${attr};
                  in
                  try.success && try.value ? version
                )
                && lib.versionAtLeast buildPackages.${attr}.version goVersion
              ) (lib.attrNames buildPackages)
            );
            goAttr = elemAt goAttrs 0;
          in
          (
            if goAttrs != [ ] then
              buildPackages.${goAttr}
            else
              throw "go.mod specified Go version ${goVersion}, but no compatible Go attribute could be found."
          )
        )
    );

  # Strip extra data that Go adds to versions, and fall back to a version based on the date if it's a placeholder value.
  # This is data that Nix can't handle in the version attribute.
  stripVersion =
    version:
    let
      parts = elemAt (split "(\\+|-)" (removePrefix "v" version));
      v = parts 0;
      d = parts 2;
    in
    if v != "0.0.0" then
      v
    else
      "unstable-"
      + (concatStringsSep "-" [
        (substring 0 4 d)
        (substring 4 2 d)
        (substring 6 2 d)
      ]);

  mkGoEnv =
    {
      pwd,
      toolsGo ? pwd + "/tools.go",
      modules ? pwd + "/gomod2nix.toml",
      ...
    }@attrs:
    let
      goMod = parseGoMod (readFile "${toString pwd}/go.mod");
      modulesStruct = fromTOML (readFile modules);

      go = selectGo attrs goMod;

      vendorEnv = mkVendorEnv {
        inherit
          go
          goMod
          modulesStruct
          pwd
          ;
      };

    in
    stdenv.mkDerivation (
      removeAttrs attrs [ "pwd" ]
      // {
        name = "${baseNameOf goMod.module}-env";

        dontUnpack = true;
        dontConfigure = true;
        dontInstall = true;

        CGO_ENABLED = attrs.CGO_ENABLED or go.CGO_ENABLED;

        nativeBuildInputs = [
          rsync
          goConfigHook
        ];

        propagatedBuildInputs = [ go ];

        GO_NO_VENDOR_CHECKS = "1";

        GO111MODULE = "on";
        GOFLAGS = "-mod=vendor";

        # Pass vendor directory to the setup hook
        goVendorDir = vendorEnv;

        preferLocalBuild = true;

        buildPhase = ''
          mkdir $out

          export GOCACHE=$TMPDIR/go-cache
          export GOPATH="$out"
          export GOSUMDB=off
          export GOPROXY=off

        ''
        + optionalString (pathExists toolsGo) ''
          mkdir source
          cp ${pwd + "/go.mod"} source/go.mod
          cp ${pwd + "/go.sum"} source/go.sum
          cp ${toolsGo} source/tools.go
          cd source

          rsync -a -K --ignore-errors ${vendorEnv}/ vendor

          ${internal.install}
        '';
      }
    );

  buildGoApplication =
    {
      modules ? pwd + "/gomod2nix.toml",
      src ? pwd,
      pwd ? null,
      nativeBuildInputs ? [ ],
      allowGoReference ? false,
      meta ? { },
      passthru ? { },
      tags ? [ ],
      ldflags ? [ ],

      ...
    }@attrs:
    let
      modulesStruct = if modules == null then { } else fromTOML (readFile modules);

      goModPath = "${toString pwd}/go.mod";

      goMod = if pwd != null && pathExists goModPath then parseGoMod (readFile goModPath) else null;

      go = selectGo attrs goMod;

      defaultPackage = modulesStruct.goPackagePath or "";

      vendorEnv =
        if modulesStruct != { } then
          mkVendorEnv {
            inherit
              defaultPackage
              go
              goMod
              modulesStruct
              pwd
              ;
          }
        else
          null;

      pname = attrs.pname or baseNameOf defaultPackage;

    in
    stdenv.mkDerivation (
      optionalAttrs (defaultPackage != "") {
        inherit pname;
        version = stripVersion (modulesStruct.mod.${defaultPackage}).version;
        src = vendorEnv.passthru.sources.${defaultPackage};
      }
      // optionalAttrs (hasAttr "subPackages" modulesStruct) {
        subPackages = modulesStruct.subPackages;
      }
      // attrs
      // {
        nativeBuildInputs = [
          rsync
          go
          goConfigHook
          goBuildHook
          goCheckHook
          goInstallHook
        ]
        ++ nativeBuildInputs;

        inherit (go) GOOS GOARCH;

        GO_NO_VENDOR_CHECKS = "1";
        CGO_ENABLED = attrs.CGO_ENABLED or go.CGO_ENABLED;

        GO111MODULE = "on";
        GOFLAGS = [ "-mod=vendor" ] ++ lib.optionals (!allowGoReference) [ "-trimpath" ];

        goVendorDir = if vendorEnv != null then vendorEnv else "";
        tags = lib.concatStringsSep "," tags;
        ldflags = lib.concatStringsSep " " ldflags;
        modRoot = attrs.modRoot or "";

        doCheck = attrs.doCheck or true;

        strictDeps = true;

        disallowedReferences = optional (!allowGoReference) go;

        passthru = {
          inherit go vendorEnv hooks;
        }
        // optionalAttrs (hasAttr "goPackagePath" modulesStruct) {

          updateScript =
            let
              generatorArgs =
                if hasAttr "subPackages" modulesStruct then
                  concatStringsSep " " (
                    map (subPackage: modulesStruct.goPackagePath + "/" + subPackage) modulesStruct.subPackages
                  )
                else
                  modulesStruct.goPackagePath;

            in
            writeScript "${pname}-updater" ''
              #!${runtimeShell}
              ${optionalString (pwd != null) "cd ${toString pwd}"}
              exec ${gomod2nix}/bin/gomod2nix generate ${generatorArgs}
            '';

        }
        // passthru;

        inherit meta;
      }
    );

in
{
  inherit
    buildGoApplication
    mkGoEnv
    mkVendorEnv
    hooks
    ;
}
