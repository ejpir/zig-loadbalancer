{
  description = "Async TLS for the Tardy Runtime";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-24.11";
    iguana = {
      url = "github:mookums/iguana";
      inputs.zigPkgs.url = "github:mitchellh/zig-overlay";
    };
    zigpkgs.url = "github:mitchellh/zig-overlay";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      iguana,
      zigpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        iguanaLib = iguana.lib.${system};
      in
      {
        devShells.default = iguanaLib.mkShell {
          zigVersion = "0.14.0";
          withZls = false;

          extraPackages = with pkgs; [
            openssl
          ];
        };
      }
    );
}
