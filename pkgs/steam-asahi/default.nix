{
  lib,
  stdenvNoCC,
  writeShellApplication,
  symlinkJoin,
  makeDesktopItem,
  muvm,
  fex,
  fuse,
  fuse3,
  bash,
  coreutils,
  util-linux,
  gnugrep,
  pciutils,
  squashfuse,
  erofs-utils,
  steam-unwrapped,
  extraEnv ? {
    FEX_X87REDUCEDPRECISION = "1";
    FEX_MULTIBLOCK = "0";
    PROTON_USE_WINED3D = "1";
  },
}:

let
  extraEnvExports = lib.concatStringsSep " \\\n          "
    (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v};") extraEnv);

  # NixOS /etc symlinks that bwrap can't follow — materialize as real files
  etcSymlinksToMaterialize = [
    "host.conf"
    "hosts"
    "localtime"
    "os-release"
    "resolv.conf"
    "nsswitch.conf"
    "group"
    "passwd"
    "machine-id"
  ];

  # Stub dirs/files PressureVessel expects but NixOS doesn't have
  etcStubDirs = [
    "ld.so.conf.d"
    "alternatives"
    "xdg"
    "pulse"
  ];
  etcStubFiles = [
    "ld.so.cache"
    "ld.so.conf"
    "timezone"
  ];

  initScript = writeShellApplication {
    name = "steam-asahi-init";
    runtimeInputs = [
      coreutils
      util-linux
      pciutils
    ];
    text = ''
      log() { echo "[INIT] $*"; }

      log "=== steam-asahi-init starting ==="
      log "Date: $(date -Iseconds)"
      log "Host: $(uname -a)"
      log "id: $(id)"
      log "PATH: $PATH"
      log "Mounts before:"
      mount | grep -E '^/' | head -20

      # NixOS has no FHS paths — create them on a writable overlay over /usr
      # /bin/bash and /usr/bin/env are needed by scripts
      # /usr/lib and /usr/lib64 are needed by bwrap for PressureVessel/steamwebhelper
      #
      # Strategy: /usr is read-only (host mount), so we create a writable tmpfs
      # overlay with all the FHS paths bwrap/Steam expect, then bind-mount over /usr
      mkdir -p /run/fhs/bin /run/fhs/usr
      log "Created /run/fhs/{bin,usr}"
      cp -a /bin/* /run/fhs/bin/ 2>/dev/null || true
      ln -sf ${bash}/bin/bash /run/fhs/bin/bash
      ln -sf ${bash}/bin/sh /run/fhs/bin/sh
      # shellcheck disable=SC2012
      log "Populated /run/fhs/bin: $(ls /run/fhs/bin/ | tr '\n' ' ')"

      # Copy existing /usr contents, then add missing FHS dirs
      cp -a /usr/* /run/fhs/usr/ 2>/dev/null || true
      mkdir -p /run/fhs/usr/bin /run/fhs/usr/lib /run/fhs/usr/lib64
      ln -sf ${coreutils}/bin/env /run/fhs/usr/bin/env
      ln -sf ${pciutils}/bin/lspci /run/fhs/usr/bin/lspci
      # shellcheck disable=SC2012
log "Populated /run/fhs/usr/bin: $(ls /run/fhs/usr/bin/ | tr '\n' ' ')"

      # Expose host Vulkan ICDs at standard FHS path for GPU discovery
      mkdir -p /run/fhs/usr/share/vulkan
      for d in /run/opengl-driver/share/vulkan/*/; do
        [ -d "$d" ] && ln -sf "$d" /run/fhs/usr/share/vulkan/
      done
      # shellcheck disable=SC2012
      log "Vulkan ICDs: $(ls /run/fhs/usr/share/vulkan/ 2>/dev/null | tr '\n' ' ' || echo 'none')"

      # PressureVessel Vulkan layer overrides dir and populate with Steam's layers
      mkdir -p /run/fhs/usr/lib/pressure-vessel/overrides/share/vulkan/implicit_layer.d
      for layer in /home/*/.local/share/vulkan/implicit_layer.d/steam*.json; do
        [ -f "$layer" ] && cp "$layer" /run/fhs/usr/lib/pressure-vessel/overrides/share/vulkan/implicit_layer.d/ 2>/dev/null || true
      done
      # shellcheck disable=SC2012
      log "Vulkan layers: $(ls /run/fhs/usr/lib/pressure-vessel/overrides/share/vulkan/implicit_layer.d/ 2>/dev/null | tr '\n' ' ' || echo 'none')"

      mount --bind /run/fhs/bin /bin
      mount --bind /run/fhs/usr /usr
      log "Bound /run/fhs/{bin,usr} -> /{bin,usr}"

      # Fix NixOS /etc for PressureVessel/bwrap compatibility
      #
      # /etc is read-only inside muvm (host filesystem). Same bind-mount approach as /usr
      # bwrap fails on NixOS symlinks (host.conf -> /etc/static/ -> /nix/store/...) when
      # it creates a new mount namespace without FEX's rootfs overlay
      #
      # Fix: copy /etc to writable tmpfs, materialize symlinks, add stubs, bind-mount over
      mkdir -p /run/fhs/etc
      cp -a /etc/. /run/fhs/etc/ 2>/dev/null || true

      # Materialize NixOS symlinks as real files
      for f in ${lib.concatStringsSep " " etcSymlinksToMaterialize}; do
        if [ -L "/run/fhs/etc/$f" ]; then
          target=$(readlink -f "/run/fhs/etc/$f" 2>/dev/null) || continue
          log "Materializing /run/fhs/etc/$f -> $target"
          rm -f "/run/fhs/etc/$f"
          if [ -f "$target" ]; then
            cp "$target" "/run/fhs/etc/$f"
          elif [ -d "$target" ]; then
            mkdir -p "/run/fhs/etc/$f" && cp -a "$target/." "/run/fhs/etc/$f/"
          fi
        fi
      done

      # Create stub dirs/files PressureVessel expects but NixOS doesn't have
      mkdir -p ${lib.concatMapStringsSep " " (d: "/run/fhs/etc/${d}") etcStubDirs}
      touch ${lib.concatMapStringsSep " " (f: "/run/fhs/etc/${f}") etcStubFiles}
      log "Stub etc dirs/files created"

      mount --bind /run/fhs/etc /etc
      log "Bound /run/fhs/etc -> /etc"

      # FEX needs suid fusermount for rootfs overlay mounting
      mkdir -p /run/wrappers
      mount -t tmpfs -o exec,suid tmpfs /run/wrappers
      mkdir -p /run/wrappers/bin
      cp ${lib.getExe' fuse "fusermount"} /run/wrappers/bin/fusermount
      cp ${lib.getExe' fuse3 "fusermount3"} /run/wrappers/bin/fusermount3
      chown root:root /run/wrappers/bin/fusermount /run/wrappers/bin/fusermount3
      chmod u=srx,g=x,o=x /run/wrappers/bin/fusermount /run/wrappers/bin/fusermount3
      log "fusermount set up at /run/wrappers/bin/"

      # Make fusermount available at the standard FHS path for FEX's FUSE rootfs
      ln -sf /run/wrappers/bin/fusermount /run/fhs/usr/bin/fusermount
      ln -sf /run/wrappers/bin/fusermount3 /run/fhs/usr/bin/fusermount3
      log "fusermount symlinked to /run/fhs/usr/bin/"

      log "Mounts after init:"
      mount | grep -E '^/' | head -30

      log "=== steam-asahi-init complete ==="
    '';
  };

  # Extract Steam bootstrap files at build time from steam-unwrapped source
  # Tracks nixpkgs steam-unwrapped version automatically
  # Raw extraction preserves generic shebangs (no nix patchShebangs),
  # which is required for running under FEX's x86 bash
  steamBootstrap = stdenvNoCC.mkDerivation {
    name = "steam-bootstrap-${steam-unwrapped.version}";
    inherit (steam-unwrapped) src;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/steam-launcher"
      cp bin_steam.sh bootstraplinux_ubuntu12_32.tar.xz steam_subscriber_agreement.txt \
        "$out/steam-launcher/"
      runHook postInstall
    '';
  };
  desktopItem = makeDesktopItem {
    name = "steam-asahi";
    desktopName = "Steam (Asahi)";
    comment = "Steam on Apple Silicon via muvm + FEX-Emu";
    exec = "steam-asahi %U";
    icon = "steam";
    categories = [
      "Game"
      "Network"
    ];
    mimeTypes = [
      "x-scheme-handler/steam"
      "x-scheme-handler/steamlink"
    ];
  };

  launcher = writeShellApplication {
    name = "steam-asahi";
    runtimeInputs = [
      coreutils
      gnugrep
      squashfuse
      erofs-utils
    ];
    text = ''
      die() { echo "ERROR: $1" >&2; exit 1; }
      debug() { echo "[DEBUG] $*" >&2; }

      # --- Debug dump ---
      logfile="''${XDG_DATA_HOME:-$HOME/.local/share}/steam-asahi/debug.log"
      mkdir -p "$(dirname "$logfile")"
      exec 3>"$logfile"
      debug "=== steam-asahi debug log ==="
      debug "Date: $(date -Iseconds)"
      debug "User: $(id -un) uid=$(id -u)"
      debug "Host: $(uname -a)"
      debug "PATH: $PATH"
      debug "FEXBash path: $(command -v FEXBash 2>&1 || echo 'not found')"
      debug "muvm path: $(command -v muvm)"
      debug "muvm real path: $(readlink -f "$(command -v muvm)" 2>/dev/null || echo 'N/A')"

      [[ "$(id -u)" -ne 0 ]] || die "Do not run steam-asahi as root"

      # --- Ensure FEX rootfs ---
      fex_configured=false
      fex_dir="$HOME/.fex-emu"
      debug "FEX dir: $fex_dir"

      if [[ -d "$fex_dir/RootFS" ]]; then
        debug "RootFS dir contents: $(ls -la "$fex_dir/RootFS/" 2>&1)"
        for f in "$fex_dir/RootFS"/*; do
          case "$f" in
            *.ero | *.sqsh | *.img) fex_configured=true; debug "Found rootfs image: $f"; break ;;
          esac
          [[ -d "$f" ]] && { fex_configured=true; debug "Found rootfs dir: $f"; break; }
        done
      else
        debug "RootFS dir does not exist"
      fi

      if [[ "$fex_configured" = false && -f "$fex_dir/Config.json" ]]; then
        debug "Checking Config.json for RootFS..."
        debug "Config.json: $(cat "$fex_dir/Config.json" 2>&1)"
        if grep -qE '"RootFS"[[:space:]]*:[[:space:]]*"[^"]+"' "$fex_dir/Config.json" 2>/dev/null; then
          fex_configured=true
          debug "RootFS configured in Config.json"
        fi
      fi

      if [[ "$fex_configured" = false ]]; then
        debug "No rootfs configured, downloading..."
        echo "FEX rootfs not found. Downloading Fedora 43 rootfs..."
        echo "This is a one-time setup (~1.3GB download)."
        echo
        if ! ${lib.getExe' fex "FEXRootFSFetcher"} --assume-yes --distro-name=Fedora \
            --distro-version=43 --distro-list-first --as-is; then
          debug "Automatic download failed, trying interactive..."
          echo "Automatic download failed. Trying interactive mode..."
          ${lib.getExe' fex "FEXRootFSFetcher"}
        fi
      fi

      data_dir="''${XDG_DATA_HOME:-$HOME/.local/share}/steam-asahi"
      marker="$data_dir/bootstrap-installed"
      debug "data_dir: $data_dir"
      debug "marker file: $marker (exists: $([[ -f $marker ]] && echo yes || echo no))"

      if [[ ! -f "$marker" || ! -f "$data_dir/steam-launcher/bin_steam.sh" ]]; then
        debug "Setting up Steam bootstrap..."
        echo "Setting up Steam bootstrap..."
        mkdir -p "$data_dir"
        cp -a ${steamBootstrap}/steam-launcher "$data_dir/"
        echo "ok" > "$marker"
        echo "Steam bootstrap ready."
        debug "Bootstrap installed"
      fi

      # --- Find FEX rootfs image for muvm ---
      fex_image=""
      if [[ -d "$fex_dir/RootFS" ]]; then
        debug "Scanning $fex_dir/RootFS for erofs images..."
        ls -la "$fex_dir/RootFS/" >&3 2>&1
        for f in "$fex_dir/RootFS"/*; do
          case "$f" in
            *.ero | *.erofs | *.sqsh)
              fex_image="$f"
              debug "Found fex_image: $fex_image"
              break
              ;;
          esac
        done
      fi
      if [[ -z "$fex_image" ]]; then
        debug "No fex_image found (will skip --fex-image)"
      fi

      # --- Pre-flight checks ---
      debug "Testing FEXBash standalone..."
      if FEXBash -c 'echo FEX_OK; uname -m' 2>&3; then
        debug "FEXBash standalone succeeded"
      else
        debug "FEXBash standalone FAILED (exit: $?)"
      fi

      debug "Testing native muvm..."
      if muvm --interactive -- bash -c 'echo MUVM_OK' 2>&3; then
        debug "muvm native succeeded"
      else
        debug "muvm native FAILED (exit: $?)"
      fi

      # --- Launch Steam via muvm + FEXBash ---
      steam_args="-cef-force-occlusion''${*:+ $*}"
      uid=$(id -u)
      debug "steam_args: $steam_args"

      echo "Launching Steam via muvm + FEX..."

      fex_muvm_args=()
      if [[ -n "$fex_image" ]]; then
        fex_muvm_args=(--fex-image "$fex_image")
      fi

      muvm_bin=${lib.getExe muvm}
      init_bin=${lib.getExe initScript}

      {
      echo "[DEBUG] Full muvm invocation:"
      echo "  $muvm_bin \\"
      echo "    --gpu-mode=drm \\"
      if [[ -n "$fex_image" ]]; then
        echo "    --fex-image \"$fex_image\" \\"
      fi
      echo "    --execute-pre $init_bin \\"
      echo "    --interactive \\"
      echo "    -e PRESSURE_VESSEL_FILESYSTEMS_RO=/nix:/run/opengl-driver \\"
      echo "    -- \\"
      echo "    FEXBash -c \"...\""
      } >&3

      # Don't exec so we can capture the exit code
      "$muvm_bin" \
        --gpu-mode=drm \
        "''${fex_muvm_args[@]}" \
        --execute-pre "$init_bin" \
        --interactive \
        -e "PRESSURE_VESSEL_FILESYSTEMS_RO=/nix:/run/opengl-driver" \
        -- \
        FEXBash -c "\
          export PULSE_SERVER=unix:/run/user/$uid/pulse/native; \
          export SDL_AUDIODRIVER=pulseaudio; \
          export LC_ALL=C.UTF-8; \
          export LANG=C.UTF-8; \
          export LOCALE_ARCHIVE=/run/current-system/sw/lib/locale/locale-archive; \
          ${extraEnvExports}
          $data_dir/steam-launcher/bin_steam.sh $steam_args"

      muvm_exit=$?
      debug "muvm exited with code $muvm_exit"
      echo "[DEBUG] muvm exited with code $muvm_exit" >&2
      debug "Full log written to $logfile"
      echo "[DEBUG] Full log written to $logfile" >&2
      exit $muvm_exit
    '';

    meta = {
      description = "Steam launcher for NixOS on Apple Silicon via muvm + FEX-Emu";
      license = lib.licenses.mit;
      platforms = [ "aarch64-linux" ];
    };
  };
in
symlinkJoin {
  name = "steam-asahi";
  paths = [
    launcher
    desktopItem
  ];
  postBuild = ''
    mkdir -p "$out/share"
    ln -s ${steam-unwrapped}/share/icons "$out/share/icons"
  '';
  inherit (launcher) meta;
}
