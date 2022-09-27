{
  inputs,
  cell,
}: let
  inherit (inputs) nixpkgs std;
  l = nixpkgs.lib // builtins;
  n2c = inputs.n2c.packages.nix2container;
in
  /*
  Creates an OCI container image using the given operable.

  Args:
  name: The name of the image.
  tag: Optional tag of the image (defaults to output hash)
  setup: A list of setup tasks to run to configure the container.
  uid: The user ID to run the container as.
  gid: The group ID to run the container as.
  perms: A list of permissions to set for the container.
  labels: An attribute set of labels to set for the container. The keys are
  automatically prefixed with "org.opencontainers.image".
  debug: Whether to include debug tools in the container (bash, coreutils).
  debugInputs: Additional packages to include in the container if debug is
  enabled.
  options: Additional options to pass to nix2container.

  Returns:
  An OCI container image (created with nix2container).
  */
  {
    name,
    operable,
    tag ? "",
    setup ? [],
    uid ? "65534",
    gid ? "65534",
    perms ? [],
    labels ? {},
    debug ? false,
    options ? {},
  }: let
    # Links useful paths into the container.
    runtimeEntryLink = "ln -s ${l.getExe operable.passthru.runtime} $out/bin/runtime";
    debugEntryLink = l.optionalString debug "ln -s ${l.getExe operable.passthru.debug} $out/bin/debug";
    livenessLink = l.optionalString (operable.passthru ? livenessProbe) "ln -s ${l.getExe operable.passthru.livenessProbe} $out/bin/live";
    readinessLink = l.optionalString (operable.passthru ? readinessProbe) "ln -s ${l.getExe operable.passthru.readinessProbe} $out/bin/ready";

    # Wrap the operable with sleep if debug is enabled
    debugOperable = cell.lib.writeScript {
      name = "debug-operable";
      runtimeInputs = [nixpkgs.coreutils];
      text = ''
        set -x
        sleep "''${DEBUG_SLEEP:-0}"
        ${l.getExe operable} "$@"
      '';
    };
    operable' =
      if debug
      then debugOperable
      else operable;

    setupLinks = cell.lib.mkSetup "links" {} ''
      mkdir -p $out/bin
      ln -s ${l.getExe operable'} $out/bin/entrypoint
      ${runtimeEntryLink}
      ${debugEntryLink}
      ${livenessLink}
      ${readinessLink}
    '';

    # The root layer contains all of the setup tasks
    rootLayer = [setupLinks] ++ setup;

    # This is what get passed to nix2container.buildImage
    config =
      {
        inherit name;

        # Setup tasks can include permissions via the passthru.perms attribute
        perms = (l.map (s: l.optionalAttrs (s ? passthru && s.passthru ? perms) s.passthru.perms) setup) ++ perms;

        # Layers are nested to reduce duplicate paths in the image
        layers = [
          # Primary layer is the package layer
          (n2c.buildLayer {
            copyToRoot = [operable.passthru.package];
            maxLayers = 50;
            layers = [
              # Runtime inputs layer
              (n2c.buildLayer {
                deps = operable.passthru.runtimeInputs;
                maxLayers = 10;
              })
            ];
          })
          # Liveness and readiness probe layer
          (n2c.buildLayer {
            deps =
              []
              ++ (l.optionals (operable.passthru ? livenessProbe) [(n2c.buildLayer {deps = [operable.passthru.livenessProbe];})])
              ++ (l.optionals (operable.passthru ? readinessProbe) [(n2c.buildLayer {deps = [operable.passthru.readinessProbe];})]);
            maxLayers = 10;
          })
        ];

        # Max layers is 127, we only go up to 120
        maxLayers = 50;
        copyToRoot = rootLayer;

        config = {
          User = uid;
          Group = gid;
          Entrypoint = ["/bin/entrypoint"];
          Labels = l.mapAttrs' (n: v: l.nameValuePair "org.opencontainers.image.${n}" v) labels;
        };
      }
      // l.optionalAttrs (tag != "") {inherit tag;};
  in
    n2c.buildImage (l.recursiveUpdate config options)