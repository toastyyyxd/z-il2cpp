{
  description = "z-il2cpp — Zig bindings and native hot runtime for IL2CPP games";

  inputs = {
    zig2nix.url = "github:cloudef/zig2nix";
    zls-overlay.url = "github:zigtools/zls";
  };

  outputs = { zig2nix, zls-overlay, ... }:
    let
      flake-utils = zig2nix.inputs.flake-utils;
    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        zig-bin = zig2nix.outputs.packages.${system}.zig-master;
        zls = zls-overlay.packages.${system}.zls;
        env = zig2nix.outputs.zig-env.${system} { zig = zig-bin; inherit zls; };
        pkgs = env.pkgs;
      in
      {
        devShells.default = env.mkShell {
          buildInputs = [

            pkgs.frida-tools
            pkgs.nodejs_22

            pkgs.jq
            pkgs.curl
            pkgs.xz
            pkgs.git
          ];

          shellHook = ''
            echo "z-il2cpp devshell"
            echo "  zig:   $(zig version)"
            echo "  node:  $(node --version 2>/dev/null || echo unavailable)"
            echo "  frida: $(frida --version 2>/dev/null || echo unavailable)"
            echo "  zls:   $(zls --version 2>/dev/null || echo unavailable)"
          '';
        };
      });
}
